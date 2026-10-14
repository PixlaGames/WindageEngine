//
//  ToneMapShaders.metal
//  WindageEngine
//
//  The pass that turns radiance into a picture. See `ToneMapping.swift`, whose `apply(_:)` is the
//  definition these curves transcribe — if one is changed, change both.
//

#include <metal_stdlib>
using namespace metal;

/// Mirrors `ToneMapping.Packed`.
struct ToneMapUniforms {
    float exposure;
    float whitePoint;
    uint  curve;        // 0 clamp · 1 reinhard · 2 ACES — `ToneMapping.Curve.shaderValue`
    uint  padding;
};

struct ToneMapVertexOut {
    float4 position [[position]];
};

/// A full-screen triangle, from nothing but the vertex id.
///
/// **A triangle rather than a quad, and no vertex buffer at all.** Two triangles meeting across the
/// screen have a diagonal seam where the rasteriser processes the same pixels twice; one oversized
/// triangle covers the screen with no seam and needs no geometry, so there is nothing to allocate,
/// bind or keep resident.
vertex ToneMapVertexOut toneMapVertex(uint id [[vertex_id]])
{
    // ids 0,1,2 give (0,0), (2,0), (0,2) in UV, which is (-1,-1), (3,-1), (-1,3) in clip space.
    const float2 uv = float2((id << 1) & 2, id & 2);
    ToneMapVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float3 reinhard(float3 x, float whitePoint)
{
    const float w2 = max(whitePoint * whitePoint, 1e-6f);
    return x * (1.0 + x / w2) / (1.0 + x);
}

/// Narkowicz 2015, "ACES Filmic Tone Mapping Curve" — six constants standing in for a much larger
/// transform, close enough that the difference is invisible in a game.
static float3 aces(float3 x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}

/// **Read, not sampled.** This pass is one-to-one with the drawable, so there is no filtering to do
/// and no texture coordinate to get the wrong way up — `[[position]]` is already the pixel.
fragment float4 toneMapFragment(ToneMapVertexOut in [[stage_in]],
                                texture2d<float, access::read> scene [[texture(0)]],
                                constant ToneMapUniforms &uniforms [[buffer(0)]])
{
    float3 colour = scene.read(uint2(in.position.xy)).rgb * uniforms.exposure;

    switch (uniforms.curve) {
        case 1: colour = reinhard(colour, uniforms.whitePoint); break;
        case 2: colour = aces(colour); break;
        default: break;                 // 0: clamp only, which is what no tone mapping looks like
    }

    // **Written to an `_srgb` drawable, so the GPU encodes for the display.** The value leaving here
    // is linear and in 0…1; doing the sRGB curve here as well would apply it twice and wash the
    // whole image out.
    return float4(saturate(colour), 1.0);
}
