//
//  OrbitCameraTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Where the orbit camera sits, what it looks at, and the limits it keeps.
struct OrbitCameraTests {

    @Test("The camera sits behind what it aims at, and forward points away from it")
    func cameraFrames() {
        var camera = OrbitCamera()
        camera.focus = .zero
        camera.yaw = 0
        camera.pitch = 0

        #expect(camera.position.z > 0)                  // behind, on +Z
        #expect(camera.groundForward.z < 0)             // forward runs away from the camera
        #expect(abs(camera.position.y - camera.shoulderHeight) < 1e-5)

        camera.yaw = .pi / 2
        #expect(camera.position.x > 0)
        #expect(camera.groundForward.x < 0)
    }

    @Test("Pitch cannot reach vertical, where the view basis collapses")
    func pitchIsClamped() {
        var camera = OrbitCamera()
        camera.orbit(byYaw: 0, pitch: 100)
        #expect(camera.pitch <= camera.tuning.pitchLimit)
        camera.orbit(byYaw: 0, pitch: -100)
        #expect(camera.pitch >= -camera.tuning.pitchLimit)
    }

    @Test("Zoom stays inside its range")
    func zoomIsClamped() {
        var camera = OrbitCamera()
        camera.zoom(by: -500)
        #expect(camera.distance == camera.tuning.distanceRange.lowerBound)
        camera.zoom(by: 500)
        #expect(camera.distance == camera.tuning.distanceRange.upperBound)
    }

    /// **The frame-rate independence check.** A naive `focus += (target - focus) * 0.2` passes
    /// every eyeball test at the rate it was written on and follows twice as fast at 120 Hz. Both
    /// runs below cover the same second of wall-clock time, so they must land in the same place.
    @Test("Following covers the same ground regardless of frame rate")
    func followIsFrameRateIndependent() {
        let target = SIMD3<Float>(10, 0, 0)

        var slow = OrbitCamera()
        for _ in 0..<60 { slow.follow(target, deltaTime: 1.0 / 60.0) }

        var fast = OrbitCamera()
        for _ in 0..<240 { fast.follow(target, deltaTime: 1.0 / 240.0) }

        #expect(abs(slow.focus.x - fast.focus.x) < 0.01)
        #expect(slow.focus.x > 9.9)
    }

    /// Movement follows the camera, and the camera's yaw means what ``Camera``'s does — so a game switching views can
    /// hand the heading across.
    @Test("Its forward is a first-person camera's at the same yaw, flattened")
    func sharesTheFirstPersonYaw() {
        for yaw: Float in [0, 0.7, -2.5, 3.1] {
            var orbit = OrbitCamera()
            orbit.yaw = yaw
            let eye = Camera(yaw: yaw)
            #expect(simd_distance(orbit.groundForward, eye.forward) < 1e-5)
            #expect(simd_distance(orbit.groundRight, eye.right) < 1e-5)
        }
    }

    @Test("The view looks from where the camera sits straight at the aim point")
    func viewLooksAtTheAimPoint() {
        var camera = OrbitCamera()
        camera.focus = SIMD3(3, 1, -2)
        camera.orbit(byYaw: 0.9, pitch: 0.3)
        let seen = camera.viewMatrix * SIMD4(camera.aimPoint, 1)
        #expect(abs(seen.x) < 1e-4 && abs(seen.y) < 1e-4)
        // Right-handed: in front of the camera is negative view-space Z, as far away as the camera sits.
        #expect(abs(seen.z + camera.workingDistance) < 1e-4)
        let eye = camera.viewMatrix * SIMD4(camera.position, 1)
        #expect(simd_length(SIMD3(eye.x, eye.y, eye.z)) < 1e-4)
    }

    @Test("Its projection is the engine's, at its own field of view and near plane")
    func projectionIsTheEngines() {
        let camera = OrbitCamera()
        #expect(camera.projectionMatrix(aspect: 1.6)
                == simd_float4x4(perspectiveFovY: camera.fieldOfView, aspectRatio: 1.6, nearZ: camera.nearPlane))
    }

    @Test("A fresh camera sits at its resting distance, with the scenery letting it")
    func opensAtRest() {
        let camera = OrbitCamera(tuning: OrbitCamera.Tuning(distanceRange: 3...12, restingDistance: 8))
        #expect(camera.distance == 8)
        #expect(camera.workingDistance == 8)
        #expect(camera.clearance == 12)
    }
}
