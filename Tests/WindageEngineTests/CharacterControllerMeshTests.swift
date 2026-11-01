import Testing
import simd
@testable import WindageEngine

/// A body walking among ``CollisionMesh`` surroundings: over what is low, against what is steep, under what is
/// overhead, and down through a gap in the ground into a cave.
@Suite("Walking among meshes")
struct CharacterControllerMeshTests {
    private let step: Float = 1.0 / 120

    /// `seconds` of walking along `input`, facing −Z; the end, and the highest and lowest the feet were.
    private func walk(_ world: CharacterController.Surroundings, from start: SIMD3<Float> = .zero, seconds: Float = 3,
                      _ input: MovementInput = MovementInput(forward: 1), jump: Bool = false)
        -> (end: CharacterController, highest: Float, lowest: Float, highestHead: Float) {
        var body = CharacterController(feet: start)
        var highest = -Float.greatestFiniteMagnitude, lowest = Float.greatestFiniteMagnitude, head = highest
        for _ in 0..<Int((seconds / step).rounded()) {
            body.step(yaw: 0, input: input, isJumpHeld: jump, deltaTime: step, in: world)
            highest = max(highest, body.feet.y)
            lowest = min(lowest, body.feet.y)
            head = max(head, body.feet.y + body.tuning.bodyHeight(for: body.tuning.eyeHeight))
        }
        return (body, highest, lowest, head)
    }

    private func world(_ triangles: [SIMD3<Float>],
                       ground: @escaping @Sendable (Float, Float) -> Float = { _, _ in 0 }) -> CharacterController.Surroundings {
        CharacterController.Surroundings(groundHeight: ground, meshes: CollisionMesh(triangles: triangles))
    }

    @Test("Up onto a knee-high rock and down off the far side")
    func overALowRock() {
        let (end, highest, _, _) = walk(world(CollisionMesh.box(centre: SIMD3(0, 0.2, -3), halfExtents: SIMD3(2, 0.2, 1))))
        #expect(end.feet.z < -6, "stopped at \(end.feet)")
        #expect(abs(highest - 0.4) < 0.01, "stood no higher than the rock: \(highest)")
        #expect(end.feet.y < 0.01 && end.isGrounded)
    }

    @Test("Up a staircase whose treads do not quite meet: a 3 cm crack is bridged, never fallen through")
    func upStairsWithCracks() {
        // Five treads 0.34 m deep and 0.18 m up, each stopping 3 cm short of the next, rising toward −Z; then a deck.
        var treads: [SIMD3<Float>] = []
        for i in 0..<5 {
            let z = -1 - Float(i) * 0.34
            treads += CollisionMesh.box(centre: SIMD3(0, Float(i + 1) * 0.18 - 0.03, z - 0.155),
                                        halfExtents: SIMD3(1, 0.03, 0.155))
        }
        treads += CollisionMesh.box(centre: SIMD3(0, 0.87, -5.23), halfExtents: SIMD3(2, 0.03, 2.5))
        let (end, _, _, _) = walk(world(treads), seconds: 1)
        #expect(abs(end.feet.y - 0.9) < 0.02 && end.feet.z < -4, "up on the deck: \(end.feet)")
        // Standing over a crack, the floor is the treads either side of it; past an edge there is none.
        let mesh = CollisionMesh(triangles: treads)
        #expect(mesh.floor(x: 0, z: -1.325, below: 1) == nil, "the crack itself")
        #expect(mesh.standingFloor(x: 0, z: -1.325, below: 1).map { abs($0 - 0.36) < 1e-3 } == true)
        #expect(mesh.standingFloor(x: 1.05, z: -1.15, below: 1) == nil, "past the side of a tread")
    }

    @Test("A boulder stops a body walking into it")
    func stoppedByABoulder() {
        let (end, highest, _, _) = walk(world(CollisionMesh.box(centre: SIMD3(0, 0.75, -3), halfExtents: SIMD3(2, 0.75, 1))))
        #expect(end.feet.z > -2, "walked into it: \(end.feet)")
        #expect(highest < 0.01)
    }

    @Test("A fence rail within a step is leant on, not stood on")
    func railIsNotAFloor() {
        let rail = CollisionMesh.box(centre: SIMD3(0, 0.35, -3), halfExtents: SIMD3(3, 0.05, 0.06))
            + CollisionMesh.box(centre: SIMD3(0, 0.75, -3), halfExtents: SIMD3(3, 0.05, 0.06))
        let (end, highest, _, _) = walk(world(rail))
        #expect(highest < 0.01, "stood on the rail: \(highest)")
        #expect(end.feet.z > -3, "walked through the fence: \(end.feet)")
        #expect(end.isGrounded)
    }

    @Test("A head stops at a roof overhead")
    func roofStopsAJump() {
        let roof = CollisionMesh.box(centre: SIMD3(0, 2.3, 0), halfExtents: SIMD3(3, 0.1, 3))
        let (_, _, _, head) = walk(world(roof), seconds: 1.5, MovementInput(), jump: true)
        #expect(head <= 2.2 + 0.01, "the head reached \(head)")
    }

    /// **A cave down through a gap in the ground**: the ground answers far below inside the gap, a ramp falls 3 m
    /// over 6 m to a flat floor, walls stand either side, and a roof closes over the flat part.
    @Test("Down a ramp through a gap in the ground, into a cave, and not through its walls")
    func intoACave() {
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) -> [SIMD3<Float>] { [a, b, c, a, c, d] }
        let cave = quad(SIMD3(-2, 0, -1), SIMD3(2, 0, -1), SIMD3(2, -3, -7), SIMD3(-2, -3, -7))      // the ramp
            + quad(SIMD3(-2, -3, -7), SIMD3(2, -3, -7), SIMD3(2, -3, -14), SIMD3(-2, -3, -14))         // the floor
            + quad(SIMD3(-2, -4, -1), SIMD3(-2, 1, -1), SIMD3(-2, 1, -14), SIMD3(-2, -4, -14))         // left wall
            + quad(SIMD3(2, -4, -1), SIMD3(2, 1, -1), SIMD3(2, 1, -14), SIMD3(2, -4, -14))             // right wall
            + quad(SIMD3(-2, -0.4, -7), SIMD3(2, -0.4, -7), SIMD3(2, -0.4, -14), SIMD3(-2, -0.4, -14)) // the roof
            + quad(SIMD3(-2, -4, -14), SIMD3(2, -4, -14), SIMD3(2, 1, -14), SIMD3(-2, 1, -14))         // the far end
        // The gap is only over the ramp: past it, the cave runs on under the ground.
        let gap: @Sendable (Float, Float) -> Float = { x, z in abs(x) < 2 && z < -1 && z > -7 ? -200 : 0 }
        let (end, _, lowest, _) = walk(world(cave, ground: gap), seconds: 3)
        #expect(end.feet.z < -11 && end.feet.z > -14, "stopped at \(end.feet)")
        #expect(abs(end.feet.y + 3) < 0.01 && end.isGrounded, "not on the cave's floor: \(end.feet)")
        #expect(lowest > -3.01, "fell through the floor to \(lowest)")
        // Sideways into a wall, it stops there.
        let (side, _, _, _) = walk(world(cave, ground: gap), from: SIMD3(0, -3, -10), seconds: 2, MovementInput(strafe: 1))
        #expect(side.feet.x < 2 - 0.25, "through the wall: \(side.feet)")
        #expect(abs(side.feet.y + 3) < 0.01)
    }
}
