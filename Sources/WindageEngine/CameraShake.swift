//
//  CameraShake.swift
//  WindageEngine
//

import simd

/// What the camera does when something lands, as trauma that decays rather than a shake that is switched on and off.
///
/// ### Extracted from a game that is played with it
///
/// A game on this engine shakes its camera this way when blows land, with every number set against a measurement of
/// how much of the screen it moves (see *Visible*, below). A blow is a **force**, 0…1 — what the player needs to feel
/// is a category (routine, heavy, the one that ended it), so a game maps its own kinds of hit onto a force rather than
/// passing damage, and a balance change cannot silently rebalance the camera.
///
/// **The trauma model, and it is worth saying why rather than just citing it.** Adding a shake per hit and letting
/// them overlap gives a camera that is calm at one hit and unusable at three, because amplitudes sum. Trauma is a
/// single 0…1 value that blows *add* to and time bleeds away, and displacement is trauma **squared** — so a stream of
/// small hits stays a tremor while one big one is a jolt, and nothing can stack into a screen nobody can read.
///
/// **Two channels, because they answer different questions.** A hit you *land* is a directional punch — the camera
/// leans into the blow and settles (``landed(force:towards:)``). A hit you *take* is a shake, because being hit is
/// disorienting and has no direction you chose (``took(force:)``). Landing one and taking one in the same moment should
/// not cancel out, which one channel would.
///
/// **Use**: ``advance(by:)`` once a step, and add ``offset`` to where the camera is drawn from — the view only, never
/// the aim, so a shake never moves what the player is pointing at.
///
/// ### Visible
///
/// **The distances are in metres, so they are tied to the camera's framing, and that is a live hazard.** How much of
/// the *screen* a metre of camera movement covers depends on the field of view and how far the camera sits. The
/// defaults are set for ``OrbitCamera``'s defaults (5.5 m, 45°): a half-force blow taken moves the view about 1% of the
/// screen's height, a full one about 5%, a half-force punch landed about 1%. A game that frames its camera differently
/// re-judges them, in fractions of screen height — the only unit in which "is this visible" has an answer.
public nonisolated struct CameraShake: Sendable, Equatable {

    /// How the shake looks. **A game's numbers, with the defaults the engine was tuned with**, for
    /// ``OrbitCamera``'s default framing.
    public struct Tuning: Sendable, Equatable {
        /// How long full trauma takes to bleed away, in seconds.
        public var traumaLife: Float = 0.9
        /// Metres of shake at full trauma. **About 5% of the screen's height** at the default orbit — a jolt, kept for
        /// the blow that ended the fight.
        public var shakeDistance: Float = 0.23
        /// Shakes per second. **Fast enough to read as an impact rather than as a wobble** — below about 15 the camera
        /// looks like it is on a boat — and slow enough to survive the frame rate: at 24 there are two and a half
        /// frames to an oscillation on a 60 Hz display, which aliases into a slower, uglier wobble than the one asked
        /// for.
        public var shakeRate: Float = 20
        /// How long a punch takes to halve, in seconds.
        public var kickHalfLife: Float = 0.07
        /// Metres the camera leans at full force. **About 2% of the screen's height**; a half-force blow lands at half
        /// that, which is the "I connected" signal and the most-felt number here, because it happens on every swing.
        public var kickDistance: Float = 0.09
        /// How much trauma a landed blow adds, as a share of its force. **A pure punch on its own reads as the camera
        /// drifting**; the tremor under it is what makes the punch land.
        public var landedTrauma: Float = 0.5

        public init(traumaLife: Float = 0.9, shakeDistance: Float = 0.23, shakeRate: Float = 20,
                    kickHalfLife: Float = 0.07, kickDistance: Float = 0.09, landedTrauma: Float = 0.5) {
            self.traumaLife = traumaLife
            self.shakeDistance = shakeDistance
            self.shakeRate = shakeRate
            self.kickHalfLife = kickHalfLife
            self.kickDistance = kickDistance
            self.landedTrauma = landedTrauma
        }
    }

    public var tuning: Tuning

    /// 0…1. Squared on the way out; see the type's note.
    public private(set) var trauma: Float = 0
    /// Where the punch is pushing, in world units, before decay.
    public private(set) var kick: SIMD3<Float> = .zero
    /// Drives the noise. **Advanced by time, never by frame count** — a shake keyed to frames runs at a different speed
    /// on a 120 Hz display, which is a bug nobody sees until somebody with a better monitor says the game feels wrong.
    private var clock: Float = 0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// A blow you landed, of `force` 0…1. `direction` is from the camera toward what was hit; it is normalised here,
    /// so a caller may hand over any vector that points the right way.
    public mutating func landed(force: Float, towards direction: SIMD3<Float>) {
        let length = (direction * direction).sum().squareRoot()
        guard length > 0.0001 else { return }
        kick += direction / length * tuning.kickDistance * force
        add(trauma: force * tuning.landedTrauma)
    }

    /// A blow you took, of `force` 0…1.
    public mutating func took(force: Float) {
        add(trauma: force)
    }

    private mutating func add(trauma amount: Float) {
        trauma = min(trauma + amount, 1)
    }

    public mutating func advance(by deltaTime: Float) {
        clock += deltaTime
        trauma = max(0, trauma - deltaTime / tuning.traumaLife)
        // Exponential, so the punch never quite arrives back and never overshoots — a linear return lands with a corner
        // in it, which reads as a second, smaller jolt.
        let keep = powf(0.5, deltaTime / tuning.kickHalfLife)
        kick *= keep
        if (kick * kick).sum() < 1e-8 { kick = .zero }
    }

    /// Where the camera should sit this frame, relative to where it otherwise would.
    public var offset: SIMD3<Float> {
        let shake = trauma * trauma * tuning.shakeDistance
        guard shake > 0 || kick != .zero else { return .zero }
        let t = clock * tuning.shakeRate
        return kick + SIMD3(noise(t, seed: 0), noise(t, seed: 1), noise(t, seed: 2)) * shake
    }

    /// Smooth −1…1 noise. **Smooth, not random per frame**: white noise at frame rate is a blur, and what reads as an
    /// impact is the camera being *carried* somewhere it should not be and hauled back. Value noise, Hermite-eased.
    private func noise(_ t: Float, seed: Int) -> Float {
        let i = t.rounded(.down)
        let f = t - i
        let a = hash(Int(i), seed), b = hash(Int(i) + 1, seed)
        let eased = f * f * (3 - 2 * f)
        return a + (b - a) * eased
    }

    /// −1…1 from an integer. An ordinary integer hash; it only has to be repeatable and to look unrelated to its
    /// neighbours.
    private func hash(_ n: Int, _ seed: Int) -> Float {
        var x = UInt64(bitPattern: Int64(n &* 374_761_393 &+ seed &* 668_265_263))
        x ^= x >> 13
        x = x &* 1_274_126_177
        x ^= x >> 16
        return Float(x & 0xFFFF) / 32_768 - 1
    }
}
