import Testing
import simd
@testable import WindageEngine

@Suite("Navigation grid")
struct NavigationGridTests {

    private let dryGround: (SIMD2<Float>) -> (height: Float, isStandable: Bool) = { _ in (0, true) }

    /// A 16 m wall across x = −8…8 at z = 0, 2 m high.
    private let longWall = CollisionMesh.box(centre: SIMD3(0, 1, 0), halfExtents: SIMD3(8, 1, 0.2))

    /// **A deck 2 m up, reached only by a ramp**: the deck x −3…3, z −13…−7, its sides sheer; the ramp 2 m wide, rising
    /// from the ground at z = −1 to the deck's edge at z = −7 (18°).
    private var deckAndRamp: [SIMD3<Float>] {
        let deck = CollisionMesh.box(centre: SIMD3(0, 1, -10), halfExtents: SIMD3(3, 1, 3))
        let a = SIMD3<Float>(-1, 0, -1), b = SIMD3<Float>(1, 0, -1), c = SIMD3<Float>(1, 2, -7), d = SIMD3<Float>(-1, 2, -7)
        return deck + [a, b, c, a, c, d]
    }

    /// Whether a walk through `points`, from `start`, crosses the long wall's line inside its length.
    private func crossesWall(_ points: [SIMD3<Float>], from start: SIMD3<Float>) -> Bool {
        var previous = start
        for p in points {
            if (previous.z > 0) != (p.z > 0) {
                let t = previous.z / (previous.z - p.z)
                let x = previous.x + (p.x - previous.x) * t
                if abs(x) < 8.2 { return true }
            }
            previous = p
        }
        return false
    }

    private func length(_ points: [SIMD3<Float>], from start: SIMD3<Float>) -> Float {
        zip([start] + points, points).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    @Test("Round a long wall: the way goes past its end, never through it, and ends at the goal")
    func roundAWall() throws {
        let grid = NavigationGrid(mesh: CollisionMesh(triangles: longWall), ground: dryGround, around: .zero, reach: 16)
        let start = SIMD3<Float>(0, 0, 4), goal = SIMD3<Float>(0, 0, -4)
        let path = try #require(grid.path(from: start, to: goal))
        #expect(!path.isEmpty)
        #expect(!crossesWall(path, from: start), "\(path)")
        #expect(path.contains { abs($0.x) > 8 }, "round an end: \(path)")
        #expect(simd_distance(try #require(path.last), goal) < 0.4)
        #expect(length(path, from: start) > 16)
        #expect(path.count < 8, "corners, not cells: \(path.count) points")
    }

    @Test("No wall, no detour: a straight line is one point")
    func straight() throws {
        let grid = NavigationGrid(mesh: nil, ground: dryGround, around: .zero, reach: 16)
        let path = try #require(grid.path(from: SIMD3(0, 0, 6), to: SIMD3(3, 0, -6)))
        #expect(path.count == 1)
    }

    @Test("Under the wall's height and beside it, nobody stands; a wall between two places never joins them")
    func places() throws {
        let grid = NavigationGrid(mesh: CollisionMesh(triangles: longWall), ground: dryGround, around: .zero, reach: 16)
        // The column at the wall's middle: its top is 2 m up and 0.4 m wide — wide enough to stand on, a body's height
        // over the ground, so it is a place; the ground under it is not.
        let onWall = try #require(grid.place(near: SIMD3(0.2, 2, 0.1)))
        #expect(abs(grid.position(of: onWall).y - 2) < 0.01)
        #expect(grid.place(near: SIMD3(0.2, 0, 0.1), within: 0.1) == nil)
        // Every join from the near side lands on the near side or on top, never on the far side's ground.
        for k in 0..<grid.placeCount {
            let p = grid.position(of: k)
            guard abs(p.x) < 7, p.y < 0.5, p.z > 0 else { continue }
            for way in 0..<8 {
                if let n = grid.neighbour(of: k, way: way) {
                    let q = grid.position(of: n)
                    #expect(!(q.z < 0 && q.y < 0.5), "\(p) joined to \(q) through the wall")
                }
            }
        }
    }

    @Test("Up a ramp: from behind the deck, the way goes round to the ramp and climbs it — never up a sheer side")
    func upARamp() throws {
        let grid = NavigationGrid(mesh: CollisionMesh(triangles: deckAndRamp), ground: dryGround, around: .zero, reach: 20)
        let start = SIMD3<Float>(0, 0, -18), goal = SIMD3<Float>(0, 2, -10)
        let path = try #require(grid.path(from: start, to: goal))
        let end = try #require(path.last)
        #expect(abs(end.y - 2) < 0.05 && simd_distance(end, goal) < 0.5, "on the deck: \(end)")
        // The first point up on the deck's height is reached from the ramp's side.
        let up = try #require(path.firstIndex { $0.y > 1.9 })
        let before = up == 0 ? start : path[up - 1]
        #expect(before.z > -7.6 && abs(before.x) < 1.2, "climbed from the ramp: \(path)")
        #expect(path.contains { $0.z > -7 }, "went round to the ramp: \(path)")
    }

    @Test("Without the ramp the deck cannot be reached: the way ends on the ground beside it, as near as it gets")
    func noRamp() throws {
        let deck = CollisionMesh.box(centre: SIMD3(0, 1, -10), halfExtents: SIMD3(3, 1, 3))
        let grid = NavigationGrid(mesh: CollisionMesh(triangles: deck), ground: dryGround, around: .zero, reach: 20)
        let path = try #require(grid.path(from: SIMD3(0, 0, -2), to: SIMD3(0, 2, -10)))
        let end = try #require(path.last)
        #expect(end.y < 0.1, "still on the ground: \(end)")
        #expect(end.z < -6, "came up to the deck's side: \(end)")
    }

    @Test("Down off a deck: a body walks off an edge it could never climb")
    func dropping() throws {
        let deck = CollisionMesh.box(centre: SIMD3(0, 0.9, -10), halfExtents: SIMD3(3, 0.9, 3))
        let grid = NavigationGrid(mesh: CollisionMesh(triangles: deck), ground: dryGround, around: .zero, reach: 20)
        let path = try #require(grid.path(from: SIMD3(0, 1.8, -10), to: SIMD3(0, 0, 0)))
        #expect(simd_distance(try #require(path.last), SIMD3(0, 0, 0)) < 0.4)
        let back = try #require(grid.path(from: SIMD3(0, 0, 0), to: SIMD3(0, 1.8, -10)))
        #expect((back.last?.y ?? 0) < 0.1, "1.8 m is no step up")
    }

    @Test("Round deep water, not through it")
    func water() throws {
        // A channel x −2…2 too deep to stand in, but for a ford at z 12…14.
        let ground: (SIMD2<Float>) -> (height: Float, isStandable: Bool) = { p in
            (0, !(abs(p.x) < 2 && !(p.y > 12 && p.y < 14)))
        }
        let grid = NavigationGrid(mesh: nil, ground: ground, around: .zero, reach: 16)
        let path = try #require(grid.path(from: SIMD3(-6, 0, 0), to: SIMD3(6, 0, 0)))
        #expect(path.contains { $0.z > 11 }, "by the ford: \(path)")
    }
}
