//
//  SampleShaders.metal
//  WindageSample
//
//  Deliberately the smallest shader that shows a lit scene: one directional light, one ambient
//  term, no texture, and cascaded shadows. A sample whose shaders are impressive teaches the reader
//  about the shaders.
//

#include <metal_stdlib>
using namespace metal;

/// One lamp, as the shader sees it. Everything packed into `float4`s, with the scalars in the `w`
/// components — so there is no padding for the two sides to disagree about.
///
/// **A point light travels the same path as a spot.** Its `angleScale` is 0 and its `angleOffset` is
/// 1, which makes the angular term below evaluate to exactly 1 everywhere: no branch, no second loop,
/// and nothing that behaves differently depending on which kind of lamp a level happens to hold.
struct PunctualLight {
    float4 positionAndRange;      // xyz position, w range
    float4 colourAndAngleOffset;  // rgb radiant intensity, w cone offset
    float4 directionAndAngleScale;// xyz cone direction, w cone scale
    /// Where this light's shadow map sits in the atlas: xy offset, z scale, **w is whether it has
    /// one at all**. A point light does not — six faces is a different feature — so it carries 0 and
    /// takes the same path with the test skipped.
    float4 shadowTile;
    /// Where this light's cube sits: x the array slice, y the near plane its faces were projected
    /// with, **w whether it has one at all**. A spot does not — it has a tile instead.
    float4 shadowCube;
    /// World to this light's clip space. Unused when `shadowTile.w` is 0.
    float4x4 shadowViewProjection;
};

struct Uniforms {
    float4x4 viewProjection;
    float4x4 model;
    float3x3 normalMatrix;
    float3   albedo;          // the game's own tint: objective state, editor selection
    float3   sunDirection;
    float4   materialBaseColor;
    float4   materialParams;  // x metallic, y roughness, z highest specular mip
    float4   sunColour;       // the level's sun, in radiance; w unused
    float4   emissive;        // what this surface emits, in radiance; w unused
};

constant int kCascadeCount = 4;

/// One over the atlas's edge, for the filter's step. **A constant rather than a uniform** because it
/// is a property of the atlas the engine allocated, not of anything a frame varies.
constant float kShadowAtlasTexel = 1.0 / 2048.0;

/// Constant depth bias for a spot's map, in the light's normalised depth. Reversed-Z, so **positive**
/// pushes a fragment towards the light and out of its own shadow — the opposite sign from the
/// rasteriser's bias during the pass, which is a different quantity in a different space.
constant float kSpotDepthBias = 0.0016;

/// How much to pull a fragment towards the lamp before comparing, **measured in texels of the face
/// it lands on**, and therefore in metres once multiplied out.
///
/// **Not a constant added to the stored depth, which is what a spot uses and what would be wrong
/// here.** A cube face stores `near / distance`; the same added constant is a third of a millimetre
/// at one metre and most of a metre at ten, so a bias that removes acne close to the lamp deletes
/// contact shadows across the room. In texels it is one number at every distance.
constant float kShadowCubeBiasTexels = 2.0;
/// A floor for it, in metres, so a fragment almost touching the lamp still gets some room.
constant float kShadowCubeMinBias = 0.01;


/// Frame-wide, written once per frame rather than once per object. The per-object `Uniforms` below
/// is copied for every drawable; putting four matrices in it would multiply them by the object count
/// for no reason.
/// Where the cluster grid is, and how to find a fragment's cell in it. **Mirrors `ClusterGrid`** —
/// the shader's slicing and the CPU's assignment must agree, or a light is binned into a cell no
/// fragment ever reads.
struct ClusterUniforms {
    uint  tilesX;
    uint  tilesY;
    uint  slices;
    float sliceScale;    // slice = log(viewDepth) * sliceScale + sliceBias
    float sliceBias;
    float padding0;
    float padding1;
    float padding2;
};

struct FrameUniforms {
    float4x4 cascadeViewProjection[kCascadeCount];
    /// Takes a clip-space point back to the world — how the sky pass turns a pixel into a ray.
    float4x4 inverseViewProjection;
    /// World to view. **Needed for the planar depth a cluster slice is chosen by** — the shadow
    /// cascades use radial distance, which is a different number and would pick a different cell.
    float4x4 view;
    float4   cascadeSplits;
    float4   cascadeBlendStart;
    float4   cascadeDepthBias;
    float3   cameraPosition;
    float    texelSize;      // 1 / shadow map resolution
    float2   viewportSize;   // pixels, for finding a fragment's tile
    float2   framePadding;
    ClusterUniforms clusters;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    float4 tangent  [[attribute(3)]];   // w is the bitangent's handedness, ±1
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 tangent;
    float  handedness;
    float3 worldPosition;
    float2 uv;
};

/// Takes a tangent-space normal into world space.
///
/// **The bitangent is reconstructed rather than carried.** It is the cross product of the other two
/// times the handedness, so storing it would be twelve bytes a vertex to save one cross product —
/// and the two could then disagree.
///
/// **The handedness is why `tangent` is a `float4`.** A UV island mirrored across the model — which
/// is most of any character, whose halves share one texture — has its bitangent the other way round.
/// Drop the sign and every mirrored surface is lit as though the light were on the other side.
static float3 applyNormalMap(float3 sampled, float3 normal, float3 tangent, float handedness)
{
    // A tangent that could not be generated arrives as zero, and normalising it gives NaN — which
    // does not draw a wrong surface, it deletes the triangle. Fall back to the vertex normal.
    if (length_squared(tangent) < 1e-8) { return normal; }

    // Gram-Schmidt: interpolation across a triangle leaves the tangent no longer perpendicular to
    // the normal, and a basis that is not orthogonal skews every direction it maps.
    const float3 t = normalize(tangent - normal * dot(normal, tangent));
    const float3 b = cross(normal, t) * handedness;
    const float3 tangentSpace = sampled * 2.0 - 1.0;      // 0..1 back to -1..1
    return normalize(t * tangentSpace.x + b * tangentSpace.y + normal * tangentSpace.z);
}

/// A skinned vertex carries two more attributes: which joints move it, and how much each one does.
///
/// **Four influences, padded.** The sample's figure uses two, and Model I/O pads the rest with a
/// joint index of 0 and a weight of 0 — which contributes nothing, so no branch is needed to skip
/// them. Four is what every rig authoring tool exports and what a real character will bring.
struct SkinnedVertexIn {
    float3  position [[attribute(0)]];
    float3  normal   [[attribute(1)]];
    float2  uv       [[attribute(2)]];
    float4  tangent  [[attribute(3)]];
    ushort4 joints   [[attribute(4)]];
    float4  weights  [[attribute(5)]];
};

/// Linear blend skinning: the weighted sum of the joint matrices moving this vertex.
///
/// **Summed as matrices, then applied once.** Transforming the vertex by each joint and averaging
/// the results gives the same answer here and four times the work; more to the point, the matrix
/// form is what lets the normal be transformed by the same basis without recomputing anything.
static float4x4 skinningMatrix(constant float4x4 *palette, ushort4 joints, float4 weights)
{
    float4x4 skin = palette[joints.x] * weights.x;
    skin += palette[joints.y] * weights.y;
    skin += palette[joints.z] * weights.z;
    skin += palette[joints.w] * weights.w;
    return skin;
}

vertex VertexOut sampleVertex(VertexIn in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]])
{
    VertexOut out;
    float4 world = uniforms.model * float4(in.position, 1.0);
    out.position = uniforms.viewProjection * world;
    out.normal = normalize(uniforms.normalMatrix * in.normal);
    // **The model matrix, not the normal matrix.** A tangent lies *along* the surface, so it
    // transforms like a position does; the inverse transpose is for things perpendicular to a
    // surface, and using it here shears the tangent off the surface under non-uniform scale.
    out.tangent = (uniforms.model * float4(in.tangent.xyz, 0.0)).xyz;
    out.handedness = in.tangent.w;
    out.worldPosition = world.xyz;
    out.uv = in.uv;
    return out;
}

/// Many copies of one mesh in one draw: the engine's `InstanceBatches` and `InstanceBuffer`.
///
/// **The copy's transform comes from a buffer, by `instance_id`, on top of the object's own** — so the
/// uniforms are written once for the whole batch and only the transforms differ. The copies are sized
/// evenly, so their transform turns normals correctly with no inverse; the normal matrix still carries
/// the object's own.
vertex VertexOut sampleInstancedVertex(VertexIn in [[stage_in]],
                                       uint instance [[instance_id]],
                                       constant Uniforms &uniforms [[buffer(1)]],
                                       const device float4x4 *copies [[buffer(7)]])
{
    const float4x4 model = copies[instance] * uniforms.model;
    const float3x3 basis = float3x3(copies[instance][0].xyz, copies[instance][1].xyz, copies[instance][2].xyz);

    VertexOut out;
    float4 world = model * float4(in.position, 1.0);
    out.position = uniforms.viewProjection * world;
    out.normal = normalize(basis * (uniforms.normalMatrix * in.normal));
    out.tangent = (model * float4(in.tangent.xyz, 0.0)).xyz;
    out.handedness = in.tangent.w;
    out.worldPosition = world.xyz;
    out.uv = in.uv;
    return out;
}

/// The same scene, wearing a pose.
///
/// **The palette is per character, not per vertex** — one matrix per joint, written on the CPU by
/// `SkeletonPose` and read here. Every joint's parent chain, every clip sample and every blend has
/// already happened by the time this runs; a vertex shader that had to walk a hierarchy would do it
/// once per vertex instead of once per joint.
vertex VertexOut sampleSkinnedVertex(SkinnedVertexIn in [[stage_in]],
                                     constant Uniforms &uniforms [[buffer(1)]],
                                     constant float4x4 *palette [[buffer(3)]])
{
    const float4x4 skin = skinningMatrix(palette, in.joints, in.weights);
    const float3x3 skinBasis = float3x3(skin[0].xyz, skin[1].xyz, skin[2].xyz);

    VertexOut out;
    float4 world = uniforms.model * (skin * float4(in.position, 1.0));
    out.position = uniforms.viewProjection * world;
    // **The normal is posed too.** Skip this and a waving arm keeps the shading of the arm it was
    // modelled as — lit from the wrong side, and it reads as a lighting bug rather than a skinning
    // one.
    out.normal = normalize(uniforms.normalMatrix * (skinBasis * in.normal));
    out.tangent = (uniforms.model * float4(skinBasis * in.tangent.xyz, 0.0)).xyz;
    // **Handedness survives skinning unchanged.** It is a property of how the texture was laid out,
    // not of where the joint has moved the vertex to.
    out.handedness = in.tangent.w;
    out.worldPosition = world.xyz;
    out.uv = in.uv;
    return out;
}

/// The shadow pass: position only. **No fragment function and no colour attachment** — nothing is
/// being shaded, only occlusion recorded, so everything but the depth write is wasted work.
vertex float4 sampleShadowVertex(VertexIn in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(1)]],
                                 constant float4x4 &lightViewProjection [[buffer(2)]])
{
    return lightViewProjection * (uniforms.model * float4(in.position, 1.0));
}

/// The shadow pass for instanced copies — the debris. Each copy's transform from the buffer the engine's
/// `ShadowBufferIndex.instances` names, on top of the object's own, exactly as the main pass draws it.
vertex float4 sampleInstancedShadowVertex(VertexIn in [[stage_in]],
                                          uint instance [[instance_id]],
                                          constant Uniforms &uniforms [[buffer(1)]],
                                          constant float4x4 &lightViewProjection [[buffer(2)]],
                                          const device float4x4 *copies [[buffer(4)]])
{
    return lightViewProjection * (copies[instance] * uniforms.model * float4(in.position, 1.0));
}

/// The shadow pass for skinned geometry.
///
/// **A second pipeline rather than a flag**, because the vertex layout differs — and it has to exist
/// at all: a character that is lit and shadowed by the scene but casts nothing reads as floating,
/// which is worse than a scene with no shadows in it.
vertex float4 sampleSkinnedShadowVertex(SkinnedVertexIn in [[stage_in]],
                                        constant Uniforms &uniforms [[buffer(1)]],
                                        constant float4x4 &lightViewProjection [[buffer(2)]],
                                        constant float4x4 *palette [[buffer(3)]])
{
    const float4x4 skin = skinningMatrix(palette, in.joints, in.weights);
    return lightViewProjection * (uniforms.model * (skin * float4(in.position, 1.0)));
}

// MARK: - Shading
//
// A Cook-Torrance microfacet specular with a GGX distribution — the model every renderer of the last
// decade uses, because it is what makes metal look like metal instead of like plastic with a bright
// spot on it.
//
// **It lives in the sample, not the engine.** The engine owns when things happen, the depth
// convention and the tone map; what a surface *is* — its BRDF, its lighting model, how many lights
// it takes — is a game's, and no two of them will agree. If a second consumer writes this same
// function, that is the moment to extract it, and not before.

/// GGX / Trowbridge-Reitz: how much of a rough surface's microfacets face halfway between the light
/// and the eye.
///
/// **`alpha` is roughness squared**, and that squaring is not decorative — roughness is authored
/// *perceptually*, so that dragging a slider from 0.3 to 0.4 looks like an even step. The
/// distribution wants the physical quantity, and using the perceptual value directly makes every
/// slider bunch all its useful range into the first third.
static float distributionGGX(float NdotH, float alpha)
{
    const float a2 = alpha * alpha;
    const float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(M_PI_F * d * d, 1e-7);
}

/// Smith's height-correlated visibility, with the BRDF's own `1 / (4 NdotL NdotV)` folded in.
///
/// **Folded in on purpose.** Written separately, the geometry term and that denominator both go to
/// zero at grazing angles and the division is a ratio of two vanishing numbers — which is a bright
/// rim of fireflies along every silhouette. Combined, the zeros cancel algebraically and never reach
/// the hardware.
static float visibilitySmithGGX(float NdotV, float NdotL, float alpha)
{
    const float a2 = alpha * alpha;
    const float v = NdotL * sqrt(NdotV * NdotV * (1.0 - a2) + a2);
    const float l = NdotV * sqrt(NdotL * NdotL * (1.0 - a2) + a2);
    return 0.5 / max(v + l, 1e-5);
}

/// Schlick's Fresnel: everything is a mirror at a grazing angle.
///
/// This is what puts a bright edge on every surface as it turns away, and it is most of why a
/// physically based image reads as "real" rather than as "shiny".
static float3 fresnelSchlick(float3 f0, float cosTheta)
{
    return f0 + (1.0 - f0) * pow(saturate(1.0 - cosTheta), 5.0);
}

/// Karis's analytic fit of the split-sum environment BRDF.
///
/// **Stands in for a lookup table.** The real thing is a precomputed 2D texture; this is four
/// constants and a couple of multiplies, close enough that the difference is invisible, and it means
/// the sample needs no baked asset to light a metal surface correctly.
static float3 environmentBRDF(float3 f0, float roughness, float NdotV)
{
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    const float4 r = roughness * c0 + c1;
    const float a004 = min(r.x * r.x, exp2(-9.28 * NdotV)) * r.x + r.y;
    const float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

/// The sky, drawn so that what a surface reflects and what the player sees are the same thing.
///
/// **They have to be the same texture.** A flat clear colour behind a metal object that reflects a
/// gradient with a sun in it is two skies in one picture, and the eye finds that faster than it finds
/// almost anything else wrong with a render.
struct SkyVertexOut {
    float4 position [[position]];
    float3 direction;
};

vertex SkyVertexOut sampleSkyVertex(uint id [[vertex_id]],
                                    constant FrameUniforms &frame [[buffer(2)]])
{
    const float2 uv = float2((id << 1) & 2, id & 2);
    const float4 clip = float4(uv * 2.0 - 1.0, 0.0, 1.0);

    SkyVertexOut out;
    out.position = clip;
    // **Reversed-Z: depth 0 is infinitely far**, which is exactly where the sky is. Unproject the far
    // plane and subtract the eye to get the ray this pixel looks along.
    const float4 world = frame.inverseViewProjection * clip;
    out.direction = world.xyz / world.w - frame.cameraPosition;
    return out;
}

fragment float4 sampleSkyFragment(SkyVertexOut in [[stage_in]],
                                  texturecube<float> environment [[texture(3)]])
{
    constexpr sampler skySampler(mag_filter::linear, min_filter::linear, mip_filter::linear);
    // Mip 0 is the environment itself — the prefiltered mips below it are for rough reflections.
    return float4(environment.sample(skySampler, normalize(in.direction), level(0.0)).rgb, 1.0);
}

/// One cascade's lookup. Lifted out of `sunVisibility` so that blending across a split samples the
/// two cascades through identical code rather than a copy that can drift.
static float sampleCascade(constant FrameUniforms &frame,
                           float3 worldPosition,
                           int cascade,
                           depth2d_array<float> shadowMap,
                           sampler shadowSampler)
{
    float4 lightPosition = frame.cascadeViewProjection[cascade] * float4(worldPosition, 1.0);
    float3 projected = lightPosition.xyz / lightPosition.w;

    // Clip space is -1..1 in X/Y, texture space is 0..1 with Y running downwards.
    float2 uv = projected.xy * float2(0.5, -0.5) + 0.5;

    // **Outside the map is lit, not shadowed.** Clamping instead smears the edge texels outward and
    // paints a shadow across everything beyond the covered box.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || projected.z <= 0.0) {
        return 1.0;
    }

    // Reversed-Z: nearer the light is a LARGER depth, so a fragment is lit when its own depth is
    // greater than the nearest recorded occluder. The bias absorbs the remaining quantisation
    // error; it comes from `ShadowCascades.normalizedDepthBias`, which derives it from the world
    // size of a texel rather than from a literal that would mean different things at different
    // scene scales.
    const float reference = projected.z + frame.cascadeDepthBias[cascade];

    // 3x3 percentage-closer filtering. `sample_compare` does the depth test *inside* the texture
    // unit and returns the filtered fraction, so this is nine comparisons rather than nine samples
    // and nine branches — and the edges come back softened instead of stair-stepped.
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            sum += shadowMap.sample_compare(shadowSampler,
                                            uv + float2(x, y) * frame.texelSize, cascade, reference);
        }
    }
    return sum / 9.0;
}

/// Fraction of the sun reaching this fragment: 0 fully shadowed, 1 fully lit.
static float sunVisibility(constant FrameUniforms &frame,
                           float3 worldPosition,
                           depth2d_array<float> shadowMap,
                           sampler shadowSampler)
{
    // **Radial distance, not planar view depth.** Slightly different cascade boundaries from the
    // textbook version, and better here: turning on the spot cannot move a surface between
    // cascades, so nothing pops as the player looks around.
    const float depth = distance(worldPosition, frame.cameraPosition);

    // The tightest cascade that still reaches this fragment, walking near to far.
    int cascade = kCascadeCount - 1;
    for (int i = 0; i < kCascadeCount; ++i) {
        if (depth < frame.cascadeSplits[i]) { cascade = i; break; }
    }

    float visibility = sampleCascade(frame, worldPosition, cascade, shadowMap, shadowSampler);

    // **Cross-fade into the next cascade over a band before the split.** Both cascades are
    // individually correct and the handover is still visible: they differ in texel size, so they
    // differ in filter footprint and in bias, and the same surface changes shadow softness within
    // one pixel. That reads as an arc drawn on the ground at a fixed distance, sweeping as the
    // player walks. The last cascade has nothing to fade into.
    if (cascade + 1 < kCascadeCount) {
        const float blendStart = frame.cascadeBlendStart[cascade];
        const float split = frame.cascadeSplits[cascade];
        const float t = saturate((depth - blendStart) / max(split - blendStart, 1e-4));
        if (t > 0.0) {
            visibility = mix(visibility,
                             sampleCascade(frame, worldPosition, cascade + 1, shadowMap, shadowSampler),
                             t);
        }
    }
    return visibility;
}

fragment float4 sampleFragment(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(1)]],
                               constant FrameUniforms &frame [[buffer(2)]],
                               depth2d_array<float> shadowMap [[texture(0)]],
                               texture2d<float> baseColorMap [[texture(1)]],
                               texture2d<float> normalMap [[texture(2)]],
                               texturecube<float> environmentSpecular [[texture(3)]],
                               texturecube<float> environmentIrradiance [[texture(4)]],
                               texture2d<float> ormMap [[texture(5)]],
                               texture2d<float> emissiveMap [[texture(6)]],
                               // **The whole scene's lights, and which of them reach each cluster.**
                               // Not a per-draw list: a fragment reads the cell it is actually in.
                               const device PunctualLight *sceneLights [[buffer(4)]],
                               const device uint2 *clusterRanges [[buffer(5)]],
                               const device uint *clusterIndices [[buffer(6)]],
                               depth2d<float> shadowAtlas [[texture(7)]],
                               depthcube_array<float> shadowCubes [[texture(8)]])
{
    // Declared here rather than bound: a comparison sampler is a constant of this shader, not
    // something the game has any reason to vary.
    constexpr sampler shadowSampler(mag_filter::linear, min_filter::linear,
                                    address::clamp_to_edge,
                                    compare_func::greater_equal);   // reversed-Z

    // **Mip filtering and anisotropy are what make a texture look textured.** Without mips the
    // ground shimmers as the camera moves; without anisotropy it turns to mush at a grazing angle,
    // which is most of the screen in a game played standing up.
    constexpr sampler surfaceSampler(mag_filter::linear, min_filter::linear,
                                     mip_filter::linear, address::repeat,
                                     max_anisotropy(8));

    // The texture is sRGB, so this is already linear — the GPU decoded it on the way in. The engine
    // decides that per slot; see `TextureSlot.isColor`.
    float4 base = baseColorMap.sample(surfaceSampler, in.uv)
                * uniforms.materialBaseColor
                * float4(uniforms.albedo, 1.0);

    // **Occlusion, roughness and metalness from one texture: R, G, B.** That is glTF's packing, and
    // the channel each slot reads is `TextureSlot.packedChannel` — USD names it per input and Model
    // I/O drops which, so the convention is assumed rather than read. It is also right for an
    // unpacked greyscale map, whose green channel is its value, which is why the convention holds.
    //
    // **Not sRGB.** These are numbers, not colour; decoded as sRGB a roughness of 0.5 arrives as 0.21
    // and the whole scene looks wet. `TextureSlot.isColor` decides that on the loading side.
    const float3 orm = ormMap.sample(surfaceSampler, in.uv).rgb;

    // Multiplied, so a surface with no map keeps its material's own values — the white fallback is
    // exactly the identity here.
    const float metallic = saturate(uniforms.materialParams.x * orm.b);
    // **Clamped away from zero.** A perfectly smooth surface is a delta function: the highlight is
    // infinitely small and infinitely bright, which on screen is a single flickering pixel that
    // crawls as the camera moves. Every renderer floors it somewhere.
    const float roughness = clamp(uniforms.materialParams.y * orm.g, 0.045, 1.0);
    const float alpha = roughness * roughness;

    // **Shading normal from the map, geometric normal kept for the shadow lookup.** Perturbing the
    // normal used to bias a shadow sample moves the sample off the surface it belongs to, and the
    // contact shadow detaches from its caster.
    const float3 geometric = normalize(in.normal);
    const float3 n = applyNormalMap(normalMap.sample(surfaceSampler, in.uv).xyz,
                                    geometric, in.tangent, in.handedness);

    const float3 v = normalize(frame.cameraPosition - in.worldPosition);
    const float3 l = normalize(uniforms.sunDirection);
    const float3 h = normalize(v + l);

    const float NdotV = saturate(dot(n, v)) + 1e-5;
    const float NdotL = saturate(dot(n, l));
    const float NdotH = saturate(dot(n, h));
    const float VdotH = saturate(dot(v, h));

    // **Dielectrics reflect about 4% head-on; metals reflect their own colour.** That single number
    // is most of what "metallic" means — a metal has no diffuse, because the light that would have
    // scattered is absorbed instead.
    const float3 f0 = mix(float3(0.04), base.rgb, metallic);
    const float3 diffuseColour = base.rgb * (1.0 - metallic);

    float visibility = dot(geometric, l) > 0.0
        ? sunVisibility(frame, in.worldPosition, shadowMap, shadowSampler)
        : 1.0;

    // **The level's sun, not a constant.** Radiance rather than a colour — far brighter than white,
    // which is what the HDR target and the tone map exist for. An overcast level says so by having a
    // dim sun and a bright sky, and that is now something a level file can express.
    const float3 incoming = uniforms.sunColour.rgb * NdotL * visibility;

    const float3 fresnel = fresnelSchlick(f0, VdotH);
    const float3 specular = fresnel
                          * distributionGGX(NdotH, alpha)
                          * visibilitySmithGGX(NdotV, NdotL, alpha);

    // **What is not reflected is what is available to scatter.** Skipping this makes a shiny surface
    // brighter than the light falling on it, which is the most common way a first PBR shader breaks
    // energy conservation. The metal term is already in `diffuseColour`, which is zero for metal.
    const float3 kD = 1.0 - fresnel;
    const float3 direct = (kD * diffuseColour / M_PI_F + specular) * incoming;

    // **Image-based lighting: the environment, convolved twice ahead of time.** The irradiance cube
    // is the whole hemisphere gathered with a cosine lobe — what a diffuse surface facing this way
    // receives. The specular cube's mips are the same environment gathered with a GGX lobe, one
    // roughness per level, so a rough surface reads a blurrier mip and a smooth one reads a sharper.
    constexpr sampler environmentSampler(mag_filter::linear, min_filter::linear,
                                         mip_filter::linear);

    // **Divided by pi, because irradiance is not radiance.** The cube holds the integral of incoming
    // light over the hemisphere; Lambert's BRDF is albedo/pi, and skipping the division makes every
    // ambient-lit surface pi times too bright.
    const float3 irradiance = environmentIrradiance.sample(environmentSampler, n).rgb;
    // **Occlusion applies to the ambient term only.** It stands for light a crevice does not receive
    // from its surroundings; applying it to the sun as well would darken a surface the sun is plainly
    // shining straight into, which is a shadow the shadow map already has an opinion about.
    const float occlusion = orm.r;
    const float3 ambientDiffuse = diffuseColour * irradiance / M_PI_F * occlusion;

    const float3 reflected = reflect(-v, n);
    const float lod = roughness * uniforms.materialParams.z;
    const float3 prefiltered = environmentSpecular.sample(environmentSampler, reflected,
                                                          level(lod)).rgb;
    const float3 ambientSpecular = prefiltered * environmentBRDF(f0, roughness, NdotV) * occlusion;

    // **Every lamp that reaches this draw, shaded with the same lobe as the sun.** A second lighting
    // model for local lights is how a scene ends up with two looks in it — the sun's highlights
    // sharp and the lamps' soft, for no reason a player could name.
    // **Which cell this fragment is in**, from its pixel and its view depth. The slicing here has to
    // be the same expression `ClusterGrid` uses, or a light is binned into a cell nothing reads.
    const float viewDepth = -(frame.view * float4(in.worldPosition, 1.0)).z;
    const uint tileX = min(uint(in.position.x / frame.viewportSize.x * float(frame.clusters.tilesX)),
                           frame.clusters.tilesX - 1);
    const uint tileY = min(uint(in.position.y / frame.viewportSize.y * float(frame.clusters.tilesY)),
                           frame.clusters.tilesY - 1);
    const float rawSlice = log(max(viewDepth, 1e-4)) * frame.clusters.sliceScale
                         + frame.clusters.sliceBias;
    const uint slice = uint(clamp(rawSlice, 0.0, float(frame.clusters.slices - 1)));
    const uint cluster = (slice * frame.clusters.tilesY + tileY) * frame.clusters.tilesX + tileX;

    const uint2 range = clusterRanges[cluster];

    float3 local = float3(0.0);
    for (uint entry = 0; entry < range.y; ++entry) {
        const uint i = clusterIndices[range.x + entry];
        const float3 toLight = sceneLights[i].positionAndRange.xyz - in.worldPosition;
        const float range_ = sceneLights[i].positionAndRange.w;
        const float distanceSquared = max(length_squared(toLight), 1e-4);

        // The same windowed inverse square as `PunctualLight.attenuation`, which is the definition.
        const float ratio = distanceSquared / max(range_ * range_, 1e-6);
        const float window = saturate(1.0 - ratio * ratio);
        const float attenuation = window * window / distanceSquared;
        if (attenuation <= 0.0) { continue; }

        const float3 lightDirection = toLight * rsqrt(distanceSquared);
        const float lampNdotL = saturate(dot(n, lightDirection));
        if (lampNdotL <= 0.0) { continue; }

        // **The cone, and the point light that is not one.** `-lightDirection` is the direction the
        // light travels; with a scale of 0 and an offset of 1 this is 1 everywhere, which is exactly
        // what a lamp with no cone should be. Squared so the edge eases in — a linear falloff still
        // shows the outer circle as a change of gradient.
        const float cosAngle = dot(-lightDirection, sceneLights[i].directionAndAngleScale.xyz);
        const float cone = saturate(cosAngle * sceneLights[i].directionAndAngleScale.w
                                  + sceneLights[i].colourAndAngleOffset.w);
        const float angular = cone * cone;
        if (angular <= 0.0) { continue; }

        const float3 lampHalf = normalize(v + lightDirection);
        const float3 lampFresnel = fresnelSchlick(f0, saturate(dot(v, lampHalf)));
        const float3 lampSpecular = lampFresnel
                                  * distributionGGX(saturate(dot(n, lampHalf)), alpha)
                                  * visibilitySmithGGX(NdotV, lampNdotL, alpha);
        const float3 lampDiffuse = (1.0 - lampFresnel) * diffuseColour / M_PI_F;

        // **A spot's own shadow map, from its tile of the atlas.** A point light carries no tile and
        // skips this — six faces is a different feature — so it still reaches through a wall.
        float lampVisibility = 1.0;
        if (sceneLights[i].shadowTile.w > 0.5) {
            const float4 lightClip = sceneLights[i].shadowViewProjection
                                   * float4(in.worldPosition, 1.0);
            if (lightClip.w > 0.0) {
                const float3 projected = lightClip.xyz / lightClip.w;
                // Clip space is −1…1 in x and y; texture space is 0…1 with y downwards.
                float2 uv = projected.xy * float2(0.5, -0.5) + 0.5;
                if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
                    // Into this light's own tile. **Everything outside the tile belongs to another
                    // lamp**, which is why the bounds test above is not optional: a sample that
                    // wandered would read a shadow from the wrong room.
                    uv = sceneLights[i].shadowTile.xy + uv * sceneLights[i].shadowTile.z;

                    // Reversed-Z: nearer the light is a larger value, so lit means greater.
                    const float reference = projected.z + kSpotDepthBias;
                    const float texel = sceneLights[i].shadowTile.z * kShadowAtlasTexel;
                    float sum = 0.0;
                    for (int y = -1; y <= 1; ++y) {
                        for (int x = -1; x <= 1; ++x) {
                            sum += shadowAtlas.sample_compare(shadowSampler,
                                                              uv + float2(x, y) * texel, reference);
                        }
                    }
                    lampVisibility = sum / 9.0;
                }
            }
        }
        // **A lamp that points nowhere reads its own cube, and the hardware picks the face.** The
        // direction is the whole coordinate — no tile, no uv, and no seam, because the sampler
        // filters across a face edge onto the correct neighbour instead of clamping.
        else if (sceneLights[i].shadowCube.w > 0.5) {
            const float3 fromLight = -toLight;
            const float3 a = abs(fromLight);
            const float major = max(a.x, max(a.y, a.z));

            // **The bias comes off the distance, not off the depth.** A face stores `near / distance`,
            // so a constant added to that is a different distance at every range; in texels — which
            // is what this is once multiplied out — it is one number everywhere.
            // **The face's texel size comes with the light**, not from a constant here: a face is a
            // 90° frustum, so its extent at distance `major` is `2 * major` and one texel is
            // `2 * major / size`. The `2 / size` half of that is what the light carries.
            const float texel = sceneLights[i].shadowCube.z;
            const float bias = max(kShadowCubeMinBias, major * texel * kShadowCubeBiasTexels);
            const float reference = sceneLights[i].shadowCube.y / max(major - bias, 1e-4);
            const uint slice = uint(sceneLights[i].shadowCube.x);

            // **Four taps, and they are directions rather than uv steps.** A cube has no second
            // texture coordinate to walk along, so the sample direction is nudged inside the plane
            // perpendicular to it. The nudge is one texel's worth of angle at the face's own scale.
            const float3 hint = (a.y >= major) ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
            const float3 tangent = normalize(cross(fromLight, hint));
            const float3 bitangent = normalize(cross(fromLight, tangent));
            const float3 step_ = (tangent + bitangent) * (major * texel);
            const float3 skew = (tangent - bitangent) * (major * texel);
            lampVisibility = 0.25
                * (shadowCubes.sample_compare(shadowSampler, fromLight + step_, slice, reference)
                 + shadowCubes.sample_compare(shadowSampler, fromLight - step_, slice, reference)
                 + shadowCubes.sample_compare(shadowSampler, fromLight + skew, slice, reference)
                 + shadowCubes.sample_compare(shadowSampler, fromLight - skew, slice, reference));
        }
        if (lampVisibility <= 0.0) { continue; }

        local += (lampDiffuse + lampSpecular) * sceneLights[i].colourAndAngleOffset.rgb
               * attenuation * angular * lampNdotL * lampVisibility;
    }

    // **Added, not lit.** Emission is light the surface makes, so nothing multiplies it: not the
    // sun's angle, not the shadow map, not the ambient occlusion. A glowing seam that dimmed when a
    // shadow crossed it would be a lamp that goes out when you stand in front of it.
    //
    // The map is sRGB like any colour, and its values pass 1 once the material's own emission scales
    // them — which is what makes a seam read as lit rather than as painted, because the tone map has
    // somewhere above white to roll it into.
    const float3 emitted = uniforms.emissive.rgb * emissiveMap.sample(surfaceSampler, in.uv).rgb;

    return float4(direct + local + ambientDiffuse + ambientSpecular + emitted, base.a);
}
