import Foundation

/// Which animation clips a character is playing this frame, and how much of each: an idle standing still, one gait
/// while moving, a rise and a fall off the ground.
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

    /// A gait: the clip's name and the ground speed it was authored to travel at.
    public struct Gait: Sendable, Equatable {
        public let clip: String
        public let speed: Float
        public init(_ clip: String, _ speed: Float) { self.clip = clip; self.speed = speed }
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

        public init(gaits: [Gait], idle: String = "Idle", rising: String = "Jump", falling: String = "Air",
                    slowestBelievablePlayback: Float = 0.85) {
            self.gaits = gaits
            self.idle = idle
            self.rising = rising
            self.falling = falling
            self.slowestBelievablePlayback = slowestBelievablePlayback
        }

        /// The gaits' clip names: the strides, sharing one phase.
        public var strides: Set<String> { Set(gaits.map(\.clip)) }
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

    /// **Off the ground wins, then how fast you are going.** Two genuinely exclusive states rather
    /// than a blend tree: you are not half airborne.
    public static func choose(airborne: Bool,
                              rising: Bool,
                              groundSpeed: Float,
                              clips: Clips) -> LocomotionBlend {
        let gaits = clips.gaits
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
        let carrying = gaits.last { groundSpeed / $0.speed >= clips.slowestBelievablePlayback } ?? slowest

        return LocomotionBlend(weights: [(carrying.clip, 1)],
                               pace: groundSpeed / carrying.speed,
                               strideReference: carrying.clip)
    }
}
