//
//  ShadowCascades.swift
//  WindageEngine
//

import simd

/// Where the shadow cascades begin, end, and hand over to each other.
///
/// **Separated from the shadow *pass* because this is the half that can be wrong.** A texture, a
/// pipeline and an encoder either work or draw nothing; splits, per-cascade bias scaling and blend
/// bands draw a *plausible* picture when they are wrong — a seam, a crawling edge, a shadow detached
/// from its caster. That half wants tests, and tests should not want a GPU.
///
/// **Extracted 2026-09-09, and the extraction is what turned its constants into parameters.** It
/// was written for one valley: four splits ending at 850 m, because that was the longest shot in the
/// game that produced it. Nothing in the maths cares — but the numbers were `static let`s, so a
/// second game could have the mechanism only by taking a sniper range's geometry with it. A
/// courtyard sixty meters across wants splits an order of magnitude tighter, and would otherwise
/// spend 99% of every shadow texel on empty ground.
///
/// So this is a value you configure, and a game's own numbers live with the game.
public nonisolated struct ShadowCascades: Sendable, Equatable {

    /// The most cascades a set may have: the shader interface — ``splitVector`` and the rest — has four
    /// slots.
    public static let maximumCount = 4

    /// View-space distance at which each cascade stops applying, in world units.
    ///
    /// **Split roughly geometrically**, near band tight because that is where the eye judges
    /// contact, far band reaching as far as the game's longest sightline.
    public let splits: [Float]

    /// Texels per side of each cascade's slice. Here rather than with the texture because the texel
    /// *snapping* below needs it: the grid the light matrix rounds to is this fine.
    public let resolution: Int

    /// How far along the light axis the box reaches. Generous on purpose: a caster clipped out of
    /// the map does not shrink its shadow, it deletes it.
    public let lightDepthRange: Float

    /// How much of a cascade's own span is spent fading into the next one.
    ///
    /// **A hard handover is visible even when both cascades are individually correct.** They differ
    /// in texel size and therefore in filter footprint and depth bias, so at the split the same
    /// surface changes shadow softness and contact offset within one pixel — a seam that reads as an
    /// arc drawn on the ground at a fixed distance from the player, sweeping as they walk.
    ///
    /// The cost is two shadow lookups instead of one, and only for fragments inside the band.
    /// Wider hides the transition better and costs more; 12% of a span is enough to be invisible
    /// because the two results are already close — the seam is a discontinuity, not a large
    /// difference.
    public let blendFraction: Float

    /// Half-extent of a cascade's world box, as a fraction of that cascade's split distance.
    ///
    /// Less than one because the box is centered *ahead* of the camera rather than on it — see
    /// ``focusFraction`` — so it does not have to reach back to the eye.
    public let extentFraction: Float

    /// How far ahead of the camera each cascade's box is centered, as a fraction of its split.
    ///
    /// **Centered ahead rather than on the camera**, so the covered box is spent on what the player
    /// is looking at instead of half-wasted behind them.
    public let focusFraction: Float

    /// Constant depth bias, measured in shadow **texels**. Scale-free on purpose — see
    /// ``normalizedDepthBias(forCascade:)`` for what the alternative cost.
    public let biasTexels: Float

    /// The rasterizer's depth bias while recording, before ``biasScales`` scales it per cascade.
    ///
    /// Kept here beside ``biasScales`` rather than passed at the call site: the numbers are one tuning,
    /// and a pass that scaled one of them independently would be tuned against nothing.
    public let rasterBias: ShadowBias

    /// - Precondition: one to ``maximumCount`` splits, each positive, finite and further than the one
    ///   before; a positive resolution and light depth range. Past four, the fifth cascade was
    ///   recorded and never read, or stopped the program reading its bias; out of order, a cascade
    ///   covered a band no fragment chooses.
    public init(splits: [Float],
                resolution: Int = 2048,
                lightDepthRange: Float = 1500,
                blendFraction: Float = 0.12,
                extentFraction: Float = 0.62,
                focusFraction: Float = 0.45,
                biasTexels: Float = 1.5,
                rasterBias: ShadowBias = .cascades) {
        precondition(!splits.isEmpty, "a cascade set needs at least one split")
        precondition(splits.count <= ShadowCascades.maximumCount,
                     "a cascade set has at most \(ShadowCascades.maximumCount) splits, given \(splits.count)")
        precondition(splits.allSatisfy { $0.isFinite && $0 > 0 },
                     "cascade splits must be positive and finite: \(splits)")
        precondition(zip(splits, splits.dropFirst()).allSatisfy { $0 < $1 },
                     "cascade splits must increase, nearest first: \(splits)")
        precondition(resolution > 0, "a cascade's resolution must be positive, given \(resolution)")
        precondition(lightDepthRange.isFinite && lightDepthRange > 0,
                     "the light depth range must be positive, given \(lightDepthRange)")
        self.splits = splits
        self.resolution = resolution
        self.lightDepthRange = lightDepthRange
        self.blendFraction = blendFraction
        self.extentFraction = extentFraction
        self.focusFraction = focusFraction
        self.biasTexels = biasTexels
        self.rasterBias = rasterBias
    }

    public var count: Int { splits.count }

    /// Half-extent of the world box each cascade covers.
    public func extent(forCascade index: Int) -> Float { splits[index] * extentFraction }

    /// World units covered by one shadow texel in this cascade.
    public func texelSize(forCascade index: Int) -> Float {
        (2 * extent(forCascade: index)) / Float(resolution)
    }

    /// How many cascades an object of this size is worth recording into, counting from the nearest.
    ///
    /// **A caster narrower than a shadow texel cannot cast a shadow — it can only cast noise.** With
    /// a far cascade spanning half a kilometer across 2048 texels, a half-meter stone is two thirds
    /// of one texel: recording it costs a draw and produces at best a flickering speck.
    ///
    /// Derived from the texel size rather than assigned per object type, so it stays right if the
    /// splits or the resolution ever move. A third of the object's width is the threshold — below
    /// that, filtering has nothing to work with.
    public func cascadeCount(forCasterOfSize size: Float) -> Int {
        var count = 0
        for index in 0..<self.count where texelSize(forCascade: index) <= size / 3 {
            count = index + 1
        }
        // At least the nearest cascade: something is better than an object with no contact shadow
        // at all, which reads as floating.
        return max(1, count)
    }

    /// The view depth at which a cascade starts giving way to the next.
    ///
    /// Measured from each cascade's **own span**, not from zero. The bands are geometric, so a fixed
    /// fraction of the far split would be wider than the entire near cascade.
    public func blendStart(forCascade index: Int) -> Float {
        let near = index == 0 ? 0 : splits[index - 1]
        return splits[index] - (splits[index] - near) * blendFraction
    }

    /// The four-cascade shader interface. **Fewer than four cascades repeats the last entry**, which
    /// is not a fudge: the shader picks a cascade by comparing view depth against these distances, so
    /// a repeated split is a band of zero width and is never chosen. More than four cannot be made —
    /// the shader has four slots.
    private func vector(_ value: (Int) -> Float) -> SIMD4<Float> {
        SIMD4(value(min(0, count - 1)), value(min(1, count - 1)),
              value(min(2, count - 1)), value(min(3, count - 1)))
    }

    /// Depth bias multiplier per cascade, relative to the near one.
    ///
    /// A cascade covering 8× the world per texel needs roughly 8× the bias: the depth error within
    /// one texel scales with how much world that texel spans. One constant for all four either
    /// leaves acne in the far cascades or detaches contact shadows in the near one.
    public var biasScales: SIMD4<Float> {
        let base = extent(forCascade: 0)
        return vector { extent(forCascade: $0) / base }
    }

    public var splitVector: SIMD4<Float> { vector { splits[$0] } }

    /// Constant depth bias for a cascade, in the light's **normalized** depth units — what a shader
    /// adds to a fragment's own depth before comparing it against the recorded occluder.
    ///
    /// **Derived from the texel's world size, not from a tuned constant, and that is a fix rather
    /// than a flourish.** The depth error inside one shadow texel is proportional to how much world
    /// that texel spans, so the bias has to be too. It shipped as a literal `0.00035 *
    /// cascadeBiasScale` in normalized units, which silently coupled it to ``lightDepthRange``: the
    /// same literal is a *centimeter* in a scene 30 m deep and **16 meters** in one ranged to 1500,
    /// and 16 meters of bias deletes every shadow in a courtyard. Extracting this from the game it
    /// was tuned in is what made that visible — nothing was wrong while there was only one scale.
    ///
    /// `biasTexels` is therefore in texels, which is scale-free.
    public func normalizedDepthBias(forCascade index: Int) -> Float {
        (texelSize(forCascade: index) * biasTexels) / (2 * lightDepthRange)
    }

    /// The four-cascade shader interface for ``normalizedDepthBias(forCascade:)``.
    public var depthBiasVector: SIMD4<Float> { vector { normalizedDepthBias(forCascade: $0) } }

    public var blendStartVector: SIMD4<Float> { vector { blendStart(forCascade: $0) } }

    /// The sun's own view matrix. Position is irrelevant to a directional light; only the axis is.
    private func lightView(sunDirection: SIMD3<Float>) -> simd_float4x4 {
        let forward = -sunDirection
        var upHint = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, upHint)) > 0.99 { upHint = SIMD3(0, 0, 1) }
        let right = simd_normalize(simd_cross(upHint, forward))
        let up = simd_cross(forward, right)

        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(0, 0, 0, 1)      // eye at the world origin: a fixed frame
        ))
    }

    /// World-to-light-clip per cascade, reversed-Z like the main pass.
    public func cascadeMatrices(cameraPosition: SIMD3<Float>,
                                cameraForward: SIMD3<Float>,
                                sunDirection: SIMD3<Float>) -> [simd_float4x4] {
        let view = lightView(sunDirection: sunDirection)

        return (0..<count).map { index in
            let extent = extent(forCascade: index)

            // Centre each cascade ahead of the camera rather than on it, so the covered box is
            // spent on what the player is looking at instead of half-wasted behind them.
            let focus = cameraPosition + cameraForward * (splits[index] * focusFraction)
            let focusInLight = view * SIMD4<Float>(focus, 1)

            // Snap to whole texels in the *fixed* light frame. This is what stops shadow edges
            // crawling as the camera moves: the sampling grid now advances in texel steps rather
            // than sliding continuously.
            let texelWorldSize = (2 * extent) / Float(resolution)
            let centerX = (focusInLight.x / texelWorldSize).rounded() * texelWorldSize
            let centerY = (focusInLight.y / texelWorldSize).rounded() * texelWorldSize

            let near = -lightDepthRange
            let far = lightDepthRange

            // Orthographic, reversed-Z: near maps to 1 and far to 0, matching the main pass so the
            // codebase has exactly one depth convention.
            var projection = simd_float4x4(0)
            projection.columns.0.x = 1 / extent
            projection.columns.1.y = 1 / extent
            projection.columns.2.z = 1 / (far - near)
            projection.columns.3.x = -centerX / extent
            projection.columns.3.y = -centerY / extent
            projection.columns.3.z = 1 + near / (far - near)
            projection.columns.3.w = 1

            return simd_mul(projection, view)
        }
    }
}
