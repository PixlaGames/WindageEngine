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
    float4 positionAndHalfSize;   // xyz world position, w half the edge in metres
    float4 colourAndCoverage;     // rgb colour premultiplied by opacity, a coverage (0 for light)
};

struct WEParticleFrame {
    float4x4 viewProjection;
    float4   right;               // the camera's, so every quad faces it
    float4   up;
};

struct WEParticleOut {
    float4 position [[position]];
    float2 corner;
    float4 colour;
};

/// **Expanded from one instance in the vertex shader**, so the CPU writes a position and a color
/// per particle rather than four corners. The corner is the vertex id; the camera's axes arrive
/// once per frame.
vertex WEParticleOut weParticleVertex(uint vertexID [[vertex_id]],
                                      uint instanceID [[instance_id]],
                                      const device WEParticle *particles [[buffer(0)]],
                                      constant WEParticleFrame &frame [[buffer(1)]])
{
    // A strip of four: (-1,-1) (1,-1) (-1,1) (1,1).
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 corner = corners[vertexID];
    const WEParticle p = particles[instanceID];
    const float3 world = p.positionAndHalfSize.xyz
                       + (frame.right.xyz * corner.x + frame.up.xyz * corner.y) * p.positionAndHalfSize.w;

    WEParticleOut out;
    out.position = frame.viewProjection * float4(world, 1.0);
    out.corner = corner;
    out.colour = p.colourAndCoverage;
    return out;
}

/// A soft disc rather than a square: a hard-edged quad reads as a sprite sheet with its texture
/// missing, which is exactly what it would be.
///
/// **Premultiplied, and that is what lets light and matter share this.** The blend is
/// `src + dst × (1 − src.a)`. Matter writes its opacity as coverage and covers what is behind it;
/// light writes zero, and the same equation becomes a plain add.
fragment float4 weParticleFragment(WEParticleOut in [[stage_in]])
{
    const float r = length(in.corner);
    float falloff = saturate(1.0 - r);
    falloff *= falloff;
    if (falloff <= 0.001) { discard_fragment(); }
    return in.colour * falloff;
}
