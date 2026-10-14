//
//  EngineMark.swift
//  WindageEngine
//

import simd

/// The engine's own mark: **the Drift W** — the initial, with the windage dialled in.
///
/// ### Why the engine has one at all
///
/// An engine is a thing other people ship with, and every engine that is says so somewhere — a splash,
/// a credit, a logo in a corner. **Nothing in `LICENSE` requires it**, which makes this a choice about
/// what the engine is rather than an obligation to encode. ``SplashScreen`` is the surface that shows
/// it; this is the drawing.
///
/// ### What it is a picture of
///
/// *Windage* is the sideways carry of a shot, and the correction dialled against it. The mark is a W
/// drawn as one continuous stroke whose **right half is carried up by ``offset``** — 16% of its own
/// height. The middle apex sits well below both shoulders, which is what makes it read as a W and not
/// as two Vs; the lift is the windage.
///
/// **What it replaced (2026-09-15).** The mark before it was a diagram: a thin rule, a curve and two squares,
/// 2.4 times as wide as it was high. It read as a chart going up, it had no silhouette at a browser
/// tab's size, and it could not be an app icon. Directions drawn before settling here, and why each
/// lost, are recorded in `Brand/README.md`.
///
/// ### The geometry is constructed, so there is one drawing of it
///
/// ``outline`` is built from five points on the stroke's center line and a stroke width measured
/// across, as type is — each arm's edges are its center line moved half the width either way, every
/// corner is where two of those edges meet, and every end is cut flat. **It is the only description of
/// the mark**: ``draw(into:origin:height:color:)`` fills it, every file in `Brand/` is written from it,
/// and `EngineMarkTests` fails if a file and this disagree. Redrawing the mark means changing a number
/// here and re-recording, never touching two places.
///
/// ### It has no hue, and that is deliberate
///
/// The studio's brand rules give each title a color lane, and a title's accent outranks everything
/// inside that title. **This mark appears inside somebody else's game**, so a hue of its own would be
/// a second brand competing with the one the player came for. Achromatic, in two tones: ``display`` on
/// dark grounds, ``deep`` on light ones. An accent on the carried half was drawn and dropped: it made
/// the letter look like two pieces, which is the thing the drawing works hardest not to be.
public nonisolated enum EngineMark {

    /// How far the right half is carried up, as a share of the mark's height.
    ///
    /// **16%, and about as far as it goes.** At 10% the lift passed for a lean or an italic; much past
    /// 20% the stroke down into the right-hand valley shortens to a stub and the valley reads as a
    /// notch, which is where the W stops being one letter.
    static let offset: Float = 0.16

    /// The mark is square.
    static let aspect: Float = 1

    /// The mark's width at a given height.
    public static func width(forHeight height: Float) -> Float { height * aspect }

    /// The outline, **in a unit square with its origin at the top left** — y downward, the same as
    /// ``HUDRenderer``. Thirteen points, in order round the letter, starting at the left shoulder.
    public static let outline: [SIMD2<Float>] = outline(offset: offset)

    /// The construction, with the lift as a parameter so a test can draw the same letter level.
    static func outline(offset: Float) -> [SIMD2<Float>] {
        // The centre line: left shoulder, left valley, middle apex, right valley, right shoulder.
        let left = SIMD2<Float>(0.12, 0.22), leftValley = SIMD2<Float>(0.31, 0.90), apex = SIMD2<Float>(0.50, 0.46)
        let lift = SIMD2<Float>(0, offset)
        let rightValley = SIMD2<Float>(0.69, 0.90) - lift, right = SIMD2<Float>(0.88, 0.22) - lift
        let half: Float = 0.085

        typealias Edge = (SIMD2<Float>, SIMD2<Float>)
        func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ dx: Float) -> Edge {
            (a + SIMD2(dx, 0), b + SIMD2(dx, 0))
        }
        func meet(_ e: Edge, _ f: Edge) -> SIMD2<Float> { intersection(e.0, e.1, f.0, f.1) }
        func cut(_ e: Edge, atY y: Float) -> SIMD2<Float> { intersection(e.0, e.1, SIMD2(-10, y), SIMD2(10, y)) }

        return [
            SIMD2(left.x - half, left.y), SIMD2(left.x + half, left.y),
            meet(edge(left, leftValley, half), edge(leftValley, apex, -half)),
            cut(edge(leftValley, apex, -half), atY: apex.y), cut(edge(apex, rightValley, half), atY: apex.y),
            meet(edge(apex, rightValley, half), edge(rightValley, right, -half)),
            SIMD2(right.x - half, right.y), SIMD2(right.x + half, right.y),
            cut(edge(rightValley, right, half), atY: rightValley.y), cut(edge(apex, rightValley, -half), atY: rightValley.y),
            meet(edge(apex, rightValley, -half), edge(leftValley, apex, half)),
            cut(edge(leftValley, apex, half), atY: leftValley.y), cut(edge(left, leftValley, -half), atY: leftValley.y),
        ]
    }

    /// Where the lines through `a1 a2` and `b1 b2` cross.
    static func intersection(_ a1: SIMD2<Float>, _ a2: SIMD2<Float>, _ b1: SIMD2<Float>, _ b2: SIMD2<Float>) -> SIMD2<Float> {
        let d = (a1.x - a2.x) * (b1.y - b2.y) - (a1.y - a2.y) * (b1.x - b2.x)
        let t = ((a1.x - b1.x) * (b1.y - b2.y) - (a1.y - b1.y) * (b1.x - b2.x)) / d
        return a1 + t * (a2 - a1)
    }

    /// The tone for dark grounds — a game, a store capsule, a splash.
    public static let display = InterfaceColor(hex: 0xF2F4F7)

    /// The tone for light grounds — a page, a printed mark, anything that must meet a contrast ratio.
    public static let deep = InterfaceColor(hex: 0x1B2027)

    /// Fills the mark with its top-left corner at `origin` and the given height, in `color`.
    @MainActor
    public static func draw(into hud: HUDRenderer, origin: SIMD2<Float>, height: Float, color: InterfaceColor) {
        guard height > 0, color.srgb.w > 0 else { return }
        hud.fillPolygon(outline.map { origin + $0 * height }, color: color)
    }
}
