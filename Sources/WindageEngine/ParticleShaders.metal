//
//  ParticleShaders.metal
//  WindageEngine
//
//  Camera-facing quads for `ParticleRenderer`. Compiled at runtime from source when the package was
//  built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// One particle, as `ParticleRenderer.Instance` writes it. **Two `float4`s and nothing else**, so
/// there is no padding for the two sides to disagree about — the lesson this codebase has learned
/// three times already.
struct WEParticle {
    float4 position;              // xyz world position
    float4 colourAndCoverage;     // rgb colour premultiplied by opacity, a coverage (0 for light)
    float4 spriteCell;            // atlas u0, v0, du, dv — du 0 for a soft disc
    float4 right;                 // xyz half its width, in the world
    float4 up;                    // xyz half its height, in the world — along the view, its motion or an axis
};

struct WEParticleFrame {
    float4x4 viewProjection;
};

struct WEParticleOut {
    float4 position [[position]];
    float2 corner;
    float4 colour;
    float2 uv;
    float sprite;
};

/// **Expanded from one instance in the vertex shader**, so the CPU writes a position, a colour and two half-edges per
/// particle rather than four corners. The corner is the vertex id; the edges say which way the quad lies — square to the
/// view, along its motion, or along an axis (`ParticleSystem.extent`).
vertex WEParticleOut weParticleVertex(uint vertexID [[vertex_id]],
                                      uint instanceID [[instance_id]],
                                      const device WEParticle *particles [[buffer(0)]],
                                      constant WEParticleFrame &frame [[buffer(1)]])
{
    // A strip of four: (-1,-1) (1,-1) (-1,1) (1,1).
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 corner = corners[vertexID];
    const WEParticle p = particles[instanceID];
    const float3 world = p.position.xyz + p.right.xyz * corner.x + p.up.xyz * corner.y;

    WEParticleOut out;
    out.position = frame.viewProjection * float4(world, 1.0);
    out.corner = corner;
    out.colour = p.colourAndCoverage;
    // Top of the image at the quad's top.
    out.uv = p.spriteCell.xy + float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5) * p.spriteCell.zw;
    out.sprite = p.spriteCell.z > 0.0 ? 1.0 : 0.0;
    return out;
}

/// A soft disc rather than a square: a hard-edged quad reads as a sprite sheet with its texture
/// missing, which is exactly what it would be.
///
/// **Premultiplied, and that is what lets light and matter share this.** The blend is
/// `src + dst × (1 − src.a)`. Matter writes its opacity as coverage and covers what is behind it;
/// light writes zero, and the same equation becomes a plain add.
fragment float4 weParticleFragment(WEParticleOut in [[stage_in]], texture2d<float> sprites [[texture(0)]])
{
    if (in.sprite > 0.5) {
        // **A sprite: the cell's own colour and shape**, tinted and faded by the particle. Clamped, so a cell never
        // bleeds its neighbour in at the edge.
        constexpr sampler cell(mag_filter::linear, min_filter::linear, mip_filter::linear, address::clamp_to_edge);
        const float4 texel = sprites.sample(cell, in.uv);
        const float alpha = texel.a * in.colour.a;
        if (alpha <= 0.004 && in.colour.a > 0.0) { discard_fragment(); }
        return float4(in.colour.rgb * texel.rgb * texel.a, alpha);
    }
    const float r = length(in.corner);
    float falloff = saturate(1.0 - r);
    falloff *= falloff;
    if (falloff <= 0.001) { discard_fragment(); }
    return in.colour * falloff;
}
