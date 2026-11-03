//
//  WadingTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Walking through water, and a third-person camera kept out of it.
@Suite("Wading")
struct WadingTests {

    private let step: Float = 1.0 / 120

    /// Flat ground at 0, and water standing `depth` deep over everything with x below 50 — dry beyond it.
    private func pond(depth: Float) -> CharacterController.Surroundings {
        CharacterController.Surroundings(liquidHeight: { x, _ in x < 50 ? depth : nil })
    }

    /// How far a body gets in one second walking (or sprinting) straight on in `world`.
    private func crossed(in world: CharacterController.Surroundings, sprinting: Bool = false) -> Float {
        var body = CharacterController(feet: .zero)
        for _ in 0..<120 {
            body.step(yaw: 0, input: MovementInput(forward: 1, isSprinting: sprinting), deltaTime: step, in: world)
        }
        return simd_length(SIMD2(body.feet.x, body.feet.z))
    }

    @Test("Deeper is slower: knee-deep barely, waist-deep half, chest-deep a crawl")
    func deeperIsSlower() {
        let tuning = CharacterController.Tuning()
        let height = tuning.bodyHeight(for: tuning.eyeHeight)
        let dry = crossed(in: CharacterController.Surroundings())
        let knee = crossed(in: pond(depth: 0.28 * height)), waist = crossed(in: pond(depth: 0.55 * height))
        let chest = crossed(in: pond(depth: 0.72 * height)), drowning = crossed(in: pond(depth: 2 * height))
        #expect(abs(knee / dry - 0.85) < 0.01)
        #expect(abs(waist / dry - 0.5) < 0.01)
        #expect(abs(chest / dry - 0.2) < 0.01)
        // Never a wall: deeper still is still a crawl.
        #expect(abs(drowning / dry - 0.2) < 0.01)
        // Between two points, the line between them.
        #expect(abs(tuning.wadingFraction(atDepth: 0.415 * height) - 0.675) < 0.001)
    }

    @Test("Water no deeper than nothing costs nothing; a liquid elsewhere costs nothing")
    func dryIsFullPace() {
        let dry = crossed(in: CharacterController.Surroundings())
        #expect(crossed(in: pond(depth: 0)) == dry)
        var body = CharacterController(feet: SIMD3(60, 0, 0))
        body.step(yaw: 0, input: MovementInput(forward: 1), deltaTime: step, in: pond(depth: 1))
        #expect(body.wadingDepth == 0)
    }

    @Test("From waist-deep a sprint is a walk; shallower it is a slowed sprint")
    func noSprintWaistDeep() {
        let tuning = CharacterController.Tuning()
        let height = tuning.bodyHeight(for: tuning.eyeHeight)
        let waist = pond(depth: 0.6 * height)
        #expect(crossed(in: waist, sprinting: true) == crossed(in: waist))
        let knee = pond(depth: 0.28 * height)
        #expect(abs(crossed(in: knee, sprinting: true) / crossed(in: CharacterController.Surroundings(), sprinting: true) - 0.85) < 0.01)
    }

    @Test("The depth a body wades is the surface less its feet")
    func depthIsReported() {
        var body = CharacterController(feet: .zero)
        body.step(yaw: 0, input: MovementInput(), deltaTime: step, in: pond(depth: 1.1))
        #expect(abs(body.wadingDepth - 1.1) < 1e-5)
    }

    // MARK: The camera

    /// A camera low over water: the character waist-deep, the view tilted up, so the orbit puts the camera under.
    private func lowCamera() -> OrbitCamera {
        var camera = OrbitCamera()
        camera.focus = SIMD3(0, -1, 0)
        camera.shoulderHeight = 1.5
        camera.orbit(byYaw: 0, pitch: -0.4 - camera.pitch)
        return camera
    }

    @Test("Over water the camera rises to stay above it, looking at the same point")
    func cameraStaysAboveWater() {
        var camera = lowCamera()
        let world = CharacterController.Surroundings(groundHeight: { _, _ in -1 }, liquidHeight: { _, _ in 0 })
        #expect(camera.orbitPosition.y < 0)
        camera.keepClear(of: world, deltaTime: 1.0 / 60)
        #expect(abs(camera.position.y - camera.tuning.liquidClearance) < 1e-4)
        #expect(camera.position.x == camera.orbitPosition.x && camera.position.z == camera.orbitPosition.z)
        #expect(camera.aimPoint == lowCamera().aimPoint)
    }

    @Test("Deeper than the shoulder, what the camera looks at comes up over the surface too")
    func aimPointStaysAboveWater() {
        var camera = OrbitCamera()
        camera.focus = SIMD3(0, -1.6, 0)
        camera.shoulderHeight = 1.5
        let world = CharacterController.Surroundings(groundHeight: { _, _ in -1.6 }, liquidHeight: { _, _ in 0 })
        camera.keepClear(of: world, deltaTime: 1.0 / 60)
        #expect(abs(camera.aimLift - 0.4) < 1e-4)
        #expect(abs(camera.aimPoint.y - camera.tuning.liquidClearance) < 1e-4)
        #expect(camera.position.y >= camera.tuning.liquidClearance - 1e-4)
        // The view looks at the surface's clearance, not down into the water.
        #expect(camera.position.y >= camera.aimPoint.y - 1e-4)
    }

    @Test("Already clear of the water, or with none, the camera is not moved")
    func clearCameraIsLeft() {
        var camera = OrbitCamera()
        camera.keepClear(of: CharacterController.Surroundings(liquidHeight: { _, _ in -3 }), deltaTime: 1.0 / 60)
        #expect(camera.liquidLift == 0)
        var dry = lowCamera()
        dry.keepClear(of: CharacterController.Surroundings(groundHeight: { _, _ in -3 }), deltaTime: 1.0 / 60)
        #expect(dry.liquidLift == 0)
    }

    @Test("Out of the water the lift eases away rather than dropping the view")
    func liftEasesDown() {
        var camera = lowCamera()
        camera.keepClear(of: CharacterController.Surroundings(groundHeight: { _, _ in -3 }, liquidHeight: { _, _ in 0 }),
                         deltaTime: 1.0 / 60)
        let lifted = camera.liquidLift
        let dry = CharacterController.Surroundings(groundHeight: { _, _ in -3 })
        camera.keepClear(of: dry, deltaTime: 1.0 / 60)
        #expect(camera.liquidLift > 0 && camera.liquidLift < lifted)
        for _ in 0..<600 { camera.keepClear(of: dry, deltaTime: 1.0 / 60) }
        #expect(camera.liquidLift == 0)
    }

    @Test("Between two steps the lift is blended like the rest")
    func liftIsInterpolated() {
        let start = lowCamera()
        var end = start
        end.keepClear(of: CharacterController.Surroundings(groundHeight: { _, _ in -3 }, liquidHeight: { _, _ in 0 }),
                      deltaTime: 1.0 / 60)
        let half = OrbitCamera.interpolated(from: start, to: end, alpha: 0.5)
        #expect(abs(half.liquidLift - end.liquidLift / 2) < 1e-5)
    }
}
