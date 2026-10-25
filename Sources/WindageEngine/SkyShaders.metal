//
//  SkyShaders.metal
//  WindageEngine
//
//  `SkyPass`: the sky of a `DaySky`, behind everything.
//

#include <metal_stdlib>
using namespace metal;

/// Mirrors `SkyPass.Uniforms`.
struct SkyUniforms {
    float4x4 inverseViewProjection;
    float4 eye;          // xyz
    float4 sunDirection; // xyz, toward the sun
    float4 sunColour;    // rgb, radiance
    float4 zenith;
    float4 horizon;
    float4 ground;
};

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

/// A full-screen triangle from the vertex id, **at depth 0** — the far plane under reversed-Z — drawn with no depth test
/// or write, so anything drawn after covers it.
vertex SkyOut skyVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0;
    SkyOut out;
    out.position = float4(p, 0, 1);
    out.ndc = p;
    return out;
}

/// The zenith overhead fading to the horizon, the ground's colour below it, and the sun's disc so the light has somewhere
/// to come from.
fragment float4 skyFragment(SkyOut in [[stage_in]], constant SkyUniforms &sky [[buffer(0)]]) {
    float4 far = sky.inverseViewProjection * float4(in.ndc, 0.5, 1);
    float3 direction = normalize(far.xyz / far.w - sky.eye.xyz);
    float up = direction.y;
    float3 colour = up >= 0
        ? mix(sky.horizon.rgb, sky.zenith.rgb * 1.6, pow(up, 0.6))
        : mix(sky.horizon.rgb, sky.ground.rgb, saturate(-up * 4));
    float disc = smoothstep(0.9995, 0.9998, dot(direction, sky.sunDirection.xyz));
    return float4(colour + sky.sunColour.rgb * disc * 4, 1);
}
