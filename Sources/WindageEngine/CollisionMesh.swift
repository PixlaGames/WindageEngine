import simd

/// **Things to stand on and walk into, as triangles in the world** — a bridge's deck, a cave's floor and walls,
/// a boulder — for a ``CharacterController`` (``CharacterController/Surroundings/meshes``) and a camera.
///
/// **Why triangles and not boxes.** A box round a whole prop is the right shape for a pillar and the wrong one
/// for nearly everything else: a bridge becomes a block from the stream bed to its rails, a rock pile a wall
/// across the stream, and a cave a solid lump with no inside. The meshes are the answer: the deck is a floor,
/// the rails are walls, and a rock lower than a step is something to walk over.
///
/// Four questions, the ones a character controller and a camera ask:
/// - **What floor is under this point**, no higher than a step up from the feet? (``floor(x:z:below:)``,
///   ``standingFloor(x:z:below:)``)
/// - **What ceiling is over it**, between the head and how high a jump would reach? (``ceiling(x:z:above:below:)``)
/// - **What wall is the body inside**, and where is the nearest place it is not? (``pushOut(_:radius:height:stepHeight:passes:)``)
/// - **How far can the camera see** along a ray before something is in the way? (``firstHit(from:direction:limit:)``)
///
/// Winding is not trusted — a mirrored mesh's triangles face the other way — so a triangle is a floor or a wall
/// by how steep it is, whichever way it faces.
public nonisolated struct CollisionMesh: Sendable {

    /// The steepest a floor can be, by default: 50°.
    public static let defaultSteepestFloor: Float = 50 * .pi / 180

    /// Steeper than ``steepestFloor`` is a wall: that angle, as a normal's upward part.
    public let floorNormalY: Float

    /// The grid's cell, in metres.
    public static let cellSize: Float = 2

    /// How far out from the centre a surface has to reach, in every direction, to be stood on — see
    /// ``standingFloor(x:z:below:)``.
    public static let footing: Float = 0.15

    /// Three corners a triangle, packed `x, y, z`.
    private let corners: [Float]
    /// Per triangle: its normal, unit length and pointing up, and its lowest and highest y.
    private let normals: [SIMD3<Float>]
    private let spans: [SIMD2<Float>]

    /// **The grid, flat**: cell `(x, z)` holds `cellTriangles[cellStart[i] ..< cellStart[i + 1]]`, `i = z × columns + x`.
    /// A dictionary of arrays took twelve seconds to build for a 400 m zone's props in a Debug build; two counting
    /// passes over preallocated arrays do not.
    private let gridOrigin: SIMD2<Float>
    private let columns: Int
    private let rows: Int
    private let cellStart: [Int32]
    private let cellTriangles: [Int32]

    public var triangleCount: Int { normals.count }

    /// - Parameters:
    ///   - triangles: World-space corners, three a triangle.
    ///   - steepestFloor: radians; anything steeper is a wall.
    public init(triangles: [SIMD3<Float>], steepestFloor: Float = CollisionMesh.defaultSteepestFloor) {
        self.init(placed: [(matrix_identity_float4x4, triangles)], steepestFloor: steepestFloor)
    }

    /// **Things placed in the world**: each one's triangles in its own space, and every transform it is placed with.
    /// The corners are transformed here, in one pass, rather than gathered into one enormous array first.
    public init(placed: [(transform: float4x4, triangles: [SIMD3<Float>])],
                steepestFloor: Float = CollisionMesh.defaultSteepestFloor) {
        self.floorNormalY = cos(steepestFloor)
        let total = placed.reduce(0) { $0 + $1.triangles.count / 3 }
        var corners = [Float](); corners.reserveCapacity(total * 9)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(total)
        var spans = [SIMD2<Float>](); spans.reserveCapacity(total)
        var boxes = [SIMD4<Float>](); boxes.reserveCapacity(total)   // min x, min z, max x, max z
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for (transform, local) in placed {
            local.withUnsafeBufferPointer { points in
                for t in 0..<(points.count / 3) {
                    let a4 = transform * SIMD4(points[t * 3], 1)
                    let b4 = transform * SIMD4(points[t * 3 + 1], 1)
                    let c4 = transform * SIMD4(points[t * 3 + 2], 1)
                    let a = SIMD3(a4.x, a4.y, a4.z), b = SIMD3(b4.x, b4.y, b4.z), c = SIMD3(c4.x, c4.y, c4.z)
                    var n = simd_cross(b - a, c - a)
                    let area = simd_length(n)
                    guard area > 1e-8 else { continue }
                    n /= area
                    if n.y < 0 { n = -n }
                    corners.append(a.x); corners.append(a.y); corners.append(a.z)
                    corners.append(b.x); corners.append(b.y); corners.append(b.z)
                    corners.append(c.x); corners.append(c.y); corners.append(c.z)
                    normals.append(n)
                    spans.append(SIMD2(Swift.min(a.y, b.y, c.y), Swift.max(a.y, b.y, c.y)))
                    let box = SIMD4(Swift.min(a.x, b.x, c.x), Swift.min(a.z, b.z, c.z),
                                    Swift.max(a.x, b.x, c.x), Swift.max(a.z, b.z, c.z))
                    boxes.append(box)
                    lo = simd_min(lo, SIMD2(box.x, box.y)); hi = simd_max(hi, SIMD2(box.z, box.w))
                }
            }
        }
        if boxes.isEmpty { lo = .zero; hi = .zero }
        let cell = Self.cellSize
        let columns = Swift.max(1, Int(((hi.x - lo.x) / cell).rounded(.down)) + 1)
        let rows = Swift.max(1, Int(((hi.y - lo.y) / cell).rounded(.down)) + 1)
        func range(_ box: SIMD4<Float>) -> (Int, Int, Int, Int) {
            (Int((box.x - lo.x) / cell), Int((box.y - lo.y) / cell),
             Swift.min(columns - 1, Int((box.z - lo.x) / cell)), Swift.min(rows - 1, Int((box.w - lo.y) / cell)))
        }
        var start = [Int32](repeating: 0, count: columns * rows + 1)
        for box in boxes {
            let (x0, z0, x1, z1) = range(box)
            for z in z0...z1 { for x in x0...x1 { start[z * columns + x + 1] += 1 } }
        }
        for i in 1..<start.count { start[i] += start[i - 1] }
        var fill = start
        var members = [Int32](repeating: 0, count: Int(start[start.count - 1]))
        for (t, box) in boxes.enumerated() {
            let (x0, z0, x1, z1) = range(box)
            for z in z0...z1 {
                for x in x0...x1 {
                    let i = z * columns + x
                    members[Int(fill[i])] = Int32(t)
                    fill[i] += 1
                }
            }
        }
        self.corners = corners
        self.normals = normals
        self.spans = spans
        self.gridOrigin = lo
        self.columns = columns
        self.rows = rows
        self.cellStart = start
        self.cellTriangles = members
    }

    private func corner(_ t: Int32, _ k: Int) -> SIMD3<Float> {
        let i = Int(t) * 9 + k * 3
        return SIMD3(corners[i], corners[i + 1], corners[i + 2])
    }

    /// Every triangle in the cells a flat circle touches. **A triangle spanning cells comes back more than once**;
    /// every question asked of them — highest floor, nearest hit, push out — gives the same answer for a repeat.
    private func nearby(x: Float, z: Float, radius: Float, _ body: (Int32) -> Void) {
        let cell = Self.cellSize
        let x0 = Int(((x - radius - gridOrigin.x) / cell).rounded(.down)), x1 = Int(((x + radius - gridOrigin.x) / cell).rounded(.down))
        let z0 = Int(((z - radius - gridOrigin.y) / cell).rounded(.down)), z1 = Int(((z + radius - gridOrigin.y) / cell).rounded(.down))
        guard x1 >= 0, z1 >= 0, x0 < columns, z0 < rows else { return }
        for cz in Swift.max(0, z0)...Swift.min(rows - 1, z1) {
            for cx in Swift.max(0, x0)...Swift.min(columns - 1, x1) {
                let i = cz * columns + cx
                for k in Int(cellStart[i])..<Int(cellStart[i + 1]) { body(cellTriangles[k]) }
            }
        }
    }

    /// **The highest floor under a point that is no higher than `limit`** — the deck of a bridge, the top of a
    /// low rock — or nil if there is none. Only surfaces gentle enough to stand on count.
    public func floor(x: Float, z: Float, below limit: Float) -> Float? {
        var best: Float?
        nearby(x: x, z: z, radius: 0) { t in
            let n = normals[Int(t)]
            guard n.y >= floorNormalY, spans[Int(t)].x <= limit else { return }
            let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
            guard Self.contains(SIMD2(x, z), SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)) else { return }
            let y = a.y - (n.x * (x - a.x) + n.z * (z - a.z)) / n.y
            if y <= limit, y > (best ?? -.greatestFiniteMagnitude) { best = y }
        }
        return best
    }

    /// **A floor under a point that is wide enough to stand on**: ``floor(x:z:below:)`` at the centre, and something
    /// a ``footing`` to one side or the other on both axes — or nil.
    ///
    /// **A fence rail at knee height is within a step**, and without this a body stepped up onto it, was pushed off
    /// by the posts, and fell — over and over, whenever it leant on a fence. A deck or a rock's top is wider than
    /// that. **Not all five samples**: requiring every one dropped a body through the edge of a mound, or the seam
    /// between two, to stand inside the rock. A rail fails it still: along its length both sides hit, across it
    /// neither does.
    public func standingFloor(x: Float, z: Float, below limit: Float) -> Float? {
        guard let centre = floor(x: x, z: z, below: limit) else { return nil }
        func hit(_ dx: Float, _ dz: Float) -> Bool { floor(x: x + dx, z: z + dz, below: limit) != nil }
        guard hit(Self.footing, 0) || hit(-Self.footing, 0), hit(0, Self.footing) || hit(0, -Self.footing) else { return nil }
        return centre
    }

    /// **The lowest surface over a point between `low` and `high`**, of any steepness — the roof of a cave, the
    /// underside of a deck — or nil. What a jump's head stops against.
    public func ceiling(x: Float, z: Float, above low: Float, below high: Float) -> Float? {
        var best: Float?
        nearby(x: x, z: z, radius: 0) { t in
            let span = spans[Int(t)]
            guard span.y >= low, span.x <= high else { return }
            let n = normals[Int(t)]
            guard n.y > 1e-4 else { return }   // a sheer wall has no height over a point
            let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
            guard Self.contains(SIMD2(x, z), SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)) else { return }
            let y = a.y - (n.x * (x - a.x) + n.z * (z - a.z)) / n.y
            if y >= low, y <= high, y < (best ?? .greatestFiniteMagnitude) { best = y }
        }
        return best
    }

    /// **Whether a gentle surface passes through the body** at a point — above a step from the feet and below the
    /// head. A mound's slope or a rock's top that starts below the feet and rises past the knee is not a wall
    /// (it is not steep) and not a floor (it is too high to step onto), and without this a body walked straight
    /// into it and stood inside.
    public func surfaceThroughBody(_ position: SIMD3<Float>, height: Float, stepHeight: Float) -> Bool {
        let low = position.y + stepHeight, high = position.y + height
        var found = false
        nearby(x: position.x, z: position.z, radius: 0) { t in
            guard !found else { return }
            let n = normals[Int(t)]
            guard n.y >= floorNormalY, spans[Int(t)].y > low, spans[Int(t)].x < high else { return }
            let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
            guard Self.contains(SIMD2(position.x, position.z), SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)) else { return }
            let y = a.y - (n.x * (position.x - a.x) + n.z * (position.z - a.z)) / n.y
            if y > low && y < high { found = true }
        }
        return found
    }

    /// **A body out of every wall it has walked into**, sliding along them.
    ///
    /// A wall is a steep triangle that reaches into the body **above a step's height** — so the side of a
    /// knee-high rock does not stop anyone, and the side of a boulder does — or a raised floor entirely above
    /// a step and below the head, a shelf the body would otherwise walk through.
    public func pushOut(_ position: SIMD3<Float>, radius: Float, height: Float, stepHeight: Float,
                        passes: Int = 2) -> SIMD3<Float> {
        var here = position
        let low = position.y + stepHeight, high = position.y + height
        for _ in 0..<passes {
            nearby(x: here.x, z: here.z, radius: radius) { t in
                let span = spans[Int(t)], n = normals[Int(t)]
                let steep = n.y < floorNormalY
                let blocks = steep ? span.y > low && span.x < high : span.x > low && span.x < high
                guard blocks else { return }
                let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
                let p = SIMD2(here.x, here.z)
                let q = Self.closest(p, SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z))
                let away = p - q
                let distance = simd_length(away)
                if distance > 1e-4 {
                    guard distance < radius else { return }
                    let moved = q + away / distance * radius
                    here.x = moved.x; here.z = moved.y
                } else if steep {
                    // Exactly on a wall's line: out along its face, to whichever side the centre already is.
                    var flat = SIMD2(n.x, n.z)
                    let length = simd_length(flat)
                    guard length > 1e-4 else { return }
                    flat /= length
                    if simd_dot(p - SIMD2(a.x, a.z), flat) < 0 { flat = -flat }
                    here.x += flat.x * radius; here.z += flat.y * radius
                }
            }
        }
        return here
    }

    /// How far along a ray the first triangle is, within `limit`, or nil.
    public func firstHit(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float) -> Float? {
        let end = origin + direction * limit
        let mid = (origin + end) / 2
        let reach = simd_length(SIMD2(end.x - origin.x, end.z - origin.z)) / 2
        var best: Float?
        nearby(x: mid.x, z: mid.z, radius: reach) { t in
            let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
            let e1 = b - a, e2 = c - a
            let h = simd_cross(direction, e2)
            let det = simd_dot(e1, h)
            guard abs(det) > 1e-8 else { return }
            let s = origin - a
            let u = simd_dot(s, h) / det
            guard u >= 0, u <= 1 else { return }
            let q = simd_cross(s, e1)
            let v = simd_dot(direction, q) / det
            guard v >= 0, u + v <= 1 else { return }
            let distance = simd_dot(e2, q) / det
            if distance > 0, distance < (best ?? limit) { best = distance }
        }
        return best
    }

    private static func contains(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        func side(_ o: SIMD2<Float>, _ d: SIMD2<Float>) -> Float { (d.x - o.x) * (p.y - o.y) - (d.y - o.y) * (p.x - o.x) }
        let s1 = side(a, b), s2 = side(b, c), s3 = side(c, a)
        return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
    }

    /// The closest point to `p` on a flat triangle, edges included.
    private static func closest(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> SIMD2<Float> {
        if contains(p, a, b, c) { return p }
        func onSegment(_ s: SIMD2<Float>, _ e: SIMD2<Float>) -> SIMD2<Float> {
            let d = e - s
            let lengthSquared = simd_length_squared(d)
            guard lengthSquared > 1e-10 else { return s }
            return s + d * min(max(simd_dot(p - s, d) / lengthSquared, 0), 1)
        }
        let candidates = [onSegment(a, b), onSegment(b, c), onSegment(c, a)]
        return candidates.min { simd_distance_squared($0, p) < simd_distance_squared($1, p) }!
    }
}

nonisolated extension CollisionMesh {
    /// A box's twelve triangles, for tests and for anything that is only a box.
    public static func box(centre: SIMD3<Float>, halfExtents h: SIMD3<Float>) -> [SIMD3<Float>] {
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { centre + h * SIMD3(x, y, z) }
        let quads: [[SIMD3<Float>]] = [
            [p(-1, -1, -1), p(1, -1, -1), p(1, 1, -1), p(-1, 1, -1)],
            [p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1)],
            [p(-1, -1, -1), p(-1, 1, -1), p(-1, 1, 1), p(-1, -1, 1)],
            [p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), p(1, -1, 1)],
            [p(-1, 1, -1), p(1, 1, -1), p(1, 1, 1), p(-1, 1, 1)],
            [p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1)],
        ]
        return quads.flatMap { [$0[0], $0[1], $0[2], $0[0], $0[2], $0[3]] }
    }
}
