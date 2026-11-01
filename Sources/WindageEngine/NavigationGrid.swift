//
//  NavigationGrid.swift
//  WindageEngine
//

import simd

/// **Where a body can walk, and the way there** (2026-10-31): standing places on a grid over the ground and the floors
/// a ``CollisionMesh`` makes — decks, stairs, ramps, a road — each joined to the eight round it when a body could walk
/// from one to the other, and a search over them that gives a path.
///
/// **A layered grid, not a mesh of polygons.** Each 0.4 m column holds as many standing places as it has floors a body
/// fits on — the ground under a stilt deck and the deck over it are two — found with the questions a
/// `CharacterController` asks the same mesh (the floor under a point, wide enough to stand on; nothing between the feet
/// and the head; no wall nearer than ``Body/clearance``). So where this says a body can stand, a controller can, and
/// nothing a polygon builder needs — voxels, contours, triangulation — is needed. Two places are joined when the rise
/// between them is a step, or a slope that rises evenly between them (a ramp, not the side of a crate), or a drop a body
/// would walk off; a diagonal only when both of its sides are joined too, so a path never cuts a corner through a wall.
///
/// **Built off the main thread, round a point** — the same reach the collision mesh was built in — since a map's worth
/// at 0.4 m is a quarter of a million columns. **Its arrays are flat** and filled by plain loops, the collision mesh's
/// way: they are what is copied when a struct holding it is.
public nonisolated struct NavigationGrid: Sendable {

    /// The body that walks it.
    public struct Body: Sendable, Equatable {
        /// No wall nearer than this to a standing place's centre. **Less than a body's radius on purpose**: a body's
        /// controller slides along a wall it brushes, and at its full radius a 0.9 m doorway is a band 0.26 m wide that
        /// the grid's centres, 0.4 m apart, fall into only half the time. At this, a wall between two neighbours is
        /// always nearer than this to one of them, so no join crosses a wall.
        public var clearance: Float = 0.25
        /// Feet to the top of the head: nothing lower over a standing place.
        public var height: Float = 1.65
        /// Climbed without a slope.
        public var stepHeight: Float = 0.45
        /// Walked off, never climbed.
        public var drop: Float = 2.2
        public init() {}
        /// The body a controller's tuning describes, standing.
        public init(_ tuning: CharacterController.Tuning, clearance: Float = 0.25, drop: Float = 2.2) {
            self.clearance = clearance
            height = tuning.bodyHeight(for: tuning.eyeHeight)
            stepHeight = tuning.stepHeight
            self.drop = drop
        }
    }

    public let body: Body
    public let cellSize: Float
    /// The corner of the grid with the least x and z, and its size in cells.
    public let origin: SIMD2<Float>
    public let columns: Int
    public let rows: Int

    /// Column `i = z × columns + x` holds standing places `columnStart[i] ..< columnStart[i + 1]`, highest first.
    private let columnStart: [Int32]
    /// Each standing place's height, and its column.
    private let heights: [Float]
    private let columnOf: [Int32]
    /// Each standing place's neighbour in each of the eight ways (``ways``), or −1: eight a place.
    private let neighbours: [Int32]

    public var placeCount: Int { heights.count }

    /// The eight ways, the four sides first: +x, −x, +z, −z, then the diagonals.
    static let ways: [(dx: Int, dz: Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
    /// For each diagonal, the two sides it needs joined.
    private static let sides: [(Int, Int)] = [(0, 2), (0, 3), (1, 2), (1, 3)]

    /// The steepest slope climbed between two places, as rise over run: a floor's steepest, 50°.
    private static let steepestRise: Float = tan(50 * Float.pi / 180)
    /// How far a slope may stray from even between two places and still be a slope.
    private static let slopeTolerance: Float = 0.15

    // MARK: Building

    /// **The standing places round `centre`**, out to `reach` either way across the ground.
    ///
    /// - Parameters:
    ///   - mesh: the solid props, or nil for none.
    ///   - ground: the ground's height at a point, and whether a body can stand there — not in deep water.
    ///   - headroom: floors higher than this over the ground are not looked for.
    public init(mesh: CollisionMesh?, ground: (SIMD2<Float>) -> (height: Float, isStandable: Bool),
                around centre: SIMD2<Float>, reach: Float, body: Body = Body(), cellSize: Float = 0.4,
                headroom: Float = 16) {
        self.body = body
        self.cellSize = cellSize
        let count = max(1, Int((2 * reach / cellSize).rounded(.up)))
        columns = count
        rows = count
        origin = centre - SIMD2(repeating: Float(count) * cellSize / 2)

        var start = [Int32](repeating: 0, count: count * count + 1)
        var heights: [Float] = []
        var columnOf: [Int32] = []
        heights.reserveCapacity(count * count)
        columnOf.reserveCapacity(count * count)
        var found: [Float] = []
        var z = 0
        while z < count {
            var x = 0
            while x < count {
                let p = origin + SIMD2(Float(x) + 0.5, Float(z) + 0.5) * cellSize
                found.removeAll(keepingCapacity: true)
                Self.standingPlaces(at: p, mesh: mesh, ground: ground(p), body: body, headroom: headroom, into: &found)
                let column = Int32(z * count + x)
                for h in found {
                    heights.append(h)
                    columnOf.append(column)
                }
                start[z * count + x + 1] = Int32(heights.count)
                x += 1
            }
            z += 1
        }
        self.columnStart = start
        self.heights = heights
        self.columnOf = columnOf
        self.neighbours = Self.join(heights: heights, columnOf: columnOf, columnStart: start, columns: count, rows: count,
                                    origin: origin, cellSize: cellSize, body: body, mesh: mesh, ground: ground)
    }

    /// The heights a body can stand at in one column, highest first.
    private static func standingPlaces(at p: SIMD2<Float>, mesh: CollisionMesh?, ground: (height: Float, isStandable: Bool),
                                       body: Body, headroom: Float, into found: inout [Float]) {
        // Every floor wide enough to stand on, highest first — and the ground — then kept where a body fits: each
        // standing place a body's height under the one over it. A floor a step under another is the same place (a body
        // stands on the higher), and one between a step and a body's height under it has no room over it.
        var candidates: [Float] = []
        if let mesh {
            var limit = ground.height + headroom
            while let floor = mesh.floor(x: p.x, z: p.y, below: limit) {
                // Under the ground is inside it.
                if floor < ground.height - 0.3 { break }
                if hasFooting(floor, at: p, in: mesh) { candidates.append(floor) }
                limit = floor - 1e-3
            }
        }
        if ground.isStandable { candidates.append(ground.height) }
        candidates.sort(by: >)
        var over: Float = .infinity
        for h in candidates where h <= over - body.height {
            over = h
            guard isClear(SIMD3(p.x, h, p.y), mesh: mesh, body: body) else { continue }
            found.append(h)
        }
    }

    /// **Wide enough to stand on** — `CollisionMesh.standingFloor`'s rule, a footing to one side or the other on both
    /// axes, but each footing at this floor's height: asked from above, a fence rail's footing would be the deck under it.
    private static func hasFooting(_ floor: Float, at p: SIMD2<Float>, in mesh: CollisionMesh) -> Bool {
        let footing = CollisionMesh.footing
        func hit(_ dx: Float, _ dz: Float) -> Bool {
            (mesh.floor(x: p.x + dx, z: p.y + dz, below: floor + 0.05) ?? -.infinity) > floor - 0.3
        }
        return (hit(footing, 0) || hit(-footing, 0)) && (hit(0, footing) || hit(0, -footing))
    }

    /// Nothing over a standing place lower than the head, and no wall nearer than the clearance.
    private static func isClear(_ feet: SIMD3<Float>, mesh: CollisionMesh?, body: Body) -> Bool {
        guard let mesh else { return true }
        if mesh.ceiling(x: feet.x, z: feet.z, above: feet.y + body.stepHeight, below: feet.y + body.height) != nil { return false }
        if mesh.surfaceThroughBody(feet, height: body.height, stepHeight: body.stepHeight) { return false }
        let out = mesh.pushOut(feet, radius: body.clearance, height: body.height, stepHeight: body.stepHeight, passes: 1)
        return simd_distance_squared(SIMD2(out.x, out.z), SIMD2(feet.x, feet.z)) < 1e-4
    }

    /// Each place's neighbour in each way: the one in that column a body could walk to, the nearest in height.
    private static func join(heights: [Float], columnOf: [Int32], columnStart: [Int32], columns: Int, rows: Int,
                             origin: SIMD2<Float>, cellSize: Float, body: Body, mesh: CollisionMesh?,
                             ground: (SIMD2<Float>) -> (height: Float, isStandable: Bool)) -> [Int32] {
        var neighbours = [Int32](repeating: -1, count: heights.count * 8)
        func centre(_ column: Int) -> SIMD2<Float> {
            origin + SIMD2(Float(column % columns) + 0.5, Float(column / columns) + 0.5) * cellSize
        }
        // The floor a body walking up a slope would be on at a point, near `h`.
        func floor(at p: SIMD2<Float>, near h: Float) -> Float? {
            let g = ground(p)
            var best: Float? = g.isStandable && g.height <= h + body.stepHeight ? g.height : nil
            if let f = mesh?.floor(x: p.x, z: p.y, below: h + body.stepHeight), f > (best ?? -.infinity) { best = f }
            return best
        }
        var place = 0
        while place < heights.count {
            let column = Int(columnOf[place])
            let cx = column % columns, cz = column / columns, h = heights[place]
            var way = 0
            while way < 8 {
                let (dx, dz) = ways[way]
                let nx = cx + dx, nz = cz + dz
                if way >= 4 {
                    // A diagonal only past two joined sides.
                    let (a, b) = sides[way - 4]
                    if neighbours[place * 8 + a] < 0 || neighbours[place * 8 + b] < 0 { way += 1; continue }
                }
                if nx >= 0, nz >= 0, nx < columns, nz < rows {
                    let other = nz * columns + nx
                    let run = cellSize * (way >= 4 ? Float(2).squareRoot() : 1)
                    var best: Int32 = -1, bestRise: Float = .infinity
                    var k = Int(columnStart[other])
                    let end = Int(columnStart[other + 1])
                    while k < end {
                        let rise = heights[k] - h
                        var joined = false
                        if rise <= body.stepHeight {
                            joined = -rise <= body.drop
                        } else if rise <= body.stepHeight + run * steepestRise {
                            // More than a step: only a slope rising evenly all the way, not the side of something.
                            let a = centre(column), b = centre(other)
                            joined = [Float(0.25), 0.5, 0.75].allSatisfy { t in
                                let expected = h + rise * t
                                guard let f = floor(at: a + (b - a) * t, near: expected) else { return false }
                                return abs(f - expected) <= slopeTolerance
                            }
                        }
                        if joined, abs(rise) < abs(bestRise) {
                            best = Int32(k)
                            bestRise = rise
                        }
                        k += 1
                    }
                    neighbours[place * 8 + way] = best
                }
                way += 1
            }
            place += 1
        }
        return neighbours
    }

    // MARK: Asking

    /// Whether a point across the ground is inside the grid.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        let local = (point - origin) / cellSize
        return local.x >= 0 && local.y >= 0 && local.x < Float(columns) && local.y < Float(rows)
    }

    /// Where a standing place is.
    public func position(of place: Int) -> SIMD3<Float> {
        let column = Int(columnOf[place])
        let p = origin + SIMD2(Float(column % columns) + 0.5, Float(column / columns) + 0.5) * cellSize
        return SIMD3(p.x, heights[place], p.y)
    }

    /// The neighbour of a place one way (``ways``), or nil.
    public func neighbour(of place: Int, way: Int) -> Int? {
        let n = neighbours[place * 8 + way]
        return n < 0 ? nil : Int(n)
    }

    /// **The standing place a body at `feet` is on** — in its column at the height nearest its feet, else the nearest
    /// within `within` across the ground and a metre and a half of height. A body against a wall has its centre nearer
    /// the wall than the clearance, so its own column often has none.
    public func place(near feet: SIMD3<Float>, within: Float = 1.2) -> Int? {
        let local = (SIMD2(feet.x, feet.z) - origin) / cellSize
        let cx = Int(local.x.rounded(.down)), cz = Int(local.y.rounded(.down))
        let ring = Int((within / cellSize).rounded(.up))
        var best: Int?, bestScore: Float = .infinity
        var z = max(cz - ring, 0)
        while z <= min(cz + ring, rows - 1) {
            var x = max(cx - ring, 0)
            while x <= min(cx + ring, columns - 1) {
                let column = z * columns + x
                var k = Int(columnStart[column])
                let end = Int(columnStart[column + 1])
                while k < end {
                    let p = position(of: k)
                    let across = simd_distance_squared(SIMD2(p.x, p.z), SIMD2(feet.x, feet.z))
                    let dy = p.y - feet.y
                    // Above the feet counts for more than below: a body is on the floor it stands on, not the one over it.
                    let up = dy > 0 ? dy * 3 : -dy
                    if across <= within * within, abs(dy) < 1.5 {
                        let score = across + up * up * 4
                        if score < bestScore { best = k; bestScore = score }
                    }
                    k += 1
                }
                x += 1
            }
            z += 1
        }
        return best
    }

    /// **A way from `start` to `goal`**: the points to walk through in turn, the first the furthest that can be walked to
    /// in a straight line, the last the goal's standing place — or, if none can be reached, the reachable place nearest
    /// it, so a body comes as close as it can. Nil if either end is off the grid; empty if the start is the end.
    ///
    /// - Parameter searchLimit: places looked at before settling for the nearest so far — a goal nobody can reach costs
    ///   no more than this.
    public func path(from start: SIMD3<Float>, to goal: SIMD3<Float>, searchLimit: Int = 12_000) -> [SIMD3<Float>]? {
        guard let from = place(near: start), let to = place(near: goal) else { return nil }
        guard from != to else { return [] }
        let places = search(from: from, to: to, limit: searchLimit)
        return smoothed(places)
    }

    /// A* over the places, from one to another; the places in order, the first `from`. The search stops at `limit`
    /// places and gives the way to the nearest it reached.
    ///
    /// **Flat buffers, a heap of its own and whole cells for distances, in plain loops** — the collision mesh's way, and
    /// for its reason: an engine runs unoptimised in a game's Debug build, where the first version, with a dictionary,
    /// a heap of tuples and distances in metres, took 5 µs a place.
    func search(from: Int, to: Int, limit: Int) -> [Int] {
        let goalColumn = Int(columnOf[to])
        let gx = goalColumn % columns, gz = goalColumn / columns
        let straight = cellSize, diagonal = cellSize * 1.4142135
        // **The octile distance** — straight then diagonal, what eight ways cost across open ground — a hair over, so of
        // two equal ways the one nearer the goal is taken first. The straight-line distance underestimates eight-way
        // moves everywhere, and the search spread over far more of the grid before reaching anything.
        let longer = straight * 1.001, shorter = (diagonal - straight) * 1.001
        let count = heights.count
        var cost = [Float](repeating: .infinity, count: count)
        var came = [Int32](repeating: -1, count: count)
        // Each place looked at pushes at most eight: the heap never holds more than this.
        let capacity = limit * 8 + 16
        var heapKey = [Float](repeating: 0, count: capacity)
        var heapPlace = [Int32](repeating: 0, count: capacity)
        var nearest = from
        cost.withUnsafeMutableBufferPointer { cost in
        came.withUnsafeMutableBufferPointer { came in
        heapKey.withUnsafeMutableBufferPointer { key in
        heapPlace.withUnsafeMutableBufferPointer { place in
        heights.withUnsafeBufferPointer { heights in
        neighbours.withUnsafeBufferPointer { neighbours in
        columnOf.withUnsafeBufferPointer { columnOf in
            func estimate(_ k: Int) -> Float {
                let c = Int(columnOf[k])
                var dx = c % columns - gx, dz = c / columns - gz
                if dx < 0 { dx = -dx }
                if dz < 0 { dz = -dz }
                return dx > dz ? Float(dx) * longer + Float(dz) * shorter : Float(dz) * longer + Float(dx) * shorter
            }
            var size = 0
            func push(_ k: Float, _ p: Int) {
                var i = size
                size += 1
                while i > 0 {
                    let parent = (i - 1) >> 1
                    if key[parent] <= k { break }
                    key[i] = key[parent]
                    place[i] = place[parent]
                    i = parent
                }
                key[i] = k
                place[i] = Int32(p)
            }
            func pop() -> (Float, Int) {
                let top = (key[0], Int(place[0]))
                size -= 1
                let k = key[size], p = place[size]
                var i = 0
                while true {
                    var child = 2 * i + 1
                    if child >= size { break }
                    if child + 1 < size && key[child + 1] < key[child] { child += 1 }
                    if key[child] >= k { break }
                    key[i] = key[child]
                    place[i] = place[child]
                    i = child
                }
                key[i] = k
                place[i] = p
                return top
            }
            var nearestEstimate = estimate(from)
            cost[from] = 0
            push(nearestEstimate, from)
            var looked = 0
            while size > 0 {
                let (f, k) = pop()
                if k == to { nearest = to; break }
                let e = estimate(k), here = cost[k]
                if f > here + e + 1e-4 { continue }  // a stale entry
                if e < nearestEstimate { nearest = k; nearestEstimate = e }
                looked += 1
                if looked > limit || size + 8 > capacity { break }
                let h = heights[k]
                var way = 0
                while way < 8 {
                    let n = Int(neighbours[k * 8 + way])
                    if n >= 0 {
                        let rise = heights[n] - h
                        // A way up costs its climb; a drop costs a little, a big one more, so a stair beats a leap.
                        var step = way >= 4 ? diagonal : straight
                        if rise > 0 {
                            step += rise * 1.5
                        } else {
                            step -= rise * 0.5
                            if -rise > body.stepHeight { step += 1.5 }
                        }
                        let through = here + step
                        if through < cost[n] {
                            cost[n] = through
                            came[n] = Int32(k)
                            push(through + estimate(n), n)
                        }
                    }
                    way += 1
                }
            }
        }
        }
        }
        }
        }
        }
        }
        var places = [nearest]
        while let last = places.last, came[last] >= 0 { places.append(Int(came[last])) }
        return places.reversed()
    }

    /// **The places a body need walk through**: from each, on to the furthest ahead that a straight line reaches over
    /// joined places — a path round a wall as its corners, not a staircase of cells.
    func smoothed(_ places: [Int]) -> [SIMD3<Float>] {
        guard places.count > 1 else { return [] }
        var points: [SIMD3<Float>] = []
        var i = 0
        while i < places.count - 1 {
            var j = min(places.count - 1, i + 48)
            while j > i + 1 && !isStraight(from: places[i], to: places[j]) { j -= 1 }
            points.append(position(of: places[j]))
            i = j
        }
        return points
    }

    /// Whether a straight line from one place reaches another through joined places, never dropping on the way — a drop
    /// is taken where the search put it.
    func isStraight(from a: Int, to b: Int) -> Bool {
        let pa = position(of: a), pb = position(of: b)
        let across = SIMD2(pb.x - pa.x, pb.z - pa.z)
        let steps = Int(simd_length(across) / (cellSize * 0.4)) + 1
        var current = a
        var column = Int(columnOf[a])
        var k = 1
        while k <= steps {
            let p = SIMD2(pa.x, pa.z) + across * (Float(k) / Float(steps))
            let local = (p - origin) / cellSize
            let cx = Int(local.x.rounded(.down)), cz = Int(local.y.rounded(.down))
            let here = cz * columns + cx
            if here != column {
                let dx = cx - column % columns, dz = cz - column / columns
                guard let way = Self.ways.firstIndex(where: { $0.dx == dx && $0.dz == dz }) else { return false }
                let next = Int(neighbours[current * 8 + way])
                guard next >= 0, heights[next] >= heights[current] - body.stepHeight else { return false }
                current = next
                column = here
            }
            k += 1
        }
        return current == b
    }
}
