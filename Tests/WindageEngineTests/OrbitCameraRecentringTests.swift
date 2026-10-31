//
//  OrbitCameraRecentringTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

/// The camera easing back behind the character.
///
/// **The recentring third-person cameras commonly have** (Cinemachine's, for one). These are the
/// rules that make it work, written down so they cannot be lost the way a port usually loses them —
/// by keeping the behaviour and dropping the conditions.
@Suite("Easing back behind the character")
struct OrbitCameraRecentringTests {

    private let tuning = OrbitCamera.Tuning()

    private func running(_ camera: inout OrbitCamera, seconds: Float, facing: Float = 0,
                         active: Bool = true, step: Float = 1.0 / 60) {
        for _ in 0..<Int(seconds / step) {
            camera.recentre(behind: facing, deltaTime: step, active: active)
        }
    }

    /// **Nothing happens while the player is steering.** The whole feature is a convenience for
    /// somebody whose hands are on the movement keys and not on the camera.
    @Test("A camera the player is turning is left alone")
    func lookingSuspendsIt() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 1.2, pitch: 0)
        let turned = camera.yaw
        // Half a second of running, but the look was this instant: the wait has not elapsed.
        running(&camera, seconds: 0.4)
        #expect(camera.yaw == turned)
        #expect(!camera.isRecentring)
    }

    @Test("It starts only after the pause, and then comes home")
    func waitsThenRecentres() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 1.0, pitch: 0)
        running(&camera, seconds: tuning.recentreWait - 0.1)
        #expect(camera.yaw == 1.0, "it moved before the wait was up")
        running(&camera, seconds: tuning.recentreTurnTime + 0.2)
        #expect(abs(camera.yaw) < 0.1, "yaw is \(camera.yaw), should be near the character's 0")
    }

    /// **The gate that stops an involuntary circle**, and the reason a strafe is excluded rather than
    /// the feature being on whenever you move.
    @Test("It does not run while the player is not going forwards")
    func inactiveDoesNothing() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 1.0, pitch: 0)
        running(&camera, seconds: 3, active: false)
        #expect(camera.yaw == 1.0)
        #expect(!camera.isRecentring)
    }

    /// **The short way round.** Without it a camera nearly behind you swings the long way home,
    /// which is a full rotation of the world under a player who pressed nothing.
    @Test("It turns the short way, even across the wrap")
    func takesTheShortWay() {
        var camera = OrbitCamera()
        // The character faces just past half a turn; the camera sits just short of it.
        camera.orbit(byYaw: 3.0, pitch: 0)
        let target: Float = -3.0   // 0.28 rad away the short way, 6.0 the long way
        var previous = camera.yaw
        var travelled: Float = 0
        for _ in 0..<Int(2.0 * 60) {
            camera.recentre(behind: target, deltaTime: 1.0 / 60, active: true)
            travelled += abs(camera.yaw - previous)
            previous = camera.yaw
        }
        #expect(travelled < 1.0, "it travelled \(travelled) rad; the short way is about 0.28")
    }

    /// **Three times, not one** — the zoom trails the turn so the picture settles rather than
    /// sliding as one block.
    @Test("The zoom comes home more slowly than the turn")
    func zoomTrailsTheTurn() {
        #expect(tuning.recentreZoomTime > tuning.recentreTurnTime)

        var camera = OrbitCamera()
        camera.orbit(byYaw: 1.0, pitch: 0)
        camera.zoom(by: 6)
        let yawAway = abs(camera.yaw), zoomAway = abs(camera.distance - camera.tuning.restingDistance)
        running(&camera, seconds: tuning.recentreWait + tuning.recentreTurnTime * 0.5)
        let yawLeft = abs(camera.yaw) / yawAway
        let zoomLeft = abs(camera.distance - camera.tuning.restingDistance) / zoomAway
        #expect(zoomLeft > yawLeft, "the zoom should still have further to go than the turn")
    }

    @Test("The zoom eases back to the resting distance")
    func zoomReturns() {
        var camera = OrbitCamera()
        camera.zoom(by: 8)
        #expect(camera.distance > camera.tuning.restingDistance)
        running(&camera, seconds: tuning.recentreWait + tuning.recentreZoomTime + 0.5)
        #expect(abs(camera.distance - camera.tuning.restingDistance) < 0.3,
                "distance is \(camera.distance)")
    }

    /// **A camera that moves itself has not been looked at.** Otherwise the eased zoom resets the
    /// pause every frame and the yaw never gets to move at all.
    @Test("Recentring the zoom does not count as the player looking")
    func selfMovementIsNotLooking() {
        var camera = OrbitCamera()
        camera.zoom(by: 6)
        camera.orbit(byYaw: 1.0, pitch: 0)
        running(&camera, seconds: tuning.recentreWait + tuning.recentreTurnTime + 0.3)
        #expect(abs(camera.yaw) < 0.1, "the yaw never came home: \(camera.yaw)")
    }

    @Test("The pitch eases back to its resting angle")
    func pitchReturns() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 0, pitch: 0.9)
        running(&camera, seconds: tuning.recentreWait + tuning.recentreTurnTime + 0.3)
        #expect(abs(camera.pitch - camera.tuning.restingPitch) < 0.05)
    }

    /// **The pitch and the field of view are one decision.** At a 45° field of view 12° puts the
    /// horizon three quarters of the way down, and the camera reads as staring at the ground; 7° puts
    /// it at 66%. At 65°, 12° was right. So this asserts where the horizon falls, not either number —
    /// a change to one that forgets the other fails here.
    @Test("The resting pitch leaves the horizon about a third down the frame")
    func restingPitchFramesTheHorizon() {
        let camera = OrbitCamera()
        let fov = Float.degrees(fromRadians: camera.fieldOfView)
        let pitch = Float.degrees(fromRadians: camera.tuning.restingPitch)
        let horizonFromTop = (pitch + fov / 2) / fov
        #expect(horizonFromTop > 0.6 && horizonFromTop < 0.75,
                "horizon sits \(horizonFromTop * 100)% down the frame")
    }

    /// **A camera that begins life believing it was just touched** would sit still for the first
    /// half second of the game.
    @Test("A fresh camera is ready to recentre at once")
    func freshCameraIsReady() {
        var camera = OrbitCamera()
        camera.recentre(behind: 0, deltaTime: 1.0 / 60, active: true)
        #expect(camera.isRecentring)
    }

    /// Frame-rate independence, the property the rest of this camera already holds.
    @Test("The same second of easing is the same easing at any frame rate")
    func easingIsTimeKeyed() {
        func after(steps: Int) -> Float {
            var camera = OrbitCamera()
            camera.orbit(byYaw: 1.0, pitch: 0)
            let total = tuning.recentreWait + 0.6
            for _ in 0..<steps { camera.recentre(behind: 0, deltaTime: total / Float(steps), active: true) }
            return camera.yaw
        }
        #expect(abs(after(steps: 66) - after(steps: 132)) < 0.02)
    }
}
