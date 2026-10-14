//
//  HUDShaders.metal
//  WindageEngine
//

#include <metal_stdlib>
using namespace metal;

// Positions arrive already in normalised device coordinates and colours already in linear space.
// Both conversions happen once on the CPU rather than per vertex, and — more importantly — it keeps
// this shader free of any opinion about tone mapping. There is deliberately no curve here: the
// interface is a specification, not radiance.
//
// Solid shapes and text share one pipeline. Solid geometry points at a fully opaque texel in the
// glyph sheet, so "coverage" is 1 and the maths is identical either way. One pipeline means one
// draw call and, more usefully, that shapes and text composite in the order they were submitted.

struct HUDVertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct HUDInOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex HUDInOut pgeHUDVertex(HUDVertexIn in [[stage_in]])
{
    HUDInOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

fragment float4 pgeHUDFragment(HUDInOut in [[stage_in]],
                               texture2d<float> atlas [[ texture(0) ]])
{
    constexpr sampler atlasSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float coverage = atlas.sample(atlasSampler, in.uv).r;
    float alpha = in.color.a * coverage;

    // Premultiplied, so the standard one / one-minus-source-alpha blend composites correctly over a
    // drawable that already holds the tone-mapped scene.
    return float4(in.color.rgb * alpha, alpha);
}
