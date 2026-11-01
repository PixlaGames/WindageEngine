//
//  BoundaryShaders.metal
//  WindageEngine
//
//  The surface of a `WorldBoundary`, for `BoundaryRenderer`. Compiled at runtime from source when the package was
//  built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// One corner of the surface, as `BoundaryRenderer.Vertex` writes it: **two `float4`s**, no padding to disagree about.
struct WEBoundaryVertex {
    float4 positionAndU;   // xyz world position, u: meters along the walls
    float4 normalAndV;     // xyz outward normal, v: meters up them
};

/// The frame, as `BoundaryRenderer.Frame` writes it.
struct WEBoundaryFrame {
    float4x4 viewProjection;
    float4 camera;          // xyz where the view is
    float4 player;          // xyz whom a near boundary shows round; w the time, seconds
    float4 color;          // rgb linear, times the brightness; a its opacity
    float4 style;           // x style (0 lattice, 1 grid, 2 field, 3 haze), y near (1) or always (0), z near distance, w motion
    float4 pattern;         // x the cell size along the walls, y up them
    float4 ripples[8];      // xyz where struck, w seconds since; negative w none
};

struct WEBoundaryOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

vertex WEBoundaryOut weBoundaryVertex(uint vertexID [[vertex_id]],
                                      const device WEBoundaryVertex *vertices [[buffer(0)]],
                                      constant WEBoundaryFrame &frame [[buffer(1)]])
{
    const WEBoundaryVertex v = vertices[vertexID];
    WEBoundaryOut out;
    out.position = frame.viewProjection * float4(v.positionAndU.xyz, 1.0);
    out.world = v.positionAndU.xyz;
    out.normal = v.normalAndV.xyz;
    out.uv = float2(v.positionAndU.w, v.normalAndV.w);
    return out;
}

/// Distance to the nearest edge of a hexagonal lattice with cells one unit across.
static float weHexEdge(float2 p)
{
    const float2 s = float2(1.0, 1.7320508);
    float2 a = p - s * floor(p / s) - s * 0.5;
    float2 q = p - s * 0.5;
    float2 b = q - s * floor(q / s) - s * 0.5;
    float2 g = abs(dot(a, a) < dot(b, b) ? a : b);
    return 0.5 - max(dot(g, normalize(s)), g.x);
}

static float weHash(float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float weNoise(float2 p)
{
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(weHash(i), weHash(i + float2(1, 0)), u.x),
               mix(weHash(i + float2(0, 1)), weHash(i + float2(1, 1)), u.x), u.y);
}

/// **A line that stays a line at any distance**: as wide as `width` cells near, widened to a pixel and a half far off,
/// and faded out once a cell is smaller than a few pixels — a lattice two hundred meters away is a shimmer of moiré
/// otherwise, which reads as a fault in the picture rather than a wall.
static float weLine(float edge, float2 cell, float width)
{
    float pixel = max(fwidth(cell.x), fwidth(cell.y));
    float line = 1.0 - smoothstep(0.0, max(width, pixel * 1.5), edge);
    return line * saturate(1.0 - (pixel - 0.12) / 0.25);
}

fragment float4 weBoundaryFragment(WEBoundaryOut in [[stage_in]],
                                   constant WEBoundaryFrame &frame [[buffer(1)]])
{
    const float t = frame.player.w * frame.style.w;
    const float3 nearPoint = frame.player.xyz + float3(0, 1.0, 0);
    const float d = length(in.world - nearPoint);

    // Near: nothing past its distance, strongest where the player meets it. Always: the whole shell.
    const float near = frame.style.y > 0.5 ? smoothstep(frame.style.z, 1.5, d) : 1.0;
    // Ripples where it was struck: a thin ring spreading at eight meters a second, a small flash where it was hit, gone
    // in a second and a quarter.
    float struck = 0.0;
    for (int i = 0; i < 8; i++) {
        const float4 r = frame.ripples[i];
        if (r.w < 0.0 || r.w > 1.25) continue;
        const float rd = length(in.world - r.xyz);
        const float front = rd - r.w * 8.0;
        struck += (exp(-front * front / 0.12) + exp(-rd * rd / 0.2) * 1.2) * (1.0 - r.w / 1.25);
    }
    if (near <= 0.001 && struck <= 0.001) discard_fragment();

    const float3 toView = normalize(frame.camera.xyz - in.world);
    const float rim = pow(1.0 - abs(dot(normalize(in.normal), toView)), 3.0);
    const float2 cell = in.uv / frame.pattern.xy;
    // Rings spreading from where the player meets it.
    const float rings = smoothstep(0.6, 1.0, sin(d * 2.2 - t * 3.0)) * smoothstep(6.0, 0.0, d);
    const float shimmer = 0.5 + 0.5 * sin(in.uv.y * 0.9 - t * 1.6 + in.uv.x * 0.15);

    const int style = int(frame.style.x + 0.5);
    float glow;
    float cover = 0.6;   // how much of what is behind a glow hides: light adds, haze covers
    if (style == 1) {
        const float2 f = abs(fract(cell - 0.5) - 0.5);
        const float line = weLine(min(f.x, f.y), cell, 0.03);
        glow = near * (0.03 + line * (0.16 + 0.12 * shimmer) + rings * 0.22);
    } else if (style == 2) {
        const float line = weLine(weHexEdge(cell), cell, 0.05);
        const float current = 0.5 + 0.5 * sin(in.uv.y * 0.35 - t * 1.2 + sin(in.uv.x * 0.05 + t * 0.3) * 3.0);
        glow = near * (0.05 + line * (0.08 + 0.14 * current) + rim * 0.45 + rings * 0.22);
        cover = 0.35;
    } else if (style == 3) {
        const float2 drift = float2(t * 0.6, -t * 0.25);
        float haze = weNoise(in.uv * 0.08 + drift * 0.1) * 0.6 + weNoise(in.uv * 0.21 - drift * 0.17) * 0.4;
        glow = near * (0.18 + 0.4 * haze + rim * 0.2);
        cover = 1.0;
    } else {
        const float line = weLine(weHexEdge(cell), cell, 0.06);
        glow = near * (0.03 + line * (0.16 + 0.12 * shimmer) + rings * 0.22);
    }
    glow += struck * 0.35;
    // **The opacity scales it all**, so 0.6 — the default — draws the numbers above as they are.
    const float scale = frame.color.a / 0.6;
    glow *= scale;
    // **A ripple covers a little of what is behind it** as well as glowing: light added to a bright, foggy sky only
    // whitens it, and a ripple that is only light washes out there; covering, it shows its color against any sky.
    return float4(frame.color.rgb * glow, min(glow * cover + struck * 0.45 * scale, 1.0));
}
