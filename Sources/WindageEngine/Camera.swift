//
//  Camera.swift
//  WindageEngine
//

import simd

/// What the player is asking the camera to do this step.
///
/// Axes rather than key names: the camera should not know what a keyboard is, so a gamepad stick or
/// a replay file can drive it later without touching this file.
public nonisolated struct MovementInput: Equatable, Sendable {
    /// +1 forward, -1 back.
    public var forward: Float = 0
    /// +1 right, -1 left.
    public var strafe: Float = 0
    /// +1 up, -1 down, along **world** up rather than the camera's.
    public var vertical: Float = 0
    /// Whether the player asked to go fast.
    public var isSprinting: Bool = false

    /// **Spelled out rather than synthesized.** A memberwise initializer stays `internal`, so a
    /// consumer outside this module can read a `MovementInput` and never construct one — an access
    /// error that reads like a missing declaration.
    public init(forward: Float = 0, strafe: Float = 0, vertical: Float = 0, isSprinting: Bool = false) {
        self.forward = forward
        self.strafe = strafe
        self.vertical = vertical
        self.isSprinting = isSprinting
    }

    public static let still = MovementInput()
}

/// A first-person camera, in meters.
///
/// **An eye, not a body.** ``advance(_:deltaTime:)`` flies — along the look direction, through
/// anything — which is right for an editor, a photo mode or a title that genuinely flies. A game
/// with feet moves a ``CharacterController`` instead and puts this camera at its ``CharacterController/eye``:
/// walking is along the ground plane, not the look direction, and that difference is the reason the
/// two are separate types.
///
/// Orientation is yaw and pitch, with no roll. Quaternions would buy nothing here: pitch is clamped
/// short of vertical, so the degenerate case they exist to avoid is unreachable, and Euler angles
/// are far easier to read in a debugger and to clamp meaningfully.
///
/// **The limits hold however the angles are set**: ``yaw`` is wrapped and ``pitch`` clamped on every
/// assignment, not only by the camera's own turning — a game nudging the view for recoil or a
/// turntable cannot leave it somewhere the camera promises it never is.
public nonisolated struct Camera: Sendable, Equatable {

    /// How the camera moves and turns. **A game's numbers, with the defaults the engine was tuned
    /// with** — the same arrangement as ``CharacterController/Tuning``.
    public struct Tuning: Sendable, Equatable {
        /// Meters per second, for ``Camera/advance(_:deltaTime:)``.
        public var walkSpeed: Float = 6
        public var sprintSpeed: Float = 18

        /// Radians of rotation per unit of mouse movement.
        public var lookSensitivity: Float = 0.0022

        /// Radians per second at full stick deflection.
        public var stickLookSpeed: Float = 3.2

        public init(walkSpeed: Float = 6, sprintSpeed: Float = 18,
                    lookSensitivity: Float = 0.0022, stickLookSpeed: Float = 3.2) {
            self.walkSpeed = walkSpeed
            self.sprintSpeed = sprintSpeed
            self.lookSensitivity = lookSensitivity
            self.stickLookSpeed = stickLookSpeed
        }
    }

    /// Meters. Y is up.
    public var position: SIMD3<Float>

    /// Radians. 0 looks down -Z; positive turns left. **Always within `(-π, π]`** — wrapped when set.
    public var yaw: Float {
        didSet { yaw = Float.wrappedAngle(yaw) }
    }

    /// Radians. Positive looks up. **Always within ``pitchLimit``** — clamped when set.
    public var pitch: Float {
        didSet { pitch = Camera.clampedPitch(pitch) }
    }

    public var tuning: Tuning

    /// Just short of straight up or down.
    ///
    /// At exactly ±90° the look direction becomes parallel to world up and the right vector is
    /// undefined, so the view matrix degenerates and the image snaps. Every first-person game stops
    /// slightly short for this reason.
    public static let pitchLimit: Float = 89 * .pi / 180

    private static func clampedPitch(_ pitch: Float) -> Float {
        min(max(pitch, -pitchLimit), pitchLimit)
    }

    public init(position: SIMD3<Float> = .zero, yaw: Float = 0, pitch: Float = 0, tuning: Tuning = Tuning()) {
        self.position = position
        self.yaw = Float.wrappedAngle(yaw)
        self.pitch = Camera.clampedPitch(pitch)
        self.tuning = tuning
    }

    // MARK: - Basis

    public var forward: SIMD3<Float> {
        SIMD3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    }

    /// Horizontal only, so strafing never drifts up or down when looking at the sky.
    public var right: SIMD3<Float> {
        SIMD3(cos(yaw), 0, -sin(yaw))
    }

    public var up: SIMD3<Float> {
        simd_cross(right, forward)
    }

    /// World space to view space. Right-handed: the camera looks down **-Z**, so anything in front
    /// of it has a negative view-space Z.
    public var viewMatrix: simd_float4x4 {
        let f = forward, r = right, u = up
        return simd_float4x4(columns: (
            SIMD4<Float>(r.x, u.x, -f.x, 0),
            SIMD4<Float>(r.y, u.y, -f.y, 0),
            SIMD4<Float>(r.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(r, position), -simd_dot(u, position), simd_dot(f, position), 1)
        ))
    }

    // MARK: - Input

    /// Applies mouse movement.
    ///
    /// **Not scaled by delta time.** A mouse delta is a displacement the player already made, not a
    /// rate: scaling it by frame duration would make the same physical hand movement turn further
    /// on a slow frame, which is the classic way to make aiming feel unpredictable. Movement below
    /// *is* a rate and is scaled.
    public mutating func look(mouseDelta: SIMD2<Float>) {
        yaw -= mouseDelta.x * tuning.lookSensitivity
        pitch -= mouseDelta.y * tuning.lookSensitivity
    }

    /// Applies stick look.
    ///
    /// **Deliberately separate from ``look(mouseDelta:)``, because the two are different kinds of
    /// quantity and mixing them up ruins the feel of one or the other.** A mouse reports a
    /// displacement that already happened, so it must *not* be scaled by time. A stick reports a
    /// held position, which is a rate — hold it for twice as long and you should turn twice as far
    /// — so it *must* be. Feeding a stick through the mouse path makes turning depend on frame
    /// rate; feeding a mouse through the stick path makes fast flicks turn less than slow ones.
    public mutating func turn(rate: SIMD2<Float>, deltaTime: Float) {
        guard rate != .zero else { return }
        yaw -= rate.x * tuning.stickLookSpeed * deltaTime
        pitch += rate.y * tuning.stickLookSpeed * deltaTime
    }

    /// Advances position by one simulation step.
    public mutating func advance(_ input: MovementInput, deltaTime: Float) {
        var direction = forward * input.forward + right * input.strafe + SIMD3<Float>(0, 1, 0) * input.vertical
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared > 0 else { return }

        // **Clamped to 1, not normalised**, so holding two keys at once is not faster than one — and
        // a stick pushed a third of the way goes a third as fast. Normalising did the first and
        // broke the second: every deflection past the dead zone flew at full speed (2026-09-11).
        if lengthSquared > 1 { direction /= lengthSquared.squareRoot() }

        let speed = input.isSprinting ? tuning.sprintSpeed : tuning.walkSpeed
        position += direction * speed * deltaTime
    }

    // MARK: - Interpolation

    /// Blends between two simulation steps for display, so motion stays smooth when the display
    /// runs at a different rate from the simulation.
    public static func interpolated(from start: Camera, to end: Camera, alpha: Float) -> Camera {
        var result = start
        result.position = simd_mix(start.position, end.position, SIMD3(repeating: alpha))
        result.yaw = start.yaw + Float.shortestAngle(from: start.yaw, to: end.yaw) * alpha
        result.pitch = start.pitch + (end.pitch - start.pitch) * alpha
        return result
    }
}
