//
//  CharacterFacing.swift
//  WindageEngine
//

import simd

/// Which way a third-person character faces as it moves: toward where it is going, except backwards.
///
/// ### Extracted from a game that is played with it
///
/// A third-person game on this engine turns its character with these rules, each found by playing: the character turns
/// toward its movement over a short half-life rather than snapping; **backing away keeps it facing forward**; it can be
/// told to hold its facing; and backing away is slower. A first-person body has no facing apart from its view, so
/// this is only for a character the player sees — beside ``OrbitCamera``, whose yaw is the `viewYaw` it is given.
///
/// **Movement is in the view's frame**: `axis.y` forward is away from the camera and `axis.x` is to its right — what
/// "forward" means in a third-person game. ``direction(of:viewYaw:)`` turns that into a direction on the ground, the
/// one a body walks along (``CharacterController/step(yaw:input:isJumpHeld:isCrouching:deltaTime:in:)`` with the
/// view's yaw walks the same way).
public nonisolated struct CharacterFacing: Sendable, Equatable {

    /// How quickly it turns and how much backing away slows it. **A game's numbers, with the defaults the engine was
    /// tuned with.**
    public struct Tuning: Sendable, Equatable {
        /// How quickly the facing catches up with the movement, as a half-life in seconds. Short enough that a turn
        /// reads as the character's own, long enough that it is a turn rather than a snap.
        public var turnHalfLife: Float = 0.05

        /// How fast backing away is, against the same input pushed forward: **60%.**
        ///
        /// **Backing away faces forward, and in the games that do that it is also slower** — WoW backpedals at
        /// roughly two thirds of its run, and ESO and Guild Wars 2 slow it too. The reason is the fight rather than
        /// realism: at full speed a player can walk backwards hitting a foe that can never close the gap, so the moment
        /// foes chase, kiting is free. Slower backwards is what makes stepping back a decision.
        public var backpedalPace: Float = 0.6

        public init(turnHalfLife: Float = 0.05, backpedalPace: Float = 0.6) {
            self.turnHalfLife = turnHalfLife
            self.backpedalPace = backpedalPace
        }
    }

    public var tuning: Tuning

    /// Radians, in the camera's convention: zero faces −Z, positive turns left. **Not wrapped**; every turn here goes
    /// the short way round whatever its value.
    public var yaw: Float

    /// While true, moving does not turn the character.
    ///
    /// **For the length of an attack, typically.** An attack turns the character to face where the camera looks,
    /// and the movement then eases the facing toward the direction of travel every frame — so a blow thrown while
    /// strafing turns to the camera and then twists back to the strafe inside the same swing, and reads as the weapon
    /// going somewhere the hit did not.
    ///
    /// **The feet still move.** Walking backwards or sideways while the blade is out is stepping through a swing,
    /// which is how melee moves; what is held is only which way the character faces.
    public var isHeld = false

    /// True while the character is moving away from the way it faces.
    ///
    /// **For running the stride backwards.** With no backward gait clip, playing the forward run while travelling
    /// backwards is a character moonwalking — the feet carry the body one way and the ground goes the other.
    public private(set) var isBackpedaling = false

    public init(yaw: Float = 0, tuning: Tuning = Tuning()) {
        self.yaw = yaw
        self.tuning = tuning
    }

    /// Which way the character faces, on the ground.
    public var heading: SIMD3<Float> { SIMD3(-sinf(yaw), 0, -cosf(yaw)) }

    /// Where a movement input goes under a view at `viewYaw`: `axis.y` along the view's facing flattened onto the
    /// ground, `axis.x` to its right. Not normalised — its length is the input's.
    public static func direction(of axis: SIMD2<Float>, viewYaw: Float) -> SIMD3<Float> {
        let forward = SIMD3<Float>(-sinf(viewYaw), 0, -cosf(viewYaw))
        let right = SIMD3<Float>(cosf(viewYaw), 0, -sinf(viewYaw))
        return forward * axis.y + right * axis.x
    }

    /// Turns toward a movement input for one step, and says whether it is backing away.
    ///
    /// **Backing away keeps it facing forward.** It faces the strafe and the *forward* part of the input — `|axis.y|`
    /// — rather than the direction of travel. Turning to face the camera on a backward input means the step back that
    /// dodges a counter-blow leaves the foe behind you, and with aimed swings the next blow misses until you turn.
    ///
    /// **Mirrored, not special-cased, and that is what keeps it smooth.** Walking forward the two are identical;
    /// strafing the two are identical; and as the input rolls from a strafe into a backpedal the facing moves
    /// continuously from side to front-side to front. A rule of "face forward whenever moving backwards" would flip
    /// ninety degrees the instant a strafe picked up the slightest backward component.
    ///
    /// - Parameters:
    ///   - axis: the movement input, x right and y forward in the view's frame. Zero is standing still, which neither
    ///     turns nor backpedals.
    ///   - viewYaw: the camera's yaw — ``OrbitCamera/yaw``.
    public mutating func turn(toward axis: SIMD2<Float>, viewYaw: Float, deltaTime: Float) {
        guard axis != .zero else {
            isBackpedaling = false
            return
        }
        if !isHeld {
            let faced = Self.direction(of: SIMD2(axis.x, abs(axis.y)), viewYaw: viewYaw)
            // Turn toward it rather than snapping, and take the short way round: without the wrap, turning from yaw
            // 179° to -179° spins the character a full circle to cover 2°.
            let target = atan2f(-faced.x, -faced.z)
            var delta = target - yaw
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            yaw += delta * (1 - exp2(-deltaTime / tuning.turnHalfLife))
        }
        isBackpedaling = simd_dot(normalize(Self.direction(of: axis, viewYaw: viewYaw)), heading) < -0.1
    }

    /// `pace` slowed by how much of the input points backwards.
    ///
    /// **In proportion, not all-or-nothing.** A pure backpedal gets the whole of ``Tuning/backpedalPace``, a strafe
    /// none, and a diagonal its share — so rolling from a strafe into a backpedal slows the character smoothly, matching
    /// how the facing turns. An all-or-nothing rule would drop the speed by forty percent the instant a strafe picked up
    /// the slightest backward component.
    ///
    /// - Parameter minimum: **never slowed below this** (nor above `pace`): the slowest pace the game's walk clip is
    ///   animated at. A gentle backpedal slowed to 60% would play the walk slower than it was animated, and a stride
    ///   played well below its own pace reads as slower than the gait it replaced.
    public func backpedalled(_ pace: Float, axis: SIMD2<Float>, minimum: Float = 0) -> Float {
        let magnitude = length(axis)
        guard magnitude > 0, pace > 0 else { return pace }
        let backward = max(0, -axis.y) / magnitude
        let slowed = pace * (1 - (1 - tuning.backpedalPace) * backward)
        return max(slowed, min(pace, minimum))
    }
}
