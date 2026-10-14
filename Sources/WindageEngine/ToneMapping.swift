//
//  ToneMapping.swift
//  WindageEngine
//

import simd

/// How radiance becomes a picture: an exposure, and a curve that fits an unbounded range into the
/// zero-to-one a display can show.
///
/// ### Why an engine owes a curve
///
/// **Shading produces values above 1.** A surface lit by the sun and reflecting a specular highlight
/// is genuinely brighter than white paper, and once ambient, direct and specular are summed the
/// result routinely passes 1.0. Written straight to an 8-bit display buffer, everything above 1
/// clips to exactly the same white — so a chrome highlight, a lamp and a sheet of paper all arrive
/// as the same flat patch, and the brightest, most informative part of the image is the part that
/// carries no information at all.
///
/// It is not a stylistic addition. A renderer that produces HDR and writes it to an LDR target is
/// **incomplete**, and the symptom — blown highlights, a plasticky look, colors that shift towards
/// white as they brighten — reads as bad art rather than as a missing pass.
///
/// ### What is here and what is not
///
/// An exposure and a curve. **No auto-exposure**: metering the frame, deciding what "correctly
/// exposed" means for a game, and smoothing the adaptation over time are genuinely contested — every
/// engine does it differently and a game's needs decide it. **No bloom, no color grading, no
/// vignette.** Those are a look; this is the part without which there is no picture.
///
/// **`Codable`**, as `{"curve": "aces", "exposureStops": 0, "whitePoint": 4}`, every key optional, so a
/// game can keep its look in a file. The curve is written by name; the number a shader selects it by is
/// the engine's own business.
public nonisolated struct ToneMapping: Sendable, Equatable, Codable {

    /// The curve applied after exposure.
    public enum Curve: String, Sendable, CaseIterable, Codable {
        /// Clamp. **Not a curve** — it is what happens with no tone mapping at all, kept so the
        /// difference can be seen rather than argued about.
        case clamp

        /// Reinhard, extended with a white point: `x (1 + x/w²) / (1 + x)`.
        ///
        /// The gentlest of these and the most washed out. Preserves hue exactly — it scales all three
        /// channels by the same factor — which is either its virtue or its problem depending on
        /// whether a very bright saturated color should stay saturated.
        case reinhard

        /// The ACES filmic curve, Narkowicz's fit.
        ///
        /// **The default, and the industry's.** Six constants standing in for a much larger transform,
        /// accurate enough that the difference is invisible in a game and cheap enough to run per
        /// pixel. Rolls the shoulder off gradually and lets very bright colors desaturate towards
        /// white, which is what film does and what the eye reads as "bright" rather than "clipped".
        case aces

        /// What `ToneMapShaders.metal` switches on. Internal: a game names a curve, never its number.
        var shaderValue: UInt32 {
            switch self {
            case .clamp: 0
            case .reinhard: 1
            case .aces: 2
            }
        }
    }

    public var curve: Curve

    /// Exposure in **stops**, photographic: +1 doubles the light, −1 halves it.
    ///
    /// Stops rather than a multiplier because that is how brightness is actually reasoned about, and
    /// because the useful range is small and symmetric — roughly −4 to +4 — where a multiplier's is
    /// 0.06 to 16 and reads as arbitrary.
    public var exposureStops: Float

    /// The value that the ``Curve/reinhard`` curve maps to white. Ignored by the others.
    public var whitePoint: Float

    public static let `default` = ToneMapping()

    /// No exposure change and no curve — every value clamped, which is what a renderer does when it
    /// has no tone mapping. Useful for a comparison and for nothing else.
    public static let off = ToneMapping(curve: .clamp, exposureStops: 0)

    public init(curve: Curve = .aces, exposureStops: Float = 0, whitePoint: Float = 4) {
        self.curve = curve
        self.exposureStops = exposureStops
        self.whitePoint = whitePoint
    }

    private enum CodingKeys: String, CodingKey { case curve, exposureStops, whitePoint }

    /// Every key optional: a file that says only `{"exposureStops": -0.5}` is the default look, darker.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ToneMapping()
        self.init(curve: try container.decodeIfPresent(Curve.self, forKey: .curve) ?? fallback.curve,
                  exposureStops: try container.decodeIfPresent(Float.self, forKey: .exposureStops)
                      ?? fallback.exposureStops,
                  whitePoint: try container.decodeIfPresent(Float.self, forKey: .whitePoint)
                      ?? fallback.whitePoint)
    }

    /// The linear multiplier the exposure amounts to.
    public var exposure: Float { exp2(exposureStops) }

    /// The curve, on the CPU.
    ///
    /// **This is the definition; `ToneMapShaders.metal` is a transcription of it.** Two copies of a
    /// formula is a real risk, and the alternative — no Swift version — means the curve cannot be
    /// tested at all without a GPU and a way to read pixels back. The tests below pin specific
    /// input-output pairs, so a change to one copy and not the other is at least visible in the
    /// numbers rather than only on screen.
    ///
    /// A game can also call it: picking an interface color that matches a tone-mapped scene means
    /// running the scene's own curve, and doing it by eye against a screenshot goes stale the moment
    /// the exposure moves.
    public func apply(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let exposed = color * exposure
        switch curve {
        case .clamp:
            return simd_clamp(exposed, .zero, .one)
        case .reinhard:
            let w2 = max(whitePoint * whitePoint, 1e-6)
            let mapped = exposed * (1 + exposed / w2) / (1 + exposed)
            return simd_clamp(mapped, .zero, .one)
        case .aces:
            // Narkowicz 2015, "ACES Filmic Tone Mapping Curve".
            let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
            let numerator = exposed * (a * exposed + b)
            let denominator = exposed * (c * exposed + d) + e
            return simd_clamp(numerator / denominator, .zero, .one)
        }
    }

    /// What the shader reads. **Sixteen bytes with the padding written down**, so the two sides
    /// cannot disagree about where the curve selector sits.
    struct Packed {
        var exposure: Float
        var whitePoint: Float
        var curve: UInt32
        var padding: UInt32 = 0
    }

    var packed: Packed {
        Packed(exposure: exposure, whitePoint: whitePoint, curve: curve.shaderValue)
    }
}
