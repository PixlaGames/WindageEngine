//
//  StickCalibration.swift
//  WindageEngine
//

import simd

/// **What a particular thumbstick actually does when nobody is touching it.**
///
/// Every stick rests somewhere other than zero, and a worn one rests further out. A fixed dead zone is a guess wide
/// enough to cover a bad pad, which means it also throws away the first part of a good one's travel. Measuring the stick
/// replaces the guess: the resting point is subtracted, and the dead zone is sized to whatever that stick actually
/// wanders by (``StickRest``). **A controller is a wear item**, and a player whose stick has started to go should be able
/// to keep playing on it rather than be told to buy another — every console-facing game ships this.
public nonisolated struct StickCalibration: Codable, Sendable, Equatable {
    /// Where this stick sits at rest, subtracted from every reading before anything else looks at it.
    public var center: SIMD2<Float>
    /// How much travel around that center still counts as "not moved".
    public var deadzone: Float

    public init(center: SIMD2<Float> = .zero, deadzone: Float) {
        self.center = center
        self.deadzone = deadzone
    }

    private enum CodingKeys: String, CodingKey { case center, centre, deadzone }

    /// Reads `centre` too, the spelling a game saved before this moved into the engine.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .center)
            ?? c.decodeIfPresent(SIMD2<Float>.self, forKey: .centre) ?? .zero
        deadzone = try c.decode(Float.self, forKey: .deadzone)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(center, forKey: .center)
        try c.encode(deadzone, forKey: .deadzone)
    }
}

/// Both sticks' measurements — the left moves, the right looks. **nil for a stick not measured**, which then takes the
/// player's dead zone as set (``PlayerSettings/moveDeadzone``, ``PlayerSettings/lookDeadzone``).
public nonisolated struct PadCalibration: Codable, Sendable, Equatable {
    public var left: StickCalibration?
    public var right: StickCalibration?

    public init(left: StickCalibration? = nil, right: StickCalibration? = nil) {
        self.left = left
        self.right = right
    }

    public static let unmeasured = PadCalibration()
    public var isMeasured: Bool { left != nil || right != nil }
}

/// **Watching one stick sit still, and deciding what that means.**
///
/// Two different faults look the same from the sofa and are not the same. A stick that rests off center pulls in one
/// direction for ever — classic drift, and subtracting the offset fixes it outright. A stick whose *pot is worn* comes
/// back to a slightly different place each time, depending on which way it was pushed last, so it reads as drift
/// forwards after a forward push and backwards after a back one. **No offset can fix that**, because there is no single
/// center to subtract; what fixes it is a dead zone wide enough to swallow the wander, which ``wander`` measures.
public nonisolated struct StickRest: Sendable, Equatable {
    /// Anything past this at "rest" means a thumb was on the stick, and the measurement is void. A genuinely ruined pot
    /// does not reach half travel on its own.
    public static let heldThreshold: Float = 0.5
    /// The narrowest dead zone a measured stick is given — well below a guess, and that is the payoff: with the resting
    /// point subtracted and the wander known, a healthy stick moves on the first millimetre of push.
    public static let floor: Float = 0.06
    /// How much room to leave above the wander actually seen. A short sample cannot have seen the worst of it.
    public static let margin: Float = 1.6

    private var samples: [SIMD2<Float>] = []

    public init() {}

    public mutating func observe(_ raw: SIMD2<Float>) { samples.append(raw) }

    public var count: Int { samples.count }

    /// The resting point: the **median** of each axis, not the mean — one twitch during the sample drags a mean and
    /// leaves a median alone, and a twitch is the likeliest thing to go wrong with a two-second measurement.
    public var center: SIMD2<Float> {
        guard !samples.isEmpty else { return .zero }
        return SIMD2(Self.median(samples.map(\.x)), Self.median(samples.map(\.y)))
    }

    /// The furthest any sample sat from that center — the size of the wobble to be swallowed.
    public var wander: Float {
        let middle = center
        return samples.map { simd_length($0 - middle) }.max() ?? 0
    }

    /// True when somebody was holding the stick, which makes the whole sample meaningless.
    public var wasHeld: Bool { samples.contains { simd_length($0) > Self.heldThreshold } }

    /// What to record for this stick, or nil when the sample cannot be trusted.
    public func calibration(minimumSamples: Int = 20) -> StickCalibration? {
        guard samples.count >= minimumSamples, !wasHeld else { return nil }
        return StickCalibration(center: center, deadzone: max(Self.floor, wander * Self.margin))
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// **Measuring both sticks over a few seconds of nobody touching them**, as a settings screen does it.
///
/// A state rather than a callback, because the screen has to draw the waiting as well as the answer: three seconds of
/// nothing happening, with no sign anything is being done, is a button that looks broken. The clock is passed in, so a
/// test needs no waiting. ``InputState/rawSticks`` gives the readings to observe.
public nonisolated struct PadMeasurement: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        /// How far through, 0…1.
        case running(Double)
        case finished(PadCalibration)
        /// Why it was refused — a held stick is refused rather than recorded: sampling a thumb resting on the stick
        /// would write that push down as the center and make the pad unusable, the one outcome worse than doing nothing.
        case refused(String)
    }

    public private(set) var state: State = .idle
    private var left = StickRest(), right = StickRest()
    private var started: Double = 0, seconds: Double = 3

    public init() {}

    public mutating func begin(at now: Double, seconds: Double = 3) {
        left = StickRest(); right = StickRest()
        started = now
        self.seconds = max(seconds, 0.1)
        state = .running(0)
    }

    public mutating func cancel() { state = .idle }

    /// One reading of both sticks; returns the state after it.
    @discardableResult
    public mutating func observe(left l: SIMD2<Float>, right r: SIMD2<Float>, at now: Double) -> State {
        guard case .running = state else { return state }
        left.observe(l)
        right.observe(r)
        let done = (now - started) / seconds
        guard done >= 1 else {
            state = .running(min(max(done, 0), 1))
            return state
        }
        guard let measuredLeft = left.calibration(), let measuredRight = right.calibration() else {
            state = .refused("Something was touching a stick. Let go of both and try again.")
            return state
        }
        state = .finished(PadCalibration(left: measuredLeft, right: measuredRight))
        return state
    }
}

/// **A pad that has stopped sending, told from a stick being held.**
///
/// Measured, not imagined: an Xbox Wireless Controller reported the *bit-identical* pair (0.0146, 0.6082) for 11,751
/// consecutive samples over thirty seconds with nobody touching it. A value like that is past any dead zone, so the
/// player walks off on their own and a push the other way nets almost nothing. **A person cannot hold an analogue stick
/// to five decimal places** — every genuine hold wanders in the fourth digit within a second; only a repeated report does
/// not move at all. So a non-zero reading unchanged for ``staleAfter`` seconds is disbelieved and the sticks read as
/// centered until the report moves again. The buttons are left alone: a stuck stick says nothing about them.
public nonisolated struct FrozenStickWatch: Sendable, Equatable {
    /// How long an unchanged non-zero reading is believed. Generous: being wrong costs a stick that stops for a second.
    public static let staleAfter: Double = 2

    public private(set) var isFrozen = false
    private var last: (SIMD2<Float>, SIMD2<Float>)?
    private var unchangedSince: Double?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool { a.isFrozen == b.isFrozen && a.unchangedSince == b.unchangedSince }

    /// Watches one report; true while it should be disbelieved. `restBelow` is how far out a stick genuinely at rest
    /// may sit — a resting stick repeats its rest for ever, and that is not a fault.
    public mutating func observe(left: SIMD2<Float>, right: SIMD2<Float>, at now: Double,
                                 restBelow: Float = StickResponse.moveDeadzone) -> Bool {
        guard let last, last.0 == left, last.1 == right else {
            self.last = (left, right)
            unchangedSince = now
            isFrozen = false
            return false
        }
        guard simd_length(left) > restBelow || simd_length(right) > restBelow else {
            isFrozen = false
            return false
        }
        let since = unchangedSince ?? now
        unchangedSince = since
        isFrozen = now - since > Self.staleAfter
        return isFrozen
    }
}
