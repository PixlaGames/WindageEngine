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

    /// **The cell walk must give every triangle's answer.** It asks only the cells a ray crosses and stops past the
    /// nearest hit, so a cell skipped wrongly or a stop made early shows as a hit missed or a farther one returned. A
    /// thousand rays through a cluttered room — boxes of every size, slanted panels across many cells, some rays
    /// starting outside the grid, some straight up or down or along one axis, every sign of direction — against every
    /// triangle.
    @Test("The cells a ray crosses give the same first hit as every triangle")
    func rayWalkMatchesEveryTriangle() {
        var seed: UInt64 = 0x5EED
        func random(_ range: ClosedRange<Float>) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Float(seed >> 40) / Float(1 << 24) * (range.upperBound - range.lowerBound)
        }
        var triangles: [SIMD3<Float>] = []
        for _ in 0..<60 {
            triangles += CollisionMesh.box(centre: SIMD3(random(-20...20), random(0...6), random(-20...20)),
                                           halfExtents: SIMD3(random(0.05...4), random(0.05...3), random(0.05...4)))
        }
        for _ in 0..<40 {
            let a = SIMD3(random(-20...20), random(0...8), random(-20...20))
            triangles += [a, a + SIMD3(random(-6...6), random(-3...3), random(-6...6)),
                          a + SIMD3(random(-6...6), random(-3...3), random(-6...6))]
        }
        let mesh = CollisionMesh(triangles: triangles)

        func everyTriangle(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ limit: Float) -> Float? {
            var best: Float?
            for t in 0..<(triangles.count / 3) {
                let a = triangles[t * 3], b = triangles[t * 3 + 1], c = triangles[t * 3 + 2]
                guard simd_length(simd_cross(b - a, c - a)) > 1e-8 else { continue }
                let e1 = b - a, e2 = c - a
                let h = simd_cross(direction, e2)
                let det = simd_dot(e1, h)
                guard abs(det) > 1e-8 else { continue }
                let s = origin - a
                let u = simd_dot(s, h) / det
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(s, e1)
                let v = simd_dot(direction, q) / det
                guard v >= 0, u + v <= 1 else { continue }
                let distance = simd_dot(e2, q) / det
                if distance > 0, distance < (best ?? limit) { best = distance }
            }
            return best
        }

        var hits = 0
        for ray in 0..<1000 {
            let origin = SIMD3(random(-30...30), random(-2...10), random(-30...30))
            var direction: SIMD3<Float>
            switch ray % 10 {
            case 0: direction = SIMD3(0, random(-1...1) < 0 ? -1 : 1, 0)   // straight up or down
            case 1: direction = SIMD3(random(-1...1), 0, 0)                // along x only
            case 2: direction = SIMD3(0, 0, random(-1...1))                // along z only
            default: direction = SIMD3(random(-1...1), random(-1...1), random(-1...1))
            }
            guard simd_length(direction) > 1e-3 else { continue }
            direction = simd_normalize(direction)
            let limit = random(0.5...60)
            let walked = mesh.firstHit(from: origin, direction: direction, limit: limit)
            let expected = everyTriangle(origin, direction, limit)
            if expected != nil { hits += 1 }
            #expect((walked == nil) == (expected == nil),
                    "ray \(ray): walked \(String(describing: walked)), every triangle \(String(describing: expected))")
            if let walked, let expected { #expect(abs(walked - expected) < 1e-4, "ray \(ray): \(walked) against \(expected)") }
        }
        #expect(hits > 200, "the rays should hit something often enough to test the walk; \(hits) did")
    }
}
