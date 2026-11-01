import Foundation

/// Which animation clips a character is playing this frame, and how much of each: an idle standing still, one gait
/// while moving — its two directions either side of the way the character travels, for a gait that has directions — a
/// rise and a fall off the ground.
///
/// ### Extracted from a game that is played with it
///
/// A third-person game on this engine picked its hero's clips this way from its first walk; **its reasons came with
/// it**, below. Its clips' names and speeds are a game's own, so they are handed in (``Clips``) where they were
/// constants.
///
/// **The gaits are keyed to the speed each animation actually depicts, not to the game's speed constants.** Getting
/// that backwards is what made a sprint look like a hurried walk for a fortnight: the hero walked at 4.5 m/s and its
/// walk cycle was authored at 1.45, so "play the walk clip while walking" meant playing it at 3.1× — a walk cycle at
/// triple speed, feet sliding. Measure each clip's speed from its root motion and hand those in; the playback rate is
/// then the character's speed over the carrying gait's own, near 1× everywhere instead of near 3×.
///
/// **A decision, not a drawing**: arithmetic over the ground speed, in a package where it can be tested, rather than
/// inline where a renderer poses the skeleton and the only check is holding a key down and looking.
public nonisolated struct LocomotionBlend: Equatable, Sendable {

    /// A gait: the clip's name and the ground speed it was authored to travel at — and, for a gait that can go other ways
    /// than straight ahead, its clip for each of them.
    public struct Gait: Sendable, Equatable {
        /// Straight ahead.
        public let clip: String
        public let speed: Float
        /// Where this gait's stride starts against the others', as a fraction of its cycle (``Clips/phaseOffset(of:)``).
        public let phase: Float
        /// Its clips for travelling other ways than ``clip`` does, each authored at ``speed`` and with the same cycle
        /// length. Empty for a gait that only goes forwards.
        public let directions: [Direction]

        public init(_ clip: String, _ speed: Float, phase: Float = 0, directions: [Direction] = []) {
            self.clip = clip
            self.speed = speed
            self.phase = phase
            self.directions = directions
        }

        /// Every clip the gait strides with: ahead first, then each direction.
        public var clips: [String] { [clip] + directions.map(\.clip) }

        /// Straight ahead and every direction, by heading, `0..<2π`.
        var ring: [Direction] {
            ([Direction(clip, heading: 0)] + directions).map { Direction($0.clip, heading: Self.wrapped($0.heading), phase: $0.phase) }
                .sorted { $0.heading < $1.heading }
        }

        static func wrapped(_ angle: Float) -> Float {
            let turn = 2 * Float.pi
            let r = angle.truncatingRemainder(dividingBy: turn)
            return r < 0 ? r + turn : r
        }
    }

    /// **One direction of a gait**: the clip that travels that way, the body still facing ahead — a strafe, a backpedal.
    ///
    /// **A strafe is not the forward clip turned.** Some packs ship their eight ways as the forward walk with the whole
    /// body rotated toward the travel — hips, chest and head — for a character whose facing turns; under a rifle held to
    /// the crosshair that points the rifle wherever the legs go. A direction here is a clip in which the body faces ahead
    /// and the feet go the other way.
    public struct Direction: Sendable, Equatable {
        public let clip: String
        /// Radians from straight ahead, in the camera's convention: positive to the left — `π/2` left, `π` behind,
        /// `-π/2` right.
        public let heading: Float
        /// Where its stride starts against its gait's forward clip, as a fraction of the cycle: **measured, not guessed** —
        /// a backward walk's feet land about half a cycle from the forward walk's, and blending the two at one phase
        /// without it crosses the legs.
        public let phase: Float

        public init(_ clip: String, heading: Float, phase: Float = 0) {
            self.clip = clip
            self.heading = heading
            self.phase = phase
        }
    }

    /// **A game's clips**: its gaits, measured, slowest first, and the names of its idle, rise and fall.
    public struct Clips: Sendable, Equatable {
        public var gaits: [Gait]
        public var idle: String
        /// The jump: the launch and the tuck, a one-shot.
        public var rising: String
        /// The fall: a loop.
        public var falling: String

        /// How far below its authored pace a clip may be played before it is the wrong clip.
        ///
        /// **A feel number with a reason, and the reason is that the error is not symmetric.** Stretched faster, a cycle
        /// looks like someone hurrying; played slower, it looks like slow motion — and a gait brings its posture with
        /// it, so a sprint's forward lean at two thirds pace is a character leaning into a stroll. Held near 1 it keeps
        /// every clip honest and asks the *slower* gait to cover the gap instead, which is the direction that survives
        /// being wrong.
        public var slowestBelievablePlayback: Float

        /// **How far off straight ahead a gait with no directions still plays**, radians. Past it, a gait that has
        /// directions carries the movement instead — a sprint authored only forwards gives way to the run's strafe — so
        /// long as some gait has them; a game with none plays its gaits at any heading, as before directions existed.
        public var undirectedReach: Float

        public init(gaits: [Gait], idle: String = "Idle", rising: String = "Jump", falling: String = "Air",
                    slowestBelievablePlayback: Float = 0.85, undirectedReach: Float = .pi / 4) {
            self.gaits = gaits
            self.idle = idle
            self.rising = rising
            self.falling = falling
            self.slowestBelievablePlayback = slowestBelievablePlayback
            self.undirectedReach = undirectedReach
        }

        /// Every gait's clip names, each direction's too: the strides, sharing one phase (``StrideClock``).
        public var strides: Set<String> { Set(gaits.flatMap(\.clips)) }

        /// **Where a stride clip is sampled against the shared phase**: its gait's ``Gait/phase`` plus its direction's
        /// ``Direction/phase`` — `time = ((phase + offset) mod 1) × duration` (``StrideClock/time(of:duration:in:)``).
        /// Zero for a clip that is not a stride.
        public func phaseOffset(of clip: String) -> Float {
            for gait in gaits {
                if gait.clip == clip { return gait.phase }
                if let direction = gait.directions.first(where: { $0.clip == clip }) { return gait.phase + direction.phase }
            }
            return 0
        }

        /// Whether any gait has clips for other directions — whether a heading means anything to these clips.
        var isDirectional: Bool { gaits.contains { !$0.directions.isEmpty } }
    }

    /// A clip's name and how strongly it contributes. Only non-zero entries are present.
    public var weights: [(clip: String, weight: Float)]

    public init(weights: [(clip: String, weight: Float)], pace: Float, strideReference: String?) {
        self.weights = weights
        self.pace = pace
        self.strideReference = strideReference
    }

    /// How fast the stride cycle should advance, as a multiple of the authored pace of whichever
    /// gait is carrying the movement. Near 1 at every speed, by construction. Zero when still.
    public var pace: Float

    /// The clip whose length the stride phase is measured against. `nil` when not striding.
    public var strideReference: String?

    public static func == (a: Self, b: Self) -> Bool {
        a.pace == b.pace && a.strideReference == b.strideReference
            && a.weights.count == b.weights.count
            && zip(a.weights, b.weights).allSatisfy { $0.clip == $1.clip && $0.weight == $1.weight }
    }

    /// **Off the ground wins, then how fast you are going, then which way.** Two genuinely exclusive states rather
    /// than a blend tree: you are not half airborne.
    ///
    /// - Parameter heading: which way the character travels against the way it faces, radians, positive to the left —
    ///   0 ahead, `π/2` a strafe left, `π` backing away. Only gaits with ``Gait/directions`` use it.
    public static func choose(airborne: Bool,
                              rising: Bool,
                              groundSpeed: Float,
                              heading: Float = 0,
                              clips: Clips) -> LocomotionBlend {
        var gaits = clips.gaits
        if airborne {
            // **The rise and the fall are two clips.** The jump carries the launch and the tuck and
            // is a one-shot; the fall is a loop. One clip for the whole arc is wrong either way.
            return LocomotionBlend(weights: [(rising ? clips.rising : clips.falling, 1)], pace: 0,
                                   strideReference: nil)
        }

        // **One gait at a time, not a blend of two.** Blending needs the clips to be at the same
        // point of the stride, and lining them up turned out to be a measurement that could be
        // wrong in ways nobody can see from the numbers — twice. A single clip cannot cross its own
        // legs. The cost is that the carrying gait is stretched further from its authored pace
        // between the gaits, and that is a visible-but-honest trade against a bug that was not.
        // (A gait's *directions* do blend, two at a time: they are one stride authored together, the
        // same length, their offsets measured — ``directions(of:heading:)``.)
        guard let slowest = gaits.first, groundSpeed > slowest.speed / 2 else {
            return LocomotionBlend(weights: [(clips.idle, 1)], pace: 0, strideReference: nil)
        }

        // **The fastest gait that will still play at a believable rate — not the nearest by ratio.**
        //
        // Nearest-by-ratio treats 1.5× and 0.67× as the same amount wrong, which is tidy and false.
        // A cycle stretched *faster* than it was authored reads as hurrying; a cycle played *slower*
        // reads as slow motion, and a gait carries its own posture with it — the sprint clip leans
        // forward, and a lean over legs strolling at 0.62× reads as **going slower than the run it
        // just replaced**, which is what full stick used to look like. Under the old rule that was
        // the sprint clip's whole lower half.
        //
        // So the crossover is not the geometric mean; it is the point where the faster clip first
        // plays at ``Clips/slowestBelievablePlayback``.
        //
        // **Off straight ahead, only a gait that can go that way.** A sprint authored forwards, played backing away, is a
        // character moonwalking at speed; the run's backpedal carries it instead, stretched as far as it must be.
        let offAhead = abs(Gait.wrapped(heading + .pi) - .pi)
        if clips.isDirectional, offAhead > clips.undirectedReach {
            gaits = gaits.filter { !$0.directions.isEmpty }
        }
        let carrying = gaits.last { groundSpeed / $0.speed >= clips.slowestBelievablePlayback } ?? gaits.first ?? slowest

        return LocomotionBlend(weights: Self.directions(of: carrying, heading: heading),
                               pace: groundSpeed / carrying.speed,
                               strideReference: carrying.clip)
    }

    /// **The two directions either side of the heading, weighted by how near each is** — a diagonal between a forward
    /// clip and a strafe, a strafe between the two diagonals. Both are sampled at one phase (``StrideClock``), which is
    /// what each direction's ``Direction/phase`` is for: two clips at one moment of one stride blend into a stride, and
    /// at different moments into crossed legs. **Two neighbours, never more**: a third clip half a circle away adds a
    /// pose the body is not in.
    static func directions(of gait: Gait, heading: Float) -> [(clip: String, weight: Float)] {
        let ring = gait.ring
        guard ring.count > 1 else { return [(gait.clip, 1)] }
        let h = Gait.wrapped(heading)
        for (index, from) in ring.enumerated() {
            let to = ring[(index + 1) % ring.count]
            let span = Gait.wrapped(to.heading - from.heading)
            let along = Gait.wrapped(h - from.heading)
            guard along <= span, span > 0 else { continue }
            let t = along / span
            if t < 1e-4 { return [(from.clip, 1)] }
            if t > 1 - 1e-4 { return [(to.clip, 1)] }
            return [(from.clip, 1 - t), (to.clip, t)]
        }
        return [(gait.clip, 1)]
    }
}

/// **One phase for every stride clip**: the walk, the run and each of their directions sampled at the same moment of the
/// stride, so a blend of two of them — neighbouring directions, or a gait handing over to the next — is a blend of one
/// stride, and a clip easing in starts with its feet where the others' are.
///
/// The phase advances at the ``LocomotionBlend/pace`` of whichever gait carries the movement, over that gait's cycle;
/// each clip is then sampled at its own ``LocomotionBlend/Clips/phaseOffset(of:)`` from it. Standing still, it holds,
/// so a stride taken up again starts where the last one stopped.
public nonisolated struct StrideClock: Sendable, Equatable {
    /// How far through the stride, `0..<1`.
    public private(set) var phase: Float

    public init(phase: Float = 0) {
        self.phase = Self.wrapped(phase)
    }

    /// Moves on by `seconds` of a stride played at `pace` (``LocomotionBlend/pace``) of a cycle `cycle` seconds long —
    /// the carrying gait's clip, ``LocomotionBlend/strideReference``. Holds while `pace` is zero.
    public mutating func advance(by seconds: Float, pace: Float, cycle: Float) {
        guard cycle > 1e-4, pace != 0 else { return }
        phase = Self.wrapped(phase + seconds * pace / cycle)
    }

    /// The time to sample `clip`, `duration` seconds long, at: its offset among `clips` added to the phase.
    public func time(of clip: String, duration: Float, in clips: LocomotionBlend.Clips) -> Float {
        Self.wrapped(phase + clips.phaseOffset(of: clip)) * duration
    }

    static func wrapped(_ phase: Float) -> Float {
        let r = phase.truncatingRemainder(dividingBy: 1)
        return r < 0 ? r + 1 : r
    }
}
