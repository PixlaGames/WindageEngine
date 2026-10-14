//
//  ToneMappingTests.swift
//  WindageEngineTests
//

import Foundation
import Testing
import simd
@testable import WindageEngine

/// **`ToneMapping.apply(_:)` is the definition and `ToneMapShaders.metal` transcribes it**, so these
/// pin specific numbers rather than only properties. Two copies of a formula is a real risk, and a
/// test that only checked "monotonic and starts at zero" would pass on the wrong curve.
@MainActor
struct ToneMappingTests {

    private let curves = ToneMapping.Curve.allCases

    @Test("Exposure is in stops: +1 doubles, −1 halves")
    func exposureIsPhotographic() {
        #expect(ToneMapping(exposureStops: 0).exposure == 1)
        #expect(ToneMapping(exposureStops: 1).exposure == 2)
        #expect(abs(ToneMapping(exposureStops: -1).exposure - 0.5) < 1e-6)
        #expect(abs(ToneMapping(exposureStops: -0.5).exposure - 0.7071) < 1e-3)
    }

    /// Black is black under any curve. A curve that lifts zero puts a grey fog over every shadow in
    /// the game, and it reads as a broken ambient term.
    @Test("Every curve leaves black alone")
    func blackStaysBlack() {
        for curve in curves {
            let result = ToneMapping(curve: curve).apply(.zero)
            #expect(simd_length(result) < 1e-6, "\(curve) lifted black")
        }
    }

    @Test("Every curve is monotonic and never leaves 0…1")
    func curvesAreMonotonicAndBounded() {
        for curve in curves {
            let mapping = ToneMapping(curve: curve)
            var previous: Float = -1
            for step in 0...200 {
                let input = Float(step) * 0.1               // 0 … 20, well past white
                let output = mapping.apply(SIMD3(repeating: input)).x
                #expect(output >= previous - 1e-6, "\(curve) is not monotonic at \(input)")
                #expect(output >= 0 && output <= 1, "\(curve) left 0…1 at \(input)")
                #expect(!output.isNaN, "\(curve) produced NaN at \(input)")
                previous = output
            }
        }
    }

    /// **What "no tone mapping" means**, kept so the difference can be measured rather than argued
    /// about: everything above 1 becomes the same white, which is why a bright surface and a very
    /// bright one arrive identical.
    @Test("Clamp is exactly clamping")
    func clampIsClamping() {
        let mapping = ToneMapping.off
        #expect(mapping.apply(SIMD3(repeating: 0.5)).x == 0.5)
        #expect(mapping.apply(SIMD3(repeating: 1.5)).x == 1)
        #expect(mapping.apply(SIMD3(repeating: 40)).x == 1)
    }

    /// **ACES brightens midtones by about a fifth**, which is the thing that surprises people
    /// switching it on — a scene tuned without a curve comes out lighter, not darker. Pinned,
    /// because it is also how a change to the six constants would show up.
    @Test("The ACES fit hits its known values")
    func acesMatchesItsFit() {
        let mapping = ToneMapping(curve: .aces)
        // Middle grey lifts from 0.18 to 0.267 — that is the fit, and it is why a scene tuned
        // without a curve looks *brighter* when one is switched on rather than darker.
        #expect(abs(mapping.apply(SIMD3(repeating: 0.18)).x - 0.26690) < 1e-4, "middle grey")
        #expect(abs(mapping.apply(SIMD3(repeating: 0.55)).x - 0.64671) < 1e-4)
        #expect(abs(mapping.apply(SIMD3(repeating: 1.00)).x - 0.80380) < 1e-4)
        // The shoulder: four times the light of white still is not white, which is the whole point.
        // **The fit passes 1 at about 6.6 and is clamped after that** — Narkowicz's curve is not
        // asymptotic, so the clamp in `apply` is doing real work rather than guarding an edge case.
        #expect(abs(mapping.apply(SIMD3(repeating: 4)).x - 0.97342) < 1e-4)
        #expect(mapping.apply(SIMD3(repeating: 8)).x == 1)
    }

    /// Reinhard's white point is the input it maps to 1. Get that wrong and the parameter means
    /// nothing.
    @Test("Reinhard maps its white point to white")
    func reinhardHitsWhite() {
        let mapping = ToneMapping(curve: .reinhard, whitePoint: 4)
        #expect(abs(mapping.apply(SIMD3(repeating: 4)).x - 1) < 1e-4)
        #expect(mapping.apply(SIMD3(repeating: 2)).x < 1)
    }

    @Test("Exposure is applied before the curve")
    func exposurePrecedesTheCurve() {
        let dark = ToneMapping(curve: .aces, exposureStops: -2).apply(SIMD3(repeating: 1)).x
        let bright = ToneMapping(curve: .aces, exposureStops: 2).apply(SIMD3(repeating: 1)).x
        #expect(dark < bright)
        // Two stops down on an input of 1 is the same as no change on an input of 0.25.
        let equivalent = ToneMapping(curve: .aces).apply(SIMD3(repeating: 0.25)).x
        #expect(abs(dark - equivalent) < 1e-5)
    }

    /// A channel-independent curve shifts hue as it compresses; the shader does the same thing, so a
    /// grey in has to be a grey out or the two are not the same transform.
    @Test("Grey stays grey")
    func greyStaysNeutral() {
        for curve in curves {
            let out = ToneMapping(curve: curve).apply(SIMD3(repeating: 0.7))
            #expect(abs(out.x - out.y) < 1e-6 && abs(out.y - out.z) < 1e-6)
        }
    }

    /// The shader reads these bytes directly. Padding written down rather than left to two compilers
    /// to agree about.
    @Test("The packed form is what the shader expects")
    func packedLayoutIsStable() {
        #expect(MemoryLayout<ToneMapping.Packed>.size == 16)
        let packed = ToneMapping(curve: .reinhard, exposureStops: 1, whitePoint: 3).packed
        #expect(packed.exposure == 2)
        #expect(packed.whitePoint == 3)
        #expect(packed.curve == ToneMapping.Curve.reinhard.shaderValue)
    }

    @Test("The default is ACES at no exposure change")
    func defaultIsAcesUnexposed() {
        #expect(ToneMapping.default.curve == .aces)
        #expect(ToneMapping.default.exposureStops == 0)
        #expect(ToneMapping.off.curve == .clamp)
    }

    /// `ToneMapShaders.metal` switches on these numbers; a game never sees them.
    @Test("Each curve's shader number is the one the shader switches on")
    func shaderValuesMatchTheShader() {
        #expect(ToneMapping.Curve.clamp.shaderValue == 0)
        #expect(ToneMapping.Curve.reinhard.shaderValue == 1)
        #expect(ToneMapping.Curve.aces.shaderValue == 2)
    }

    @Test("A tone mapping survives a round trip through JSON, the curve written by name")
    func codableRoundTrip() throws {
        let original = ToneMapping(curve: .reinhard, exposureStops: -1.25, whitePoint: 6)
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self).contains("\"reinhard\""))
        #expect(try JSONDecoder().decode(ToneMapping.self, from: data) == original)
    }

    @Test("Every key is optional: what a file leaves out is the default")
    func codableKeysAreOptional() throws {
        let decoded = try JSONDecoder().decode(ToneMapping.self, from: Data(#"{"exposureStops": -0.5}"#.utf8))
        #expect(decoded == ToneMapping(exposureStops: -0.5))
        #expect(try JSONDecoder().decode(ToneMapping.self, from: Data("{}".utf8)) == .default)
    }

    @Test("An unknown curve name is refused, not read as a default")
    func unknownCurveIsRefused() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ToneMapping.self, from: Data(#"{"curve": "filmic"}"#.utf8))
        }
    }
}
