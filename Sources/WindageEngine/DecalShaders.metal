//
//  DecalShaders.metal
//  WindageEngine
//
//  Quads lying on surfaces for `DecalRenderer`. Compiled at runtime from source when the package was
//  built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// One mark, as `DecalRenderer.Instance` writes it. **`float4`s only**, so there is no padding for
/// the two sides to disagree about.
struct WEDecal {
    float4 position;   // xyz world, lifted off the surface
    float4 right;      // xyz half the width, along the surface
    float4 up;         // xyz half the height, along the surface
    float4 uvRect;     // u0, v0, du, dv
    float4 tint;       // rgb tint, a opacity
};

struct WEDecalFrame {
    float4x4 viewProjection;
    float4   light;
};

struct WEDecalOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
};

vertex WEDecalOut weDecalVertex(uint vertexID [[vertex_id]],
                                uint instanceID [[instance_id]],
                                const device WEDecal *decals [[buffer(0)]],
                                constant WEDecalFrame &frame [[buffer(1)]])
{
    // A strip of four: (-1,-1) (1,-1) (-1,1) (1,1).
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 corner = corners[vertexID];
    const WEDecal d = decals[instanceID];
    const float3 world = d.position.xyz + d.right.xyz * corner.x + d.up.xyz * corner.y;

    WEDecalOut out;
    out.position = frame.viewProjection * float4(world, 1.0);
    // Corner is -1..1; the cell is a sub-rect of 0..1, top of the image at the quad's top.
    out.uv = d.uvRect.xy + float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5) * d.uvRect.zw;
    out.tint = float4(d.tint.rgb * frame.light.rgb, d.tint.a);
    return out;
}

/// **Premultiplied over.** Clamped rather than repeated: a mark reads one cell of an atlas, and a
/// repeating sampler bleeds the neighbouring cell in along every edge.
fragment float4 weDecalFragment(WEDecalOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]])
{
    constexpr sampler cell(mag_filter::linear, min_filter::linear, mip_filter::linear,
                           address::clamp_to_edge);
    const float4 texel = atlas.sample(cell, in.uv);
    const float alpha = texel.a * in.tint.a;
    if (alpha <= 0.004) { discard_fragment(); }
    return float4(texel.rgb * in.tint.rgb * alpha, alpha);
}
