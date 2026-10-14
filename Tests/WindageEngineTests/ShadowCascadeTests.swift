//
//  ShadowCascadeTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Guards the shadow cascades, and in particular the texel snapping.
///
/// **Moved here with the code, not rewritten from it.** The studio's own rule: extracting maths by
/// retyping it from memory produced a light basis and an orthographic projection that were both
/// wrong and both looked plausible.
struct ShadowCascadeTests {

    /// The set these tests were written against — a long-range outdoor game's, kept verbatim so the
    /// extraction is checkable against the behaviour it had before it moved.
    private let cascades = ShadowCascades(splits: [30, 90, 260, 850])

    private let sun = simd_normalize(SIMD3<Float>(-0.42, 0.72, -0.55))
    private let forward = SIMD3<Float>(0, 0, -1)

    private func matrices(at position: SIMD3<Float>) -> [matrix_float4x4] {
        cascades.cascadeMatrices(cameraPosition: position, cameraForward: forward, sunDirection: sun)
    }

    /// **The regression this exists for.** Shadow edges crawled while moving, because the light's
    /// frame was rebuilt around the camera each frame — so snapping to texels inside a frame that
    /// was itself sliding stabilised nothing.
    ///
    /// Sweeping the camera across one texel's worth of world must produce at most **two** distinct
    /// matrices: one before the rounding boundary and one after. Continuous movement of the box
    /// would produce a different matrix at every sample.
    @Test("Sub-texel camera movement does not slide the shadow box")
    func snappingHoldsTheBoxStill() {
        let texel = (2 * cascades.extent(forCascade: 0)) / Float(cascades.resolution)

        var distinct: [matrix_float4x4] = []
        for step in 0..<64 {
            let offset = texel * Float(step) / 64
            let matrix = matrices(at: SIMD3(offset, 0, offset))[0]
            if !distinct.contains(where: { $0 == matrix }) { distinct.append(matrix) }
        }

        #expect(distinct.count <= 2, "Expected the snapped box to hold still, got \(distinct.count) positions")
    }

    /// Moving far enough *should* move the box — snapping must not freeze it altogether.
    @Test("Moving a long way does move the box")
    func largeMovementMovesTheBox() {
        #expect(matrices(at: .zero)[0] != matrices(at: SIMD3(50, 0, 0))[0])
    }

    /// Cascades exist so the far field is covered at all. A target at sniping range must fall
    /// inside the last cascade's box.
    @Test("The far cascade reaches sniping range")
    func farCascadeCoversDistance() {
        let matrix = matrices(at: .zero)[cascades.count - 1]
        let target = SIMD3<Float>(0, 0, -800)     // 800 m down the camera's forward axis
        let clip = matrix * SIMD4<Float>(target, 1)

        #expect(abs(clip.x) <= 1.0)
        #expect(abs(clip.y) <= 1.0)
        // Reversed-Z: inside the light's depth range means strictly between 0 and 1.
        #expect(clip.z > 0 && clip.z < 1)
    }

    /// A near-field point must land in cascade 0, or the tight map is being wasted.
    @Test("Near geometry falls inside the tightest cascade")
    func nearCascadeCoversNearField() {
        let matrix = matrices(at: .zero)[0]
        let clip = matrix * SIMD4<Float>(SIMD3<Float>(0, 0, -10), 1)
        #expect(abs(clip.x) <= 1.0)
        #expect(abs(clip.y) <= 1.0)
    }

    @Test("Cascades grow with distance, and bias grows with them")
    func cascadesAndBiasScaleTogether() {
        for i in 1..<cascades.count {
            #expect(cascades.extent(forCascade: i) > cascades.extent(forCascade: i - 1))
            #expect(cascades.biasScales[i] > cascades.biasScales[i - 1])
        }
        #expect(cascades.biasScales[0] == 1)
    }

    @Test("Splits are ordered and reach past the game's range")
    func splitsAreSane() {
        #expect(cascades.splits == cascades.splits.sorted())
        #expect(cascades.splits.last! >= 800)
    }

    // MARK: - Cascade blending

    /// The band must lie **inside its own cascade**, or a fragment starts fading toward the next
    /// cascade before the current one is even responsible for it.
    @Test("Each blend band sits inside its own cascade")
    func blendBandIsInsideItsCascade() {
        for index in 0..<cascades.count {
            let near = index == 0 ? Float(0) : cascades.splits[index - 1]
            let start = cascades.blendStart(forCascade: index)
            #expect(start > near, "cascade \(index) starts blending before it starts applying")
            #expect(start < cascades.splits[index], "cascade \(index) blend band has no width")
        }
    }

    /// **Measured against each cascade's own span, not against zero.**
    ///
    /// The splits are geometric, so a fixed fraction of the *far* split would produce a band for
    /// cascade 3 that is wider than cascades 0, 1 and 2 put together — the near cascades would spend
    /// their whole existence cross-fading.
    @Test("Band width is a fraction of the cascade's own span")
    func bandScalesWithItsOwnSpan() {
        for index in 0..<cascades.count {
            let near = index == 0 ? Float(0) : cascades.splits[index - 1]
            let span = cascades.splits[index] - near
            let width = cascades.splits[index] - cascades.blendStart(forCascade: index)
            #expect(abs(width - span * cascades.blendFraction) < 1e-3,
                    "cascade \(index) band is \(width) m of a \(span) m span")
            #expect(width < span, "a band cannot be wider than the cascade it lives in")
        }
    }

    /// The blend factor the shader computes must run 0 → 1 across the band and clamp outside it.
    /// Reproduced here because getting it backwards produces a *plausible* picture — the handover
    /// simply moves rather than disappearing.
    @Test("The blend factor runs zero to one across the band")
    func blendFactorIsMonotone() {
        let index = 1
        let start = cascades.blendStart(forCascade: index)
        let split = cascades.splits[index]

        func factor(atDepth depth: Float) -> Float {
            min(1, max(0, (depth - start) / (split - start)))
        }

        #expect(factor(atDepth: start - 1) == 0, "blending must not begin before the band")
        #expect(factor(atDepth: start) == 0)
        #expect(abs(factor(atDepth: (start + split) / 2) - 0.5) < 1e-3)
        #expect(factor(atDepth: split) == 1, "the far edge must hand over completely")
        #expect(factor(atDepth: split + 100) == 1, "and stay handed over beyond it")

        var previous: Float = -1
        for step in 0...20 {
            let depth = start + (split - start) * Float(step) / 20
            let value = factor(atDepth: depth)
            #expect(value >= previous, "the factor doubled back at \(depth) m")
            previous = value
        }
    }

    /// The vector handed to the shader has to agree with the function, or the seam moves to a
    /// distance nothing accounts for.
    @Test("The blend vector matches the per-cascade function")
    func blendVectorMatchesFunction() {
        let vector = cascades.blendStartVector
        for index in 0..<cascades.count {
            #expect(vector[index] == cascades.blendStart(forCascade: index))
        }
    }

    /// Blend bands must not overlap the next cascade's band, or three cascades contribute at once
    /// and the shader — which mixes exactly two — is quietly wrong.
    @Test("Bands do not reach into the next cascade's band")
    func bandsDoNotOverlap() {
        for index in 0..<(cascades.count - 1) {
            #expect(cascades.splits[index] <= cascades.blendStart(forCascade: index + 1),
                    "cascade \(index) is still blending when \(index + 1) starts to")
        }
    }

    // MARK: - Which cascades a caster is worth recording into

    /// Something large must still be recorded everywhere. Clipping a mast or a plate out of the far
    /// cascade would delete its shadow at exactly the range the player is shooting at.
    @Test("A large caster is recorded into every cascade")
    func largeCastersUseEveryCascade() {
        #expect(cascades.cascadeCount(forCasterOfSize: 4) == cascades.count)
        #expect(cascades.cascadeCount(forCasterOfSize: 40) == cascades.count)
    }

    /// And something tiny must not be, or hundreds of stones cost hundreds of draws per cascade to
    /// produce a speck narrower than a texel.
    @Test("Small scatter is dropped from the far cascades")
    func smallCastersAreDropped() {
        let stone = cascades.cascadeCount(forCasterOfSize: 0.4)
        #expect(stone >= 1, "everything keeps its contact shadow, or it reads as floating")
        #expect(stone < cascades.count, "a 0.4 m stone is sub-texel in the far cascade")
    }

    @Test("Bigger casters never get fewer cascades")
    func budgetIsMonotone() {
        var previous = 0
        for step in 1...60 {
            let count = cascades.cascadeCount(forCasterOfSize: Float(step) * 0.1)
            #expect(count >= previous, "a larger caster got fewer cascades at \(Float(step) * 0.1) m")
            previous = count
        }
    }

    /// The rule itself: a cascade is only used when its texels can actually resolve the caster.
    @Test("Every granted cascade can resolve the caster")
    func grantedCascadesCanResolve() {
        for step in 1...40 {
            let size = Float(step) * 0.15
            let granted = cascades.cascadeCount(forCasterOfSize: size)
            // The nearest cascade is always granted, so only check the ones chosen on merit.
            for index in 1..<granted {
                #expect(cascades.texelSize(forCascade: index) <= size / 3,
                        "cascade \(index) cannot resolve a \(size) m caster")
            }
        }
    }

    // MARK: - Depth bias

    /// **The bug this pins deleted every shadow in a small scene, and nothing said so.** The bias
    /// was a literal in the light's *normalised* depth units, which silently coupled it to
    /// `lightDepthRange`: the same literal is a centimetre in a scene ranged to 30 and sixteen
    /// metres in one ranged to 1500. A cascade set built for a courtyard drew shadow maps correctly
    /// and then biased every fragment to "lit".
    @Test("The depth bias means the same thing in world units at any light depth range")
    func biasIsScaleFree() {
        let splits: [Float] = [30, 90, 260, 850]
        let shallow = ShadowCascades(splits: splits, lightDepthRange: 200)
        let deep = ShadowCascades(splits: splits, lightDepthRange: 1500)

        for index in 0..<shallow.count {
            let shallowWorld = shallow.normalizedDepthBias(forCascade: index) * 2 * 200
            let deepWorld = deep.normalizedDepthBias(forCascade: index) * 2 * 1500
            #expect(abs(shallowWorld - deepWorld) < 1e-5,
                    "cascade \(index): \(shallowWorld) m against \(deepWorld) m")
        }
    }

    /// The depth error inside one shadow texel is proportional to how much world that texel spans,
    /// so the bias has to be too — which is what makes it expressible in texels at all.
    @Test("The bias is a fixed number of texels, whatever the scene's scale")
    func biasIsAFixedNumberOfTexels() {
        for cascades in [ShadowCascades(splits: [8, 22, 55, 120], resolution: 1024, lightDepthRange: 200),
                         ShadowCascades(splits: [30, 90, 260, 850])] {
            for index in 0..<cascades.count {
                let world = cascades.normalizedDepthBias(forCascade: index) * 2 * cascades.lightDepthRange
                let texels = world / cascades.texelSize(forCascade: index)
                #expect(abs(texels - cascades.biasTexels) < 1e-3,
                        "cascade \(index) biases by \(texels) texels, not \(cascades.biasTexels)")
            }
        }
    }

    /// A courtyard and a sniper range are not the same scene, and the whole reason this is a value
    /// rather than a set of constants is that they must be able to differ.
    @Test("A small scene gets a far finer bias than a large one")
    func aSmallSceneGetsAFinerBias() {
        let courtyard = ShadowCascades(splits: [8, 22, 55, 120], resolution: 1024, lightDepthRange: 200)
        let valley = ShadowCascades(splits: [30, 90, 260, 850])
        for index in 0..<4 {
            #expect(courtyard.texelSize(forCascade: index) < valley.texelSize(forCascade: index))
        }
    }
}

/// **Splits are checked where they are made.** Past four, the shader's four slots dropped the rest — or
/// reading the fifth cascade's bias stopped the program mid-frame; out of order, a cascade covered a band
/// no fragment chooses.
struct ShadowCascadeValidationTests {

    @Test("Four increasing splits are accepted, and the set compares by value")
    func fourIncreasingSplitsAreFine() {
        let a = ShadowCascades(splits: [8, 22, 55, 120])
        #expect(a.count == ShadowCascades.maximumCount)
        #expect(a == ShadowCascades(splits: [8, 22, 55, 120]))
        #expect(a != ShadowCascades(splits: [8, 22, 55, 121]))
        #expect(a.rasterBias == .cascades)
    }

    @Test("More than four splits stop at the init")
    func moreThanFourStops() async {
        await #expect(processExitsWith: .failure) {
            _ = ShadowCascades(splits: [5, 10, 20, 40, 80])
        }
    }

    @Test("Splits out of order stop at the init")
    func unsortedStops() async {
        await #expect(processExitsWith: .failure) {
            _ = ShadowCascades(splits: [30, 10, 90])
        }
    }

    @Test("A split that is not positive stops at the init")
    func nonPositiveStops() async {
        await #expect(processExitsWith: .failure) {
            _ = ShadowCascades(splits: [0, 10])
        }
    }
}
