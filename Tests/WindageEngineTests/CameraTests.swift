//
//  CameraTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

struct CameraTests {

    /// Transforms a world point into view space, which is what the camera is ultimately for.
    private func viewSpace(_ world: SIMD3<Float>, through camera: Camera) -> SIMD3<Float> {
        let transformed = camera.viewMatrix * SIMD4<Float>(world, 1)
        return SIMD3(transformed.x, transformed.y, transformed.z)
    }

    // MARK: - Orientation

    @Test("A default camera looks down -Z, and what it sees lands in front of it")
    func defaultOrientation() {
        let camera = Camera()
        let seen = viewSpace(SIMD3(0, 0, -10), through: camera)
        #expect(abs(seen.x) < 1e-5)
        #expect(abs(seen.y) < 1e-5)
        // Right-handed: in front of the camera means negative view-space Z.
        #expect(abs(seen.z - (-10)) < 1e-4)
    }

    @Test("Positive yaw turns left")
    func yawTurnsLeft() {
        let camera = Camera(yaw: .pi / 2)
        // After turning 90° left the camera faces -X, so a point out at -X is now dead ahead.
        let seen = viewSpace(SIMD3(-10, 0, 0), through: camera)
        #expect(abs(seen.x) < 1e-4)
        #expect(abs(seen.z - (-10)) < 1e-4)
    }

    @Test("Moving the camera moves the world the opposite way")
    func translationInverts() {
        let camera = Camera(position: SIMD3(0, 0, 10))
        let seen = viewSpace(.zero, through: camera)
        #expect(abs(seen.z - (-10)) < 1e-4)
    }

    @Test("Pitch cannot reach vertical")
    func pitchIsClamped() {
        var camera = Camera()
        camera.look(mouseDelta: SIMD2(0, -100_000))
        #expect(camera.pitch <= Camera.pitchLimit)
        camera.look(mouseDelta: SIMD2(0, 200_000))
        #expect(camera.pitch >= -Camera.pitchLimit)
        // Still a usable basis at the limit — the degenerate case is what the clamp exists to avoid.
        #expect(simd_length(camera.up) > 0.9)
    }

    // MARK: - Movement

    @Test("Walking covers exactly the stated metres per second")
    func speedIsInMetresPerSecond() {
        var camera = Camera()
        var input = MovementInput(); input.forward = 1

        let step: Float = 1.0 / 120.0
        for _ in 0..<120 { camera.advance(input, deltaTime: step) }

        #expect(abs(simd_length(camera.position) - Camera.Tuning().walkSpeed) < 1e-3)
    }

    /// The classic bug: holding forward *and* right moves you √2 times faster than either alone.
    @Test("Diagonal movement is not faster than straight")
    func diagonalIsNotFaster() {
        var camera = Camera()
        var input = MovementInput(); input.forward = 1; input.strafe = 1

        let step: Float = 1.0 / 120.0
        for _ in 0..<120 { camera.advance(input, deltaTime: step) }

        #expect(abs(simd_length(camera.position) - Camera.Tuning().walkSpeed) < 1e-3)
    }

    @Test("Strafing never drifts vertically, even looking at the sky")
    func strafeStaysLevel() {
        var camera = Camera(pitch: Camera.pitchLimit)
        var input = MovementInput(); input.strafe = 1
        for _ in 0..<120 { camera.advance(input, deltaTime: 1.0 / 120.0) }
        #expect(abs(camera.position.y) < 1e-5)
    }

    /// The same property `FixedTimestep` guarantees, checked through the camera: the distance
    /// covered in one second of simulated time must not depend on the step count.
    @Test("Distance covered does not depend on step rate")
    func movementIsStepRateIndependent() {
        func distanceAfterOneSecond(steps: Int) -> Float {
            var camera = Camera()
            var input = MovementInput(); input.forward = 1
            let step = 1.0 / Float(steps)
            for _ in 0..<steps { camera.advance(input, deltaTime: step) }
            return simd_length(camera.position)
        }
        #expect(abs(distanceAfterOneSecond(steps: 120) - distanceAfterOneSecond(steps: 60)) < 1e-3)
        #expect(abs(distanceAfterOneSecond(steps: 120) - distanceAfterOneSecond(steps: 240)) < 1e-3)
    }

    @Test("Sprinting is faster than walking")
    func sprintIsFaster() {
        func distance(sprinting: Bool) -> Float {
            var camera = Camera()
            var input = MovementInput(); input.forward = 1; input.isSprinting = sprinting
            for _ in 0..<120 { camera.advance(input, deltaTime: 1.0 / 120.0) }
            return simd_length(camera.position)
        }
        #expect(distance(sprinting: true) > distance(sprinting: false))
    }

    // MARK: - Angles

    @Test("Yaw stays wrapped rather than growing without bound")
    func yawStaysWrapped() {
        var camera = Camera()
        // Spin a long way in small increments, as a long session would.
        for _ in 0..<10_000 { camera.look(mouseDelta: SIMD2(50, 0)) }
        #expect(camera.yaw > -Float.pi && camera.yaw <= .pi)
    }

    /// Turning from 179° to -179° is 2° of movement. A naive blend travels 358° of it instead.
    @Test("Interpolation crosses the angle seam the short way")
    func interpolationTakesShortestPath() {
        let start = Camera(yaw: .pi - 0.05)
        let end = Camera(yaw: -.pi + 0.05)

        let midpoint = Camera.interpolated(from: start, to: end, alpha: 0.5)
        // The short way passes through ±π, not through zero.
        #expect(abs(midpoint.yaw) > .pi - 0.02)
    }

    @Test("Interpolation lands exactly on the endpoints")
    func interpolationEndpoints() {
        let start = Camera(position: SIMD3(1, 2, 3), yaw: 0.3, pitch: 0.1)
        let end = Camera(position: SIMD3(4, 5, 6), yaw: -0.7, pitch: -0.2)

        let atStart = Camera.interpolated(from: start, to: end, alpha: 0)
        let atEnd = Camera.interpolated(from: start, to: end, alpha: 1)

        #expect(simd_length(atStart.position - start.position) < 1e-6)
        #expect(abs(atStart.yaw - start.yaw) < 1e-6)
        #expect(simd_length(atEnd.position - end.position) < 1e-5)
        #expect(abs(atEnd.yaw - end.yaw) < 1e-5)
    }

    /// Mouse input is a displacement the player already made, not a rate. If it were scaled by
    /// frame duration, the same physical hand movement would turn further on a slow frame.
    @Test("Mouse look is not affected by how long the frame took")
    func lookIsNotTimeScaled() {
        var a = Camera(), b = Camera()
        a.look(mouseDelta: SIMD2(100, 0))
        for _ in 0..<10 { b.look(mouseDelta: SIMD2(10, 0)) }
        #expect(abs(a.yaw - b.yaw) < 1e-5)
    }

    // MARK: - The limits hold when set

    /// **Settable past the clamp** was the fault: a game nudging the view for recoil left a pitch the
    /// camera promises it never has, and the view matrix degenerates at ±90°.
    @Test("Pitch set past the limit is clamped, and yaw set past a half turn is wrapped")
    func limitsHoldWhenSet() {
        var camera = Camera()
        camera.pitch = 3
        #expect(camera.pitch == Camera.pitchLimit)
        camera.pitch -= 10
        #expect(camera.pitch == -Camera.pitchLimit)
        camera.yaw = 3 * .pi / 2
        #expect(abs(camera.yaw + .pi / 2) < 1e-5)
        camera.yaw += 40 * .pi
        #expect(camera.yaw > -.pi && camera.yaw <= .pi)
        camera.yaw = .pi
        #expect(camera.yaw == .pi, "π is inside the range and stays π")
    }

    @Test("Each camera carries its own tuning, starting at the engine's")
    func tuningPerCamera() {
        #expect(Camera().tuning == Camera.Tuning(walkSpeed: 6, sprintSpeed: 18, lookSensitivity: 0.0022, stickLookSpeed: 3.2))
        var slow = Camera(tuning: .init(walkSpeed: 2, lookSensitivity: 0.001))
        var standard = Camera()
        slow.advance(MovementInput(forward: 1), deltaTime: 1)
        standard.advance(MovementInput(forward: 1), deltaTime: 1)
        #expect(abs(simd_length(slow.position) - 2) < 1e-5 && abs(simd_length(standard.position) - 6) < 1e-5)
        slow.look(mouseDelta: SIMD2(100, 0))
        standard.look(mouseDelta: SIMD2(100, 0))
        #expect(abs(slow.yaw * 2.2 - standard.yaw) < 1e-5)
        #expect(Camera.interpolated(from: slow, to: slow, alpha: 0.5).tuning == slow.tuning)
    }

    @Test("Cameras compare by everything they hold")
    func equatable() {
        #expect(Camera(position: SIMD3(1, 2, 3), yaw: 0.5) == Camera(position: SIMD3(1, 2, 3), yaw: 0.5))
        #expect(Camera() != Camera(tuning: .init(walkSpeed: 7)))
    }

    // MARK: - Speed scale and boost

    /// One second of flying forward, a step at a time, at 120 steps a second.
    private func flown(_ camera: inout Camera, seconds: Float, _ input: MovementInput = MovementInput(forward: 1)) -> Float {
        let start = camera.position
        for _ in 0..<Int((seconds * 120).rounded()) { camera.advance(input, deltaTime: 1.0 / 120) }
        return simd_distance(start, camera.position)
    }

    @Test("A speed scale multiplies both speeds; a default camera is as it was")
    func speedScaleMultiplies() {
        var plain = Camera(), scaled = Camera(tuning: .init(speedScale: 4))
        #expect(abs(flown(&plain, seconds: 1) - 6) < 1e-3)
        #expect(abs(flown(&scaled, seconds: 1) - 24) < 1e-2)
        var sprinting = Camera(tuning: .init(speedScale: 0.5))
        #expect(abs(flown(&sprinting, seconds: 1, MovementInput(forward: 1, isSprinting: true)) - 9) < 1e-2)
    }

    @Test("A held direction builds to the boost over its time, and letting go starts again")
    func boostBuildsAndResets() {
        var camera = Camera(tuning: .init(walkSpeed: 10, boost: 4, boostTime: 2))
        let first = flown(&camera, seconds: 0.1)
        #expect(first < 1.05, "a tap moves at the speed set: \(first) m in 0.1 s")
        _ = flown(&camera, seconds: 2)
        #expect(abs(camera.boostNow - 4) < 1e-4)
        #expect(abs(flown(&camera, seconds: 1) - 40) < 0.05, "held, four times the speed")
        camera.advance(.still, deltaTime: 1.0 / 120)
        #expect(camera.heldFor == 0 && camera.boostNow == 1)
    }

    @Test("Speed steps double, hold at the ends, and start from the nearest step")
    func speedSteps() {
        var tuning = Camera.Tuning()
        tuning.stepSpeedScale(1); #expect(tuning.speedScale == 2)
        tuning.stepSpeedScale(10); #expect(tuning.speedScale == 8)
        tuning.stepSpeedScale(-20); #expect(tuning.speedScale == 0.125)
        tuning.speedScale = 3.1
        tuning.stepSpeedScale(1); #expect(tuning.speedScale == 8, "3.1 is nearest 4, and up one is 8")
    }
}
