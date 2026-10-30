//
//  SkinningShaders.metal
//  WindageEngine
//
//  Skins a character's vertices once a frame, into buffers laid out as the game's own meshes are — so every pass that
//  draws the character afterwards (the scene, each shadow cascade, a reflection) draws an ordinary mesh with the
//  game's ordinary pipeline. See `SkinningPass`.
//

#include <metal_stdlib>
using namespace metal;

/// Where the posed attributes go in the game's layout, in bytes. A stride of zero means the layout has no such
/// attribute. Must match `SkinningParameters` in SkinnedModel.swift.
struct WESkinningParameters {
    uint vertexCount;
    uint positionStride;
    uint positionOffset;
    uint normalStride;
    uint normalOffset;
    uint tangentStride;
    uint tangentOffset;
    uint tangentHasHandedness;
};

/// Linear blend skinning: the weighted sum of the joint matrices moving this vertex.
///
/// **Summed as matrices, then applied once.** Transforming the vertex by each joint and averaging the results gives
/// the same point for a position, but four transforms of the normal averaged is not the normal of anything.
static float4x4 weSkinningMatrix(device const float4x4 *palette, ushort4 joints, float4 weights)
{
    float4x4 skin = palette[joints.x] * weights.x;
    skin += palette[joints.y] * weights.y;
    skin += palette[joints.z] * weights.z;
    skin += palette[joints.w] * weights.w;
    return skin;
}

/// One thread per vertex. **The upper 3×3 of the blended matrix serves for normals and tangents**: a skin is a near
/// rigid blend, and a true inverse transpose per vertex costs more than the artefact it removes at character scale —
/// the same approximation every vertex-shader skinning in this engine's history has made.
kernel void weSkinVertices(device const packed_float3 *restPositions   [[buffer(0)]],
                           device const packed_float3 *restNormals     [[buffer(1)]],
                           device const float4 *restTangents           [[buffer(2)]],
                           device const ushort4 *joints                [[buffer(3)]],
                           device const float4 *weights                [[buffer(4)]],
                           device const float4x4 *palette              [[buffer(5)]],
                           device uchar *positionsOut                  [[buffer(6)]],
                           device uchar *normalsOut                    [[buffer(7)]],
                           device uchar *tangentsOut                   [[buffer(8)]],
                           constant WESkinningParameters &parameters   [[buffer(9)]],
                           uint index [[thread_position_in_grid]])
{
    if (index >= parameters.vertexCount) { return; }
    const float4x4 skin = weSkinningMatrix(palette, joints[index], weights[index]);

    const float3 position = (skin * float4(float3(restPositions[index]), 1.0)).xyz;
    *((device packed_float3 *)(positionsOut + index * parameters.positionStride + parameters.positionOffset)) = position;

    if (parameters.normalStride != 0) {
        const float3 n = (skin * float4(float3(restNormals[index]), 0.0)).xyz;
        const float length2 = dot(n, n);
        const float3 normal = length2 > 1e-12 ? n * rsqrt(length2) : float3(0.0, 1.0, 0.0);
        *((device packed_float3 *)(normalsOut + index * parameters.normalStride + parameters.normalOffset)) = normal;
    }

    if (parameters.tangentStride != 0) {
        const float4 rest = restTangents[index];
        const float3 t = (skin * float4(rest.xyz, 0.0)).xyz;
        const float length2 = dot(t, t);
        const float3 tangent = length2 > 1e-12 ? t * rsqrt(length2) : float3(1.0, 0.0, 0.0);
        device uchar *out = tangentsOut + index * parameters.tangentStride + parameters.tangentOffset;
        if (parameters.tangentHasHandedness != 0) {
            // The handedness rides through untouched: a skin does not mirror.
            *((device packed_float4 *)out) = float4(tangent, rest.w);
        } else {
            *((device packed_float3 *)out) = tangent;
        }
    }
}
