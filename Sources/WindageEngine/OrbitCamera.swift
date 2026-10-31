//
//  OrbitCamera.swift
//  WindageEngine
//

import simd

/// A third-person camera: it orbits a point on a character, follows it, keeps out of the scenery, and eases itself
/// back behind the character while the player runs and does not steer.
///
/// ### Extracted from a game that is played with it
///
/// **None of this is new.** A third-person game built on this engine has been played with this camera from its first
/// day, and every number here that says how it feels was settled in play, with the reason beside it. Two things
/// changed on the way in. The numbers a game picks for itself moved into ``Tuning``, where they had been constants.
/// And the scenery the camera keeps out of is the ``CharacterController/Surroundings`` a body walks in — **one
/// description of the world, because it is one fact about the world**: a pillar that is solid to the body and not to
/// the camera is a pillar the game disagrees with itself about, and it shows as the camera pulling in against
/// something the player just walked through.
///
/// **A first-person view is ``Camera``**, placed at ``CharacterController/eye``. A game with both — first person to
/// fight, third person to be seen — keeps one of each and draws through whichever is in use. They share a yaw
/// convention (0 looks down −Z, positive turns left), so either can be handed the other's heading when the view
/// switches; **pitch is the other way round** — here positive raises the camera, so the view looks down.
///
/// **Third person is a decision, not a default.** It costs a rig, locomotion, this camera and its collision, for
/// ever. What pays for it is a player who needs to see their character — gear they chose, bought or earned — and
/// that is also why the camera orbits rather than sits on the character's eyes.
///
/// ### Stepped, then drawn between steps
///
/// Turn it with ``orbit(byYaw:pitch:)`` and ``zoom(by:)``, then once a simulation step: ``follow(_:deltaTime:)``
/// the character, ``recentre(behind:deltaTime:active:)``, and ``keepClear(of:deltaTime:)``. A frame that falls
/// between two steps draws ``interpolated(from:to:alpha:)``.
public nonisolated struct OrbitCamera: Sendable, Equatable {

    /// How the camera sits, follows, eases back and keeps clear. **A game's numbers, with the defaults the engine was
    /// tuned with** — the same arrangement as ``Camera/Tuning`` and ``CharacterController/Tuning``. Each default was
    /// settled in play, and its reason is on it.
    public struct Tuning: Sendable, Equatable {

        /// How near and far the player may zoom, in meters from the aim point.
        public var distanceRange: ClosedRange<Float> = 2.5...18

        /// How far the camera tilts up or down, in radians. **Kept away from straight up and straight down**: at
        /// exactly vertical the look-at basis is degenerate — `cross(forward, up)` is zero — and the view flips
        /// through itself.
        public var pitchLimit: Float = 78 * .pi / 180

        /// Where the pitch eases back to, in radians.
        ///
        /// **7°, and this number could not be decided on its own.** A resting pitch is only meaningful against a
        /// field of view: what the player sees is where the *horizon* falls in the frame, and that is
        /// `(pitch + fov/2) / fov`. At the default 45° field of view, 7° puts the horizon **66%** of the way down the
        /// frame. 12° — right for this camera when it had a 65° field of view, where it put the horizon at 68% —
        /// puts it **77%** down at 45°: a camera that insists on staring at the ground.
        ///
        /// **The lesson is the pairing, not either number.** Changing one of these without the other is how this went
        /// wrong in both directions; the tests assert the horizon, not the pitch.
        public var restingPitch: Float = 7 * .pi / 180

        /// Where the zoom eases back to. **The same as the opening distance**, or running forward would quietly move
        /// the camera somewhere the player never put it.
        public var restingDistance: Float = 5.5

        /// Seconds of no look input before the camera starts easing back.
        public var recentreWait: Float = 0.5
        /// Seconds the yaw and pitch take to come home — 94% of the way (see ``recentre(behind:deltaTime:active:)``).
        public var recentreTurnTime: Float = 1.2
        /// The zoom's own, deliberately longer: **three times, not one**, so the three do not move as one block, which
        /// reads as the whole picture sliding rather than as a camera settling.
        public var recentreZoomTime: Float = 1.2 * 1.4

        /// How quickly the focus catches up with what it follows, as a half-life in seconds — see
        /// ``follow(_:deltaTime:)``.
        public var followHalfLife: Float = 0.08

        /// How long the camera takes to come back out from behind scenery, as a half-life in seconds.
        ///
        /// **0.6 s, chosen by playing the same corner at 0.18, 0.35, 0.6 and 0.9.** It started at 0.18, which read as
        /// a transition rather than a drift — half-lives are not intuitive, and that one has the camera three quarters
        /// of the way back in a third of a second. Cycling the value from a debug menu so they can be felt one after
        /// another, instead of guessed at, is the only way a number like this gets settled.
        ///
        /// **Worth re-judging in a fight rather than on a walk.** At 0.6 the camera is still easing out a second
        /// later, which is calm when you round a building and could read as lag when you are weaving around a pillar
        /// with something on you.
        public var recoveryHalfLife: Float = 0.6

        /// How far the camera is treated as being a ball rather than a point, in meters.
        ///
        /// **A ray finds the wall a frame after the near plane has already gone through it.** The camera sees a
        /// frustum, not a point, so the corner of a pillar enters the picture while the camera's own position is
        /// still in clear air. Growing the boxes by this instead of sweeping a real sphere is the standard trade: it
        /// rounds the corners the wrong way — the camera is pushed in slightly early at a box's edge — and it costs a
        /// slab test rather than a solver.
        public var probeRadius: Float = 0.4

        /// How close to the aim point the camera may be pulled before it stops, in meters.
        ///
        /// At zero the camera would end up inside the character's own head, and the character would fill the screen
        /// with the inside of a shoulder. This is roughly the first-person distance: a squeeze this tight is
        /// unpleasant, but it is a view.
        public var minimumDistance: Float = 0.8

        /// How far above the ground the camera must stay, in meters. Tilting the view all the way down otherwise
        /// buries the camera in the ground and the world turns to fog.
        public var groundClearance: Float = 0.5

        public init(distanceRange: ClosedRange<Float> = 2.5...18, pitchLimit: Float = 78 * .pi / 180,
                    restingPitch: Float = 7 * .pi / 180, restingDistance: Float = 5.5,
                    recentreWait: Float = 0.5, recentreTurnTime: Float = 1.2, recentreZoomTime: Float = 1.2 * 1.4,
                    followHalfLife: Float = 0.08, recoveryHalfLife: Float = 0.6,
                    probeRadius: Float = 0.4, minimumDistance: Float = 0.8, groundClearance: Float = 0.5) {
            self.distanceRange = distanceRange
            self.pitchLimit = pitchLimit
            self.restingPitch = restingPitch
            self.restingDistance = restingDistance
            self.recentreWait = recentreWait
            self.recentreTurnTime = recentreTurnTime
            self.recentreZoomTime = recentreZoomTime
            self.followHalfLife = followHalfLife
            self.recoveryHalfLife = recoveryHalfLife
            self.probeRadius = probeRadius
            self.minimumDistance = minimumDistance
            self.groundClearance = groundClearance
        }
    }

    public var tuning: Tuning

    /// What the camera looks at, before the shoulder offset — normally the character's feet.
    public var focus: SIMD3<Float> = .zero

    /// Around the focus, in radians. Zero looks down −Z; positive turns left. **Not wrapped**: every turn, blend and
    /// recentre here goes the short way round whatever its value.
    public var yaw: Float = 0

    /// Positive tilts the camera up and the view down. Clamped in ``orbit(byYaw:pitch:)``.
    public var pitch: Float = 12 * .pi / 180

    /// What the player asked for, with the wheel or the triggers. Starts at ``Tuning/restingDistance``.
    ///
    /// **It arrives with its field of view.** At 7 m and 65° a character drew at about half the size it did at
    /// 5.5 m and 45° — measured, not estimated — and a third-person game whose character is half the size it should
    /// be reads as a camera left outside the scene. Distance is the smaller half of that: the field of view was doing
    /// most of it.
    public var distance: Float

    /// How far back the scenery will let the camera sit, smoothed.
    ///
    /// **Separate from the player's own choice, and the two are combined rather than merged.** Folding the
    /// obstruction into `distance` means squeezing past a pillar permanently resets how far back the camera sits and
    /// the player has to scroll out again — which reads as the zoom drifting on its own. Keeping them apart also
    /// means a wheel zoom arrives on the frame it was asked for while the scenery's own changes are eased.
    public private(set) var clearance: Float

    /// Where the camera actually ends up: the nearer of what was asked for and what fits.
    public var workingDistance: Float { min(distance, clearance) }

    /// Raises the aim point off the ground so the character sits in the lower third of the frame rather than dead
    /// centre, which is where a third-person camera reads best. A game sets it from the character's height.
    public var shoulderHeight: Float = 1.7

    /// **45°**, vertical, in radians.
    ///
    /// Wide angles make a third-person subject small and distant and they exaggerate perspective, so a character near
    /// the edge of the frame leans and stretches. 65° is a first-person number; 45 *"flattens perspective so the
    /// character reads bigger and less distorted, and distant terrain reads larger"*, which is the whole complaint
    /// this answers. **It is paired with ``Tuning/restingPitch``** — change one, re-judge the other.
    public var fieldOfView: Float = 45 * .pi / 180
    public var nearPlane: Float = 0.1

    /// Seconds since the player last moved the camera themselves.
    ///
    /// **Starts enormous, meaning "not recently".** A camera that begins life believing it was just touched would sit
    /// still for the first half second of the game.
    public private(set) var sinceLook: Float = .greatestFiniteMagnitude

    /// Whether the camera is currently easing itself back.
    public private(set) var isRecentring = false

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        distance = tuning.restingDistance
        clearance = tuning.distanceRange.upperBound
    }

    // MARK: - Where it is

    public var aimPoint: SIMD3<Float> { focus + SIMD3(0, shoulderHeight, 0) }

    /// Where the camera actually sits, derived rather than stored, so focus and angles are the only state that can
    /// disagree with each other.
    public var position: SIMD3<Float> { aimPoint + offsetDirection * workingDistance }

    /// Which way the camera sits from what it is looking at. Unit length by construction, and the ray the obstruction
    /// test is cast along — so the test and the placement cannot disagree.
    public var offsetDirection: SIMD3<Float> {
        let horizontal = cosf(pitch)
        return SIMD3(sinf(yaw) * horizontal, sinf(pitch), cosf(yaw) * horizontal)
    }

    /// The direction the character moves when the player holds forward: the camera's facing, flattened onto the
    /// ground. Movement follows the camera, which is what "forward" means in a third-person game.
    public var groundForward: SIMD3<Float> { SIMD3(-sinf(yaw), 0, -cosf(yaw)) }
    public var groundRight: SIMD3<Float> { SIMD3(cosf(yaw), 0, -sinf(yaw)) }

    /// World space to view space, looking from ``position`` at ``aimPoint``. Right-handed, as ``Camera/viewMatrix``:
    /// the camera looks down **−Z**.
    public var viewMatrix: simd_float4x4 {
        let eye = position
        let forward = normalize(aimPoint - eye)
        let right = normalize(cross(forward, SIMD3(0, 1, 0)))
        let trueUp = cross(right, forward)
        return simd_float4x4(columns: (SIMD4(right.x, trueUp.x, -forward.x, 0),
                                       SIMD4(right.y, trueUp.y, -forward.y, 0),
                                       SIMD4(right.z, trueUp.z, -forward.z, 0),
                                       SIMD4(-dot(right, eye), -dot(trueUp, eye), dot(forward, eye), 1)))
    }

    /// The engine's projection — reversed Z, infinite far plane — at this camera's field of view and near plane.
    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        simd_float4x4(perspectiveFovY: fieldOfView, aspectRatio: aspect, nearZ: nearPlane)
    }

    /// **The camera between two simulation steps**, `alpha` of the way from `start` to `end` — what a frame shows when
    /// it falls between steps. The world is stepped at a fixed rate and drawn whenever the display asks; drawn at the
    /// last step instead, a frame is up to a step behind, by a different amount every frame, and the view judders
    /// while moving.
    ///
    /// Everything that places the camera is blended — focus, angles, the distance it is seen from — and the rest is
    /// the latest step's. **A copy for drawing**: its clearance is the blended working distance, never stepped
    /// further. **The yaw goes the short way round**: a camera turning through ±π would otherwise spin the long way
    /// for a frame.
    public static func interpolated(from start: OrbitCamera, to end: OrbitCamera, alpha: Float) -> OrbitCamera {
        var camera = end
        let t = min(max(alpha, 0), 1)
        camera.focus = start.focus + (end.focus - start.focus) * t
        var turn = (end.yaw - start.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
        camera.yaw = end.yaw - turn * (1 - t)
        camera.pitch = start.pitch + (end.pitch - start.pitch) * t
        camera.distance = start.distance + (end.distance - start.distance) * t
        // **What is seen is the nearer of the two**, so that is what is blended: blending each separately would leave
        // a camera pulled in by a pillar at the far distance until halfway. The blend of the nearer ones is never
        // past the blended distance, so it is what the drawn camera shows.
        camera.clearance = start.workingDistance + (end.workingDistance - start.workingDistance) * t
        camera.shoulderHeight = start.shoulderHeight + (end.shoulderHeight - start.shoulderHeight) * t
        return camera
    }

    // MARK: - The player's hands

    public mutating func orbit(byYaw deltaYaw: Float, pitch deltaPitch: Float) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -tuning.pitchLimit), tuning.pitchLimit)
        // **Only a real movement counts as looking.** The stick's delta is handed over every frame whether or not a
        // thumb is on it, so resetting unconditionally would mean the camera had been "just looked at" forever and
        // nothing would ever ease back.
        if deltaYaw != 0 || deltaPitch != 0 { sinceLook = 0 }
    }

    public mutating func zoom(by delta: Float) {
        distance = min(max(distance + delta, tuning.distanceRange.lowerBound), tuning.distanceRange.upperBound)
        // **A wheel notch arrives this frame, outwards as well as inwards.** `clearance` is capped at the distance the
        // player asked for (see `constrain`), so zooming out without raising it would leave the view at the old
        // distance and ease into the new one — a zoom that lags the hand. Scenery cannot be cheated by this: the
        // obstruction test runs after the zoom in the same frame, and it pulls in at once.
        clearance = max(clearance, distance)
        if delta != 0 { sinceLook = 0 }
    }

    // MARK: - Following

    /// Eases the focus toward the character instead of snapping to it, so a stutter in movement does not become a
    /// stutter in the whole view.
    ///
    /// **Framed in terms of a half-life rather than a per-frame lerp factor.** `focus += (target - focus) * 0.2` looks
    /// identical at the frame rate it was tuned on and wrong at every other one — twice as fast at 120 Hz as at 60.
    /// This form is frame-rate independent by construction.
    public mutating func follow(_ target: SIMD3<Float>, deltaTime: Float) {
        let t = 1 - exp2(-deltaTime / tuning.followHalfLife)
        focus += (target - focus) * t
    }

    // MARK: - Easing back behind the character

    /// Eases the camera back behind the character: yaw, pitch and zoom each come home to a resting value after a
    /// pause, but only while the player is running roughly forwards and not steering. The recentring third-person
    /// cameras commonly have (Cinemachine's, for one), with the conditions that make it work kept with it.
    ///
    /// **The gate is the part worth copying.** Recentring during a *strafe* rotates the camera, which rotates what
    /// "forward" means, which turns the character further — an involuntary slow circle. So it is gated on the
    /// movement input rather than on the character's facing: the character turns to face wherever it moves, so its
    /// heading always agrees with a strafe.
    ///
    /// **Times, not rates**: each `…Time` in ``Tuning`` is four half-lives, so "1.2 seconds" means 94% of the way
    /// rather than a number with no relationship to what is seen.
    ///
    /// - Parameters:
    ///   - facing: the character's heading, in the same convention as ``yaw``.
    ///   - active: whether the player is running roughly forwards. Read it off the movement input, never off the
    ///     character's facing.
    public mutating func recentre(behind facing: Float, deltaTime: Float, active: Bool) {
        sinceLook = min(sinceLook + deltaTime, 1_000)
        guard active, sinceLook >= tuning.recentreWait else {
            isRecentring = false
            return
        }
        isRecentring = true

        // **The short way round.** Without this a camera 179° off swings the long way home, which is a full rotation
        // of the world under a player who pressed nothing.
        var delta = facing - yaw
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        yaw += delta * Self.eased(deltaTime, tuning.recentreTurnTime)

        pitch += (tuning.restingPitch - pitch) * Self.eased(deltaTime, tuning.recentreTurnTime)

        // **Through `zoom(by:)`, not by assignment**, so the clamp and the clearance rule that a wheel notch goes
        // through apply to this too — an eased zoom that skipped them could park the camera outside its own range or
        // leave the view lagging behind the distance.
        let wanted = (tuning.restingDistance - distance) * Self.eased(deltaTime, tuning.recentreZoomTime)
        if wanted != 0 {
            let remembered = sinceLook
            zoom(by: wanted)
            // The camera moved itself; that is not the player looking.
            sinceLook = remembered
        }
    }

    /// The fraction of the remaining distance to cover this frame, for something that takes `time` seconds to come
    /// 94% of the way — four half-lives. **Frame-rate independent**, the same way ``follow(_:deltaTime:)`` is: a
    /// fixed fraction per frame would ease twice as fast on a 120 Hz display.
    private static func eased(_ deltaTime: Float, _ time: Float) -> Float {
        1 - exp2(-deltaTime / (time / 4))
    }

    // MARK: - Keeping out of the scenery

    /// Takes the camera in to what the scenery allows along its own line, and lets it back out gently:
    /// ``allowedDistance(aimPoint:direction:desired:in:tuning:)`` from ``aimPoint`` along ``offsetDirection``, as far
    /// as the zoom could ever reach, then ``constrain(to:deltaTime:)``.
    ///
    /// **A third-person camera that clips is a third-person camera that stops working.** Back into a pillar and the
    /// view is swallowed by it: the player is looking at the inside of a wall with no way to tell which way is out.
    /// It is the one camera fault that cannot be lived with, and it comes with a right stick rather than after it — a
    /// pad player backs into things constantly, because the camera is on a thumb rather than on a hand that can also
    /// be steering.
    ///
    /// **After ``follow(_:deltaTime:)``, not before.** The obstruction is a question about where the camera is going
    /// to be this frame, and the aim point does not settle until the follow has eased it.
    public mutating func keepClear(of surroundings: CharacterController.Surroundings, deltaTime: Float) {
        constrain(to: Self.allowedDistance(aimPoint: aimPoint, direction: offsetDirection,
                                           desired: tuning.distanceRange.upperBound, in: surroundings, tuning: tuning),
                  deltaTime: deltaTime)
    }

    /// Takes the camera in to `allowed`, and lets it back out gently.
    ///
    /// **In at once, out over ``Tuning/recoveryHalfLife``, and the asymmetry is the whole point.** Easing *in* means
    /// the pillar has already clipped through the near plane by the time the camera has finished moving, which is the
    /// fault this exists to prevent. Snapping *out* is a lurch every time the character clears a doorway — the view
    /// leaps backwards under a thumb that did nothing. So the near side is immediate and the far side is a half-life,
    /// frame-rate independent for the same reason ``follow(_:deltaTime:)`` is.
    public mutating func constrain(to allowed: Float, deltaTime: Float) {
        // **Eased toward the distance the player asked for, never past it.** The caller asks the scenery about the
        // *furthest* the camera could sit, and the view shows `min(distance, clearance)` — so easing toward that far
        // number spent the whole ease above the distance anybody could see, and the picture snapped back the moment
        // it crossed. In and out both read as jerks (found by playing).
        let target = min(allowed, distance)
        if target <= clearance {
            clearance = target
        } else {
            clearance += (target - clearance) * (1 - exp2(-deltaTime / tuning.recoveryHalfLife))
            // **A half-life never actually arrives**, and the last millimetre is invisible but not harmless: the
            // camera would sit fractionally short of the distance the player asked for, for ever, and anything
            // comparing the two would be wrong. Five millimetres at seven metres is nothing to look at and about two
            // seconds in.
            if target - clearance < 0.005 { clearance = target }
        }
    }

    /// Metres between samples along the camera's line when looking for the ground.
    ///
    /// **A quarter of a metre**, finer than a terrain's usual 1–2 m grid and coarse enough to cost about seventy
    /// height reads at the camera's furthest. A ridge narrower than this between the character and the camera can be
    /// missed for a frame; a ridge that narrow is a fence, and a fence is a solid or a mesh rather than ground.
    public static let groundStep: Float = 0.25

    /// The distance the camera may actually have, given what is in the way.
    ///
    /// Asks, in order: the meshes (``CollisionMesh/firstHit(from:direction:limit:)``), stopping ``Tuning/probeRadius``
    /// short of the face they meet; each solid, grown by the probe radius; and the ground, staying
    /// ``Tuning/groundClearance`` above it. Never nearer than ``Tuning/minimumDistance``.
    ///
    /// **What the camera does not see**: ``CharacterController/Surroundings/isBlocked`` — a test of a point says
    /// nothing about where along a line the wall begins. A solid's ``CharacterController/Surroundings/Solid/motion``
    /// and `turn` are not needed either: the camera asks every step where things are now.
    ///
    /// - Parameters:
    ///   - aimPoint: What the camera looks at — the character's shoulder height, not their feet.
    ///   - direction: Unit vector from the aim point toward where the camera wants to sit.
    ///   - desired: The furthest the camera wants to be.
    public static func allowedDistance(aimPoint: SIMD3<Float>, direction: SIMD3<Float>, desired: Float,
                                       in surroundings: CharacterController.Surroundings,
                                       tuning: Tuning = Tuning()) -> Float {
        var allowed = desired
        let probeRadius = tuning.probeRadius

        // **Meshes by their real shapes**, stopping the probe's radius short of the face they meet.
        if let meshes = surroundings.meshes,
           let hit = meshes.firstHit(from: aimPoint, direction: direction, limit: allowed + probeRadius) {
            allowed = min(allowed, hit - probeRadius)
        }

        for solid in surroundings.solids {
            if let hit = firstHit(from: aimPoint, direction: direction, limit: allowed, solid: solid,
                                  probeRadius: probeRadius) {
                allowed = hit
            }
        }

        if let hit = firstGroundHit(from: aimPoint, direction: direction, limit: allowed,
                                    height: surroundings.groundHeight, clearance: tuning.groundClearance) {
            allowed = hit
        }
        return max(allowed, tuning.minimumDistance)
    }

    /// How far along the ray the camera first comes within `clearance` of the ground.
    ///
    /// **Marched, not solved, and that is the difference a hill makes.** On a plane the answer is one division, and
    /// asking only about the ground *under the character* would be enough. On a terrain the thing in the way is
    /// usually the slope *behind* them — backing up a hillside with the camera tilted level is the everyday case — and
    /// a check that only knew the height at the character's feet would put the camera inside the hill with the world
    /// gone to fog behind it. A flat world is asked the same way, and the answer is the plane's within a few
    /// millimetres.
    ///
    /// **It refines the last step by bisection**, so the camera stops at the ground rather than at the last sample
    /// before it. Without that it would jump in quarter-metre notches as it slid along a slope.
    static func firstGroundHit(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float,
                               height: (Float, Float) -> Float, clearance: Float) -> Float? {
        func below(_ t: Float) -> Bool {
            let p = origin + direction * t
            return p.y < height(p.x, p.z) + clearance
        }
        // **An aim point already inside the clearance is not a hit at zero.** The aim point is at shoulder height and
        // the clearance is half a metre, so this only happens in a hollow the character is standing in, or under
        // ground that runs on overhead — a cave — and answering zero there would pin the camera at its minimum for as
        // long as they stood there.
        guard !below(0) else { return nil }

        var previous: Float = 0
        var t = groundStep
        while t < limit {
            if below(t) {
                var lo = previous, hi = t
                for _ in 0..<6 {
                    let mid = (lo + hi) / 2
                    if below(mid) { hi = mid } else { lo = mid }
                }
                return lo
            }
            previous = t
            t += groundStep
        }
        return below(limit) ? previous : nil
    }

    /// Where the ray first enters the solid, grown by the probe radius, or `nil` if it misses within `limit`.
    ///
    /// **A solid is an upright box turned about its own vertical**: its ``CharacterController/Surroundings/Solid/footprint``
    /// across and its bounds up, or its bounds alone when it has no footprint. A round footprint is tested as the
    /// square round it, which pulls the camera in a little early past a column's rim — the same side the probe's
    /// grown corners already err on. The ray is taken into the box's own frame — one rotation about Y — where it is an
    /// axis-aligned box and the test is three slabs.
    private static func firstHit(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float,
                                 solid: CharacterController.Surroundings.Solid, probeRadius: Float) -> Float? {
        let centre: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float
        let low = solid.bounds.minimum.y, high = solid.bounds.maximum.y
        if let footprint = solid.footprint {
            centre = SIMD3(footprint.center.x, (low + high) / 2, footprint.center.y)
            halfExtents = SIMD3(footprint.halfSize.x, (high - low) / 2, footprint.halfSize.y)
            yaw = footprint.yaw
        } else {
            centre = solid.bounds.center
            halfExtents = solid.bounds.size / 2
            yaw = 0
        }

        let toOrigin = origin - centre
        let c = cosf(yaw), s = sinf(yaw)
        // The inverse of a yaw rotation, applied to both the offset and the direction.
        let localOrigin = SIMD3<Float>(c * toOrigin.x - s * toOrigin.z,
                                       toOrigin.y,
                                       s * toOrigin.x + c * toOrigin.z)
        let localDirection = SIMD3<Float>(c * direction.x - s * direction.z,
                                          direction.y,
                                          s * direction.x + c * direction.z)
        // **Inside the true box is not a hit; inside the widened one is.** The two cases look the same to a slab test
        // and mean opposite things. Standing with your back a hand's width from a wall puts the aim point inside the
        // *widened* box, and the camera must be pulled all the way in — otherwise it sits on the far side and the
        // player is looking at masonry. Being inside the *true* box means the character is embedded in the scenery,
        // which is a bug somewhere else, and pulling the camera to nothing turns it into a bug here as well.
        if abs(localOrigin.x) < halfExtents.x && abs(localOrigin.y) < halfExtents.y && abs(localOrigin.z) < halfExtents.z {
            return nil
        }

        let bounds = halfExtents + SIMD3(repeating: probeRadius)
        var near: Float = 0
        var far = limit

        for axis in 0..<3 {
            let d = localDirection[axis]
            let o = localOrigin[axis]
            if abs(d) < 1e-6 {
                // Parallel to this pair of faces: either always between them or never.
                if abs(o) > bounds[axis] { return nil }
                continue
            }
            var t0 = (-bounds[axis] - o) / d
            var t1 = (bounds[axis] - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            near = max(near, t0)
            far = min(far, t1)
            if near > far { return nil }
        }

        // `near` clamps at zero above, so a wall already within the probe's radius answers "no distance at all" and
        // the caller's minimum takes over from there.
        return near
    }
}
