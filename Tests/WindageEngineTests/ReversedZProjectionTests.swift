//
//  ReversedZProjectionTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Guards the reversed-Z depth convention.
///
/// The engine maps the near plane to depth **1** and infinite distance to depth **0**, the opposite of
/// the conventional near-0/far-1 the Xcode template shipped with. Float depth holds most of its
/// precision near zero, so this puts the precision at range — which is the whole point of a game
/// about reading a target at 800 m.
///
/// This convention is spread across four places that must agree: this projection,
/// `depthCompareFunction = .greater`, `MTKView.clearDepth = 0`, and the depth format. Getting one
/// wrong renders nothing at all. These tests pin the one piece that is pure arithmetic; the other
/// three were verified with an occlusion query counting fragments that pass the depth test
/// (~380,000 per frame correct, 0 with a deliberately mismatched clear value).
struct ReversedZProjectionTests {

    private let fovy = Float.radians(fromDegrees: 65)
    private let aspect: Float = 16.0 / 9.0
    private let near: Float = 0.1

    /// Normalised device depth of a point on the view axis, `distance` metres in front of the
    /// camera. View space is right-handed, so the camera looks down **-z**.
    private func depth(atDistance distance: Float) -> Float {
        let projection = simd_float4x4(
            perspectiveFovY: fovy, aspectRatio: aspect, nearZ: near)
        let clip = projection * SIMD4<Float>(0, 0, -distance, 1)
        return clip.z / clip.w
    }

    @Test("The near plane sits at depth 1, not 0")
    func nearPlaneIsOne() {
        #expect(abs(depth(atDistance: near) - 1.0) < 1e-6)
    }

    @Test("Depth decreases with distance, and never leaves [0, 1]")
    func depthDecreasesMonotonically() {
        let distances: [Float] = [0.1, 1, 10, 100, 800, 3_000, 20_000]
        let depths = distances.map(depth(atDistance:))

        for d in depths {
            #expect(d >= 0.0 && d <= 1.0)
        }
        for (nearer, farther) in zip(depths, depths.dropFirst()) {
            #expect(nearer > farther)
        }
    }

    /// The far plane is infinite rather than merely large: depth approaches 0 asymptotically and
    /// nothing is ever clipped for being too distant. A finite far plane would return exactly 0 —
    /// or negative — somewhere out here.
    @Test("Nothing clips at sniping range, or far past it")
    func infiniteFarPlane() {
        #expect(depth(atDistance: 800) > 0)
        #expect(depth(atDistance: 100_000) > 0)
    }

    /// The precision claim, made concrete. Across the band this game actually shoots in, one metre
    /// of distance must be worth many *representable* float steps — that headroom is exactly what
    /// stops surfaces z-fighting at range.
    ///
    /// The yardstick is `ulp` at the depth value itself, not `ulpOfOne`. Reversed-Z depths out here
    /// are tiny (0.1/3000 ≈ 3.3e-5), and float spacing near 3e-5 is ~3e-12 — some five orders finer
    /// than spacing near 1.0. Measuring against the precision at 1.0 would understate the margin by
    /// that factor and fail a perfectly healthy projection, which is precisely the confusion
    /// reversed-Z exists to exploit.
    @Test("A metre at sniping range is worth many float steps")
    func precisionSurvivesAtRange() {
        for metres: Float in [500, 800, 1_500, 3_000] {
            let here = depth(atDistance: metres)
            let separation = here - depth(atDistance: metres + 1)
            #expect(separation > here.ulp * 100,
                    "at \(metres) m: separation \(separation) vs ulp \(here.ulp)")
        }
    }
}
