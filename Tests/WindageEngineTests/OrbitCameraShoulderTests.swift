//
//  OrbitCameraShoulderTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Over the shoulder: the aim point beside the character, the character off centre, and a wall at the shoulder.
@Suite("Orbit camera over the shoulder")
struct OrbitCameraShoulderTests {

    private func camera(offset: Float, yaw: Float = 0) -> OrbitCamera {
        var camera = OrbitCamera()
        camera.focus = SIMD3(0, 0, 0)
        camera.yaw = yaw
        camera.shoulderOffset = offset
        return camera
    }

    /// Where a point lands across the screen, −1 at the left edge, 1 at the right.
    private func screenX(of point: SIMD3<Float>, from camera: OrbitCamera) -> Float {
        let clip = camera.projectionMatrix(aspect: 16 / 9) * camera.viewMatrix * SIMD4(point, 1)
        return clip.x / clip.w
    }

    @Test("No offset is the centred camera: the aim point is over the character")
    func noOffsetChangesNothing() {
        let centred = camera(offset: 0)
        #expect(centred.aimPoint == centred.shoulder)
        #expect(abs(screenX(of: centred.shoulder, from: centred)) < 1e-4)
    }

    @Test("Offset to the right, the character sits left of centre")
    func theCharacterSitsLeft() {
        let over = camera(offset: 0.6)
        #expect(simd_distance(over.aimPoint, over.shoulder + SIMD3(0.6, 0, 0)) < 1e-5)
        let x = screenX(of: over.shoulder, from: over)
        #expect(x < -0.05 && x > -0.5, "character at \(x) across the screen")
    }

    @Test("The shoulder turns with the camera: looking along −X, its right is −Z")
    func theOffsetTurnsWithTheCamera() {
        let over = camera(offset: 0.6, yaw: .pi / 2)
        #expect(simd_distance(over.aimPoint, over.shoulder + SIMD3(0, 0, -0.6)) < 1e-5)
        // And the character holds its place on screen as the camera swings.
        let x = screenX(of: over.shoulder, from: over), atZero = screenX(of: SIMD3(0, 1.7, 0), from: camera(offset: 0.6))
        #expect(abs(x - atZero) < 1e-4)
    }

    @Test("A wall at the right shoulder takes the offset in at once, and lets it out gently")
    func aWallAtTheShoulder() {
        var over = camera(offset: 0.6)
        // A wall whose face is 0.5 m to the right of the shoulder: with the probe's 0.4, 0.1 m of offset is left.
        let wall = CharacterController.Surroundings.Solid(bounds: BoundingBox(minimum: SIMD3(0.5, 0, -5),
                                                                              maximum: SIMD3(1.5, 4, 5)))
        over.keepClear(of: CharacterController.Surroundings(solids: [wall]), deltaTime: 1 / 120)
        #expect(abs(over.workingShoulderOffset - 0.1) < 1e-3)
        // Clear of it, the offset eases back rather than leaping.
        over.keepClear(of: CharacterController.Surroundings(), deltaTime: 1 / 120)
        #expect(over.workingShoulderOffset > 0.1 && over.workingShoulderOffset < 0.2)
        for _ in 0..<1_200 { over.keepClear(of: CharacterController.Surroundings(), deltaTime: 1 / 120) }
        #expect(over.workingShoulderOffset == 0.6)
    }

    @Test("Drawn between steps, the offset is blended")
    func interpolationBlendsTheOffset() {
        let start = camera(offset: 0), end = camera(offset: 0.6)
        let half = OrbitCamera.interpolated(from: start, to: end, alpha: 0.5)
        #expect(abs(half.workingShoulderOffset - 0.3) < 1e-5)
    }
}
