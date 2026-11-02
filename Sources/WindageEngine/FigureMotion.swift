import Foundation

/// **How a figure is moving, as the clips to play, where in each, and how much of each**: the clips ``LocomotionBlend``
/// picks, eased in and out, every stride on one phase, a jump played from take-off, and one-shots — a swing, a flinch, a
/// fall — laid over the lot.
///
/// ### Extracted from a game that is played with it
///
/// A third-person game posed its hero this way, then every other player with the same type so the people beside the
/// hero did not walk by a second rule; two more figures in another game — a player who strafes and crouches, and a horde
/// that shambles and swipes — had each grown a copy. **Its reasons came with it**, below. What is per figure is handed in:
/// the clips (``LocomotionBlend/Clips``, which may change from frame to frame — standing and crouched), which way the body
/// travels against its facing (``Body/heading``), how quickly one clip hands over to the next (``easing``), and what is
/// laid over the locomotion (``OneShot``).
///
/// **What stays with the caller** is the part that needs a rig — turning a clip's name into a pose: sample each
/// ``Play`` at its time and mix them (`SkeletonPose.set(mixing:)`) — and what the caller knows about its own body.
public nonisolated struct FigureMotion: Sendable {

    /// What the body is doing this frame.
    public struct Body: Sendable, Equatable {
        public var airborne: Bool
        public var rising: Bool
        public var groundSpeed: Float
        /// Which way the body travels against the way it faces, radians, positive to the left — 0 ahead, `π/2` a strafe
        /// left, `π` backing away (``LocomotionBlend/choose(airborne:rising:groundSpeed:heading:clips:)``). Only gaits
        /// with directions use it.
        public var heading: Float
        /// Backing away on a gait with no backward clip: its forward stride runs in reverse (``advance(by:body:oneShots:clips:duration:strideOffsets:)``).
        public var backpedaling: Bool

        public init(airborne: Bool = false, rising: Bool = false, groundSpeed: Float = 0, heading: Float = 0,
                    backpedaling: Bool = false) {
            self.airborne = airborne
            self.rising = rising
            self.groundSpeed = groundSpeed
            self.heading = heading
            self.backpedaling = backpedaling
        }
    }

    /// **A one-shot laid over the locomotion** — a swing, a flinch, a fall: its clip, how long since it began, and how
    /// strongly it overrides everything under it, 0…1. The caller owns the weight's envelope (``envelope(at:lasting:fadeIn:fadeOut:)``
    /// is the usual one); this owns the clip's time.
    public struct OneShot: Sendable, Equatable {
        public var clip: String
        public var age: TimeInterval
        public var weight: Float

        public init(clip: String, age: TimeInterval, weight: Float) {
            self.clip = clip
            self.age = age
            self.weight = weight
        }

        /// **Fades in over `fadeIn` seconds, holds, and fades out over the last `fadeOut`** of `lasting` — 0 outside it.
        ///
        /// **Usually asymmetric**: a blow has to *start* now — a blended wind-up is a figure thinking about it — and it can
        /// hand back gently.
        public static func envelope(at age: TimeInterval, lasting: TimeInterval, fadeIn: TimeInterval,
                                    fadeOut: TimeInterval) -> Float {
            guard lasting > 0, age >= 0, age < lasting else { return 0 }
            if fadeIn > 0, age < fadeIn { return Float(age / fadeIn) }
            let remaining = lasting - age
            if fadeOut > 0, remaining < fadeOut { return Float(remaining / fadeOut) }
            return 1
        }
    }

    /// One clip to sample: at `time` seconds into it, mixed in at `weight`.
    public struct Play: Sendable, Equatable {
        public var name: String
        public var time: TimeInterval
        public var weight: Float

        public init(name: String, time: TimeInterval, weight: Float) {
            self.name = name
            self.time = time
            self.weight = weight
        }
    }

    /// **How quickly one clip hands over to the next**: the half-life of every locomotion weight's ease, seconds.
    public var easing: TimeInterval

    /// How far through the stride the figure is, 0 to 1. **Its own accumulator, not wall-clock**,
    /// because the cycle has to advance with the figure's speed: driving it from the clock would leave
    /// the feet striding at the same rate whether walking or sprinting, which is the sliding this
    /// exists to avoid. **A fraction rather than a time**, because the walk and the run are
    /// different lengths and are blended together — one number both clips can be asked for.
    public private(set) var walkPhase: TimeInterval = 0

    /// **Animation time, which is not wall time** — whatever the caller advances it by: a frame scaled down for a hit-stop
    /// reaches the stride phase, the jump's own clock and the idle loop together.
    public private(set) var clock: TimeInterval = 0

    /// Whether a gait was carrying the movement last frame, so a new one can start at its own
    /// beginning rather than wherever the previous one stopped.
    private var wasStriding = false

    /// What each clip is contributing right now, eased towards what the state asked for.
    ///
    /// **Every state change was a hard cut, and a hard cut is a pose jumping in one frame.** Frame
    /// zero of a gait is a foot on the ground but the legs are still apart, so setting off from a
    /// standing idle snapped; the apex of a jump swapped one airborne clip for another; landing
    /// swapped back. A tenth of a second of overlap covers all three without making the states feel
    /// vague.
    ///
    /// **This was written once before and crashed, and the reason is now understood.** Blending two
    /// poses can cancel a quaternion to nothing, and Model I/O was handing back quaternions that
    /// were already nearly nothing — normalising one is a NaN, which becomes a NaN matrix and kills
    /// the process somewhere in the graphics stack with no trace of where it started. The source
    /// data is fixed and `SkeletonPose.set(mixing:)` refuses to normalise a cancelled sum.
    public private(set) var clipWeights: [String: Float] = [:]

    /// **Every stride clip of every clip set handed in, with its offset** (``LocomotionBlend/Clips/phaseOffset(of:)``).
    /// A figure that changes clip sets — standing to crouched — still has the old set's strides easing out, and a stride
    /// easing out sampled anywhere but on the shared phase is a pose jumping as it goes.
    private var strideClips: [String: Float] = [:]
    private var lastClips: LocomotionBlend.Clips?

    private var wasAirborne = false

    /// When the figure last left the ground, so the jump plays from its first frame.
    ///
    /// **A jump is a one-shot and was being looped on the wall clock.** Whatever `now` happened to
    /// be modulo the clip's half second decided which pose the leap started on, so it began
    /// mid-tuck as often as not, jumped again when the loop came round inside a single jump, and
    /// started somewhere different every time. The fall had the same problem. Both now run from the
    /// moment the feet left the ground.
    private var leftGroundAt: TimeInterval?

    /// - Parameters:
    ///   - easing: the half-life of a hand-over between clips, seconds (``easing``). **A tenth of a second** covers a
    ///     gait setting off, the apex of a jump and a landing without making the states feel vague.
    ///   - clock: where this figure's own loops start. **Figures made together idle in step**, which in a crowd reads as
    ///     a drill; start each somewhere different.
    public init(easing: TimeInterval = 0.1, clock: TimeInterval = 0) {
        self.easing = easing
        self.clock = clock.isFinite ? clock : 0
    }

    /// Moves on by `delta` seconds of animation and says what to play: the clips ``LocomotionBlend`` asks for of
    /// `clips`, eased, each of `oneShots` over them in turn. `duration` is each clip's length on this figure's model (nil
    /// for one it lacks); `strideOffsets` is where each stride lines up with the others' when measured off the model
    /// (``StrideAlignment``), 0…1 — added to the clips' own ``LocomotionBlend/Clips/phaseOffset(of:)``.
    public mutating func advance(by delta: TimeInterval, body: Body, oneShots: [OneShot] = [],
                                 clips: LocomotionBlend.Clips,
                                 duration: (String) -> TimeInterval?,
                                 strideOffsets: [String: Double] = [:]) -> [Play] {
        // **A number that is not one never reaches a pose.** A NaN in a playhead becomes a NaN matrix and kills the
        // process somewhere in the graphics stack; a body read off the network is checked.
        let delta = delta.isFinite ? max(delta, 0) : 0
        var body = body
        if !body.groundSpeed.isFinite { body.groundSpeed = 0 }
        if !body.heading.isFinite { body.heading = 0 }
        clock += delta
        let now = clock
        if clips != lastClips {
            lastClips = clips
            for name in clips.strides { strideClips[name] = clips.phaseOffset(of: name) }
        }

        // **The choice lives in `LocomotionBlend`.** It is arithmetic over the
        // body's state, and the only way to check it here was to hold a key down and look — which
        // is how a sprint spent a fortnight playing the walk clip at 1.78× and reading as a hurried
        // walk.
        // **Set on take-off and never cleared.** The airborne clips keep fading out for a moment
        // after landing, and they have to keep their own clock while they do — reading the wall
        // clock instead would snap the very pose the fade exists to smooth.
        if body.airborne, !wasAirborne { leftGroundAt = now }
        wasAirborne = body.airborne

        let blend = LocomotionBlend.choose(airborne: body.airborne,
                                           rising: body.rising,
                                           groundSpeed: body.groundSpeed,
                                           heading: body.heading,
                                           clips: clips)

        // **A fraction of a cycle, not a time**, because the walk and the run are different lengths
        // and are blended together: handing both the same number of seconds would land them on
        // different parts of the stride and average a left foot with a right.
        if let reference = blend.strideReference, let length = duration(reference) {
            // **A stride starts at the beginning of a stride.** The phase used to carry over from
            // whenever the figure last stopped, so setting off again snapped straight to whatever
            // pose that happened to be — mid-swing as often as not, which reads as a lurch forward
            // on the first step. Frame zero of a gait as the common packs author it is a foot on the
            // ground, which is what standing still looks like, so starting there is a step rather than
            // a jolt.
            if !wasStriding { walkPhase = 0 }
            // **Backwards while backing away**, for a gait with no backward clip: running the forward
            // stride in reverse puts the feet under a body travelling the other way, where playing it
            // forwards is a figure moonwalking.
            let stride: TimeInterval = body.backpedaling ? -1 : 1
            walkPhase += stride * delta * TimeInterval(blend.pace) / length
            walkPhase -= walkPhase.rounded(.down)
        }
        wasStriding = blend.strideReference != nil

        var wanted: [String: Float] = [:]
        for (clip, weight) in blend.weights { wanted[clip, default: 0] += weight }

        let ease = Float(easing > 0 ? 1 - exp2(-delta / easing) : 1)
        for clip in Set(clipWeights.keys).union(wanted.keys) {
            let current = clipWeights[clip, default: 0]
            let eased = current + ((wanted[clip] ?? 0) - current) * ease
            if eased < 0.004, wanted[clip] == nil {
                clipWeights[clip] = nil
            } else {
                clipWeights[clip] = eased
            }
        }

        // **A one-shot lies over the eased locomotion, and is not eased itself.**
        //
        // **A swing was folded into `wanted` above and that was wrong.** The 0.1 s half-life exists for
        // locomotion hand-overs, which take their time — a walk becoming a run. A swing is 0.37 s
        // and has *already* faded itself in over 30 ms, so passing it through a second smoother
        // meant the attack chased a target that had started leaving: measured, it reached about
        // 0.85 only in the last third of the clip and was cut by the fade-out immediately after.
        // The swing arrived late, weak and briefly, which is indistinguishable from not arriving.
        //
        // **A full-body override rather than an upper-body mask, deliberately for now.** A mask
        // needs the rig to know which joints are the arms and to blend two poses per joint; this
        // rig had neither, and a melee clip is commonly authored as a whole body anyway. It costs a
        // figure who swings while sprinting, which a game whose blows are struck standing does not
        // ask for. A game that does lays its upper-body clips over the pose afterwards
        // (`SkeletonPose.overlay(_:mask:modelRotationAt:)`), not here.
        //
        // **Each in turn, each taking its weight from everything under it** — a flinch over a swing
        // over a walk: a swing at 1 and a flinch at 0.75 leave the swing a quarter.
        var playing = clipWeights
        for shot in oneShots where shot.weight > 0 {
            let weight = min(shot.weight, 1)
            for clip in playing.keys { playing[clip]! *= 1 - weight }
            playing[shot.clip] = weight
        }

        var plays: [Play] = []
        for (name, weight) in playing {
            guard weight > 0, let length = duration(name) else { continue }
            // The gaits share one phase so their feet stay in step through a hand-over; everything
            // else is a loop on its own clock.
            // **Each gait is sampled at the shared phase plus its own offset.** Two clips blended at
            // the same fraction of their cycles are not blended at the same moment of the stride —
            // a pack's walk, run and sprint each start wherever their animator started them — so the
            // mix could average one clip's left-foot-forward against another's right, which draws as
            // the legs crossing and clipping through each other, and the arms with them. The offsets
            // are the clips' own (``LocomotionBlend/Clips/phaseOffset(of:)``) plus any measured off the
            // model when it is made (``StrideAlignment``).
            let time: TimeInterval
            if let shot = oneShots.last(where: { $0.clip == name && $0.weight > 0 }) {
                // **Its own clock, from the moment the swing began** — the same reason the jump
                // has one. A one-shot sampled on a looping wall clock starts wherever that clock
                // happened to be, so half the swings would begin mid-follow-through.
                // **One to one with the clip, never stretched.** The swing's length *is* the
                // clip's length, so this is the age, clamped to the last frame rather than wrapped: a
                // swing that loops inside its own life is a figure swinging twice for one key press.
                time = min(max(shot.age.isFinite ? shot.age : 0, 0), length - 0.001)
            } else if let offset = strideClips[name] {
                var phase = (walkPhase + Double(offset) + (strideOffsets[name] ?? 0)).truncatingRemainder(dividingBy: 1)
                if phase < 0 { phase += 1 }
                time = phase * length
            } else if let since = leftGroundAt, name == clips.rising || name == clips.falling {
                let elapsed = now - since
                // **The jump holds its last frame; the fall loops.** A leap is one motion that ends
                // — replaying it while still rising is a figure hopping in mid-air — and a fall is a
                // state, which is exactly the difference between the two clips.
                time = name == clips.rising
                    ? min(elapsed, length - 0.001)
                    : elapsed.truncatingRemainder(dividingBy: length)
            } else {
                time = now.truncatingRemainder(dividingBy: length)
            }
            plays.append(Play(name: name, time: time, weight: weight))
        }
        return plays
    }
}
