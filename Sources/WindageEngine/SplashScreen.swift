//
//  SplashScreen.swift
//  WindageEngine
//

import simd

/// The engine saying its own name: a lockup of ``EngineMark`` and the name over a ground, for as long
/// as a game wants and no longer.
///
/// ### What the engine owes here, and what it does not
///
/// The engine owes the **surface** — a thing that can be shown, timed, skipped and drawn with no art,
/// no texture and no pipeline of its own, so that a game which wants to credit the engine has nothing
/// to build. It does not owe the decision: nothing here runs unless a game runs it, and
/// ``SplashScreen`` does not install itself in the frame loop.
///
/// ### What goes on it, and what does not (2026-09-15)
///
/// **One line across: a lead, the mark, the name** — `MADE WITH`, the W, `WINDAGE` over `ENGINE`. The
/// shape most players have already seen on an engine splash, and for a reason: it reads in one glance.
///
/// - **No version.** No engine shows one in a shipped game — a version belongs to an editor's splash,
///   an about box and a log. ``showsVersion`` is there for development builds and is off.
/// - **The lead is worth its two words here.** A splash showing only a logo works for an engine every
///   player already recognizes; nobody recognizes this one yet, and "made with" says what they are
///   looking at. It is part of the lockup, set in the lockup's capitals, not a label floating over it.
///
/// The name is set in the host's own interface font. The engine has a drawn **mark**; it does not have
/// a drawn wordmark, and until it does, the name beside the mark is set rather than drawn.
///
/// ### It does not stop the game, and it must not swallow the key that skips it
///
/// **Advance it from your simulation step, draw it from your HUD.** It is an overlay and a clock, not
/// a mode: the game goes on stepping behind it, which is what a game is usually *for* during a splash
/// — loading. Two things follow:
///
/// - A game that suspends its step while this is up makes its own first second unrepeatable.
/// - **``skip()`` must be a side effect of a press, never a consumer of it.** A splash that eats the
///   first keystroke eats the first keystroke of whatever the player was already doing — in the
///   sample's case the first press of a scripted walk, which then ends 1.2 m short. There is a check
///   for exactly that (a recorded walk, "crate behind the splash").
///
/// ### The fades are ramps, so the picture is the same at any step rate
///
/// Everything here is linear in ``elapsed``, and ``elapsed`` is a sum of step lengths. A game at 30
/// steps a second and one at 240 show the same opacity at the same moment.
public nonisolated struct SplashScreen: Sendable {

    /// Seconds fading up from nothing.
    public var fadeIn: Float = 0.4
    /// Seconds at full strength.
    public var hold: Float = 1.6
    /// Seconds fading away.
    public var fadeOut: Float = 0.5

    /// Seconds from going up before a press can skip it.
    ///
    /// **A splash that can be skipped on the frame it appears is one nobody ever sees**: the key or
    /// the click that launched the game is often still down when the first frame goes up, and the
    /// splash is gone before it has drawn once.
    public var skipDelay: Float = 0.25

    /// What is behind the lockup. Near-black rather than black, so it reads as a surface.
    public var background = InterfaceColor(hex: 0x0B0D10)

    /// The mark and the lettering. ``EngineMark/display``, because the ground is dark.
    public var foreground = EngineMark.display

    /// Words set in small capitals to the left of the mark, one per line — `"MADE WITH"` is the usual
    /// lead. Nil draws none, and the mark and name center on their own.
    public var lead: String?

    /// The mark's size — it is square — as a share of the viewport's width. Everything else in the
    /// lockup is sized from the mark.
    public var markScale: Float = 0.12

    /// Whether ``Engine/version`` is drawn under the name. **Off**: no shipped game shows its engine's
    /// version, and a recorded frame that could see it would fail on every release.
    public var showsVersion = false

    /// Seconds since it went up.
    public private(set) var elapsed: Float = 0

    /// Whether ``skip()`` has been taken.
    public private(set) var isSkipped = false

    public init(lead: String? = nil) {
        self.lead = lead
    }

    /// How long it lasts if nobody skips it.
    public var duration: Float { fadeIn + hold + fadeOut }

    /// Nothing left to draw. **Drop it when this is true** — an overlay at zero opacity still costs
    /// its vertices.
    public var isFinished: Bool { elapsed >= duration }

    /// 0…1, up the ramp, flat, and down again.
    public var opacity: Float {
        if elapsed <= 0 { return 0 }
        if elapsed < fadeIn { return fadeIn > 0 ? elapsed / fadeIn : 1 }
        if elapsed < fadeIn + hold { return 1 }
        if elapsed < duration { return fadeOut > 0 ? (duration - elapsed) / fadeOut : 0 }
        return 0
    }

    /// Call once per simulation step.
    public mutating func advance(by seconds: Float) {
        elapsed = min(duration, elapsed + max(0, seconds))
    }

    /// Cut it short — **by running it to the start of its fade, not by ending it.**
    ///
    /// A splash that vanishes on the frame a key goes down looks like a dropped frame; one that fades
    /// out over its own fade looks like it was always going to. Ignored until ``skipDelay`` has
    /// passed, and ignored again once it is already fading, so leaning on a key does not shorten
    /// the fade twice.
    public mutating func skip() {
        guard elapsed >= skipDelay, elapsed < fadeIn + hold else { return }
        elapsed = fadeIn + hold
        isSkipped = true
    }

    /// Draws it over the whole viewport. Call from `encodeHUD`, after everything else.
    ///
    /// - Parameter viewportSize: the size the HUD was begun with, in the same units.
    @MainActor
    public func draw(into hud: HUDRenderer, viewportSize viewport: SIMD2<Float>) {
        let alpha = opacity
        guard alpha > 0, viewport.x > 0, viewport.y > 0 else { return }

        hud.fillRect(origin: .zero, size: viewport,
                     color: background.withAlpha(background.srgb.w * alpha))

        let ink = foreground.withAlpha(foreground.srgb.w * alpha)
        let mark = viewport.x * markScale
        let center = viewport * 0.5
        let gap = mark * 0.3

        // The name as the lockup sets it: the first word large, the rest small and tracked out beneath.
        let words = Engine.name.uppercased().split(separator: " ", maxSplits: 1).map(String.init)
        let first = words.first ?? "", second = words.count > 1 ? words[1] : ""
        let large = mark * 0.62, small = mark * 0.19
        let nameWidth = max(hud.width(of: first, pointSize: large),
                            SplashScreen.width(of: second, pointSize: small, tracking: small * 0.6, in: hud))

        let leadLines = (lead ?? "").uppercased().split(separator: " ").map(String.init)
        let leadPoint = mark * 0.17, leadTracking = leadPoint * 0.3
        let leadWidth = leadLines.map { SplashScreen.width(of: $0, pointSize: leadPoint, tracking: leadTracking, in: hud) }.max() ?? 0

        let total = (leadLines.isEmpty ? 0 : leadWidth + gap) + mark + gap + nameWidth
        var x = center.x - total / 2

        if !leadLines.isEmpty {
            // Right-aligned against the mark, the block centred on the mark's height.
            let line = leadPoint * 1.2
            let firstBaseline = center.y - line * Float(leadLines.count) / 2 + leadPoint * 0.95
            for (index, words) in leadLines.enumerated() {
                let width = SplashScreen.width(of: words, pointSize: leadPoint, tracking: leadTracking, in: hud)
                SplashScreen.set(words, into: hud, x: x + leadWidth - width, y: firstBaseline + line * Float(index),
                                 pointSize: leadPoint, tracking: leadTracking, color: ink.withAlpha(ink.srgb.w * 0.8))
            }
            x += leadWidth + gap
        }

        EngineMark.draw(into: hud, origin: SIMD2(x, center.y - mark / 2), height: mark, color: ink)
        x += mark + gap

        // Capitals stand about seven tenths of their point size above the baseline; the two lines are
        // centred together on the mark.
        let block = large * 0.72 + small * 0.55 + small * 0.72
        let firstBaseline = center.y - block / 2 + large * 0.72
        _ = hud.text(first, atBaseline: SIMD2(x, firstBaseline), pointSize: large, color: ink)
        let secondBaseline = firstBaseline + small * 0.55 + small * 0.72
        SplashScreen.set(second, into: hud, x: x + mark * 0.02, y: secondBaseline,
                         pointSize: small, tracking: small * 0.6, color: ink.withAlpha(ink.srgb.w * 0.7))

        if showsVersion {
            _ = hud.text(Engine.version, atBaseline: SIMD2(x, secondBaseline + small * 1.9), pointSize: small,
                         color: ink.withAlpha(ink.srgb.w * 0.45))
        }
    }

    /// A line with extra space between its letters — the HUD sets text solid, and small capitals
    /// set solid run together.
    @MainActor
    static func set(_ string: String, into hud: HUDRenderer, x: Float, y: Float, pointSize: Float,
                    tracking: Float, color: InterfaceColor) {
        var pen = x
        for character in string {
            pen += hud.text(String(character), atBaseline: SIMD2(pen, y),
                            pointSize: pointSize, color: color) + tracking
        }
    }

    @MainActor
    static func width(of string: String, pointSize: Float, tracking: Float, in hud: HUDRenderer) -> Float {
        guard !string.isEmpty else { return 0 }
        return hud.width(of: string, pointSize: pointSize) + tracking * Float(string.count - 1)
    }
}
