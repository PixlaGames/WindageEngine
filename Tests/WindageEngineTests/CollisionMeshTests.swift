import Testing
import simd
@testable import WindageEngine

@Suite("Collision mesh")
struct CollisionMeshTests {
    private let stepHeight: Float = 0.45

    /// A knee-high rock (0.4 m), a boulder (1.5 m), and a deck 0.3 m up with a 1 m rail along one side.
    private let world = CollisionMesh(triangles:
        CollisionMesh.box(centre: SIMD3(0, 0.2, 0), halfExtents: SIMD3(0.5, 0.2, 0.5))
        + CollisionMesh.box(centre: SIMD3(5, 0.75, 0), halfExtents: SIMD3(0.5, 0.75, 0.5))
        + CollisionMesh.box(centre: SIMD3(0, 0.25, 10), halfExtents: SIMD3(1.5, 0.05, 5))
        + CollisionMesh.box(centre: SIMD3(1.45, 0.8, 10), halfExtents: SIMD3(0.05, 0.5, 5)))

    @Test("A rock lower than a step is something to stand on, not a wall")
    func lowRockIsAFloor() {
        #expect(world.floor(x: 0, z: 0, below: stepHeight) == 0.4)
        let walked = world.pushOut(SIMD3(0.3, 0, 0), radius: 0.35, height: 1.8, stepHeight: stepHeight)
        #expect(walked == SIMD3(0.3, 0, 0), "pushed to \(walked)")
    }

    @Test("A boulder is a wall, and too high to step onto")
    func boulderBlocks() {
        // Its underside is at its base, which is no higher than the ground it sits on; its top is out of reach.
        #expect((world.floor(x: 5, z: 0, below: stepHeight) ?? 0) <= 0.01)
        let pushed = world.pushOut(SIMD3(4.3, 0, 0), radius: 0.35, height: 1.8, stepHeight: stepHeight)
        #expect(abs(pushed.x - (4.5 - 0.35)) < 1e-3, "pushed to \(pushed)")
    }

    @Test("A deck is a floor from the bank, and its rail stops a body walking off the side")
    func bridge() {
        #expect(world.floor(x: 0, z: 8, below: 0 + stepHeight) == 0.3)
        let atRail = world.pushOut(SIMD3(1.3, 0.3, 9), radius: 0.35, height: 1.8, stepHeight: stepHeight)
        #expect(atRail.x < 1.4 - 0.34, "at \(atRail)")
    }

    @Test("Walking under a deck, it is not the floor — it is the ceiling")
    func underTheDeck() {
        let tall = CollisionMesh(triangles: CollisionMesh.box(centre: SIMD3(0, 3, 0), halfExtents: SIMD3(2, 0.1, 2)))
        #expect(tall.floor(x: 0, z: 0, below: stepHeight) == nil)
        #expect(tall.pushOut(SIMD3(0, 0, 0), radius: 0.35, height: 1.8, stepHeight: stepHeight) == SIMD3(0, 0, 0))
        let roof = tall.ceiling(x: 0, z: 0, above: 1.8, below: 5)
        #expect(roof.map { abs($0 - 2.9) < 1e-4 } == true, "ceiling at \(String(describing: roof))")
        #expect(tall.ceiling(x: 0, z: 0, above: 1.8, below: 2.5) == nil, "out of the head's reach")
    }

    @Test("A rail is not a floor; a slab's edge is")
    func standingNeedsFooting() {
        let rail = CollisionMesh(triangles: CollisionMesh.box(centre: SIMD3(0, 0.35, 0), halfExtents: SIMD3(3, 0.05, 0.06)))
        #expect(rail.floor(x: 0, z: 0, below: stepHeight) != nil)
        #expect(rail.standingFloor(x: 0, z: 0, below: stepHeight) == nil)
        let slab = CollisionMesh(triangles: CollisionMesh.box(centre: SIMD3(0, 0.2, -3), halfExtents: SIMD3(2, 0.2, 2)))
        #expect(slab.standingFloor(x: 0, z: -1.1, below: 0.4 + stepHeight) == 0.4)
    }

    @Test("A ray stops at the first face it meets")
    func rayHits() throws {
        let hit = try #require(world.firstHit(from: SIMD3(2, 0.75, 0), direction: SIMD3(1, 0, 0), limit: 10))
        #expect(abs(hit - 2.5) < 1e-3)
        #expect(world.firstHit(from: SIMD3(2, 0.75, 0), direction: SIMD3(-1, 0, 0), limit: 1) == nil)
    }
}
