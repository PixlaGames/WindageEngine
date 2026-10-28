//
//  StaticVolumes.swift
//  WindageEngine
//

import simd

/// **Many volumes that never move — a level's scenery — that a shot can be tested against without visiting them all.**
///
/// ``Volume/firstHit(segmentFrom:to:against:)`` tests every volume it is given and recomputes each one's world bounds
/// as it goes, which is right for things that move and right for a few hundred of anything. A valley of eight thousand
/// buildings and boulders is neither: a rangefinder asking every frame cost a frame on its own. So this keeps each
/// volume's world bounds **once** — they cannot go stale, because nothing here moves — and files them in a grid over the
/// ground, so a ray visits only the cells under its path and stops at the first cell whose nearest hit it has found.
///
/// **Indices are the input's**, so a game that keeps something per volume beside its list keeps it as it was. Things
/// that move stay in an array of ``Volume``s and are tested the old way; a shot asks both and takes the nearer.
public nonisolated struct StaticVolumes: Sendable {

    /// Each volume's bounds in the world, in the order given.
    public let bounds: [BoundingBox]

    /// Metres a cell of the grid spans, along x and z.
    public let cell: Float

    private let buckets: [SIMD2<Int32>: [Int32]]
    private let lowest: SIMD2<Int32>
    private let highest: SIMD2<Int32>

    /// - Parameter cell: metres a grid cell spans. About the size of the larger things in it: much smaller files a
    ///   building in many cells, much larger tests many things per cell.
    public init(_ volumes: [Volume], cell: Float = 32) {
        self.cell = cell
        let bounds = volumes.map(\.worldBounds)
        self.bounds = bounds
        var buckets: [SIMD2<Int32>: [Int32]] = [:]
        var lowest = SIMD2<Int32>(repeating: .max), highest = SIMD2<Int32>(repeating: .min)
        for (index, box) in bounds.enumerated() {
            let low = Self.key(SIMD2(box.minimum.x, box.minimum.z), cell), high = Self.key(SIMD2(box.maximum.x, box.maximum.z), cell)
            lowest = simd_min(lowest, low)
            highest = simd_max(highest, high)
            for i in low.x...high.x {
                for j in low.y...high.y { buckets[SIMD2(i, j), default: []].append(Int32(index)) }
            }
        }
        self.buckets = buckets
        self.lowest = bounds.isEmpty ? .zero : lowest
        self.highest = bounds.isEmpty ? .zero : highest
    }

    public var isEmpty: Bool { bounds.isEmpty }
    public var count: Int { bounds.count }

    static func key(_ p: SIMD2<Float>, _ cell: Float) -> SIMD2<Int32> {
        SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)))
    }

    /// The first volume a shot's step passes through, and how far along it — the same answer as
    /// ``Volume/firstHit(segmentFrom:to:against:)`` given the same volumes.
    public func firstHit(segmentFrom start: SIMD3<Float>, to end: SIMD3<Float>) -> (index: Int, distance: Float)? {
        let length = simd_distance(start, end)
        guard length > 0 else { return nil }
        return walk(origin: start, direction: (end - start) / length, maxDistance: length) { box in
            box.hitDistance(ofSegmentFrom: start, to: end)
        }
    }

    /// The nearest volume along a ray, and how far away it is — the same answer as
    /// ``Volume/firstHit(origin:direction:against:maxDistance:)``.
    public func firstHit(origin: SIMD3<Float>, direction: SIMD3<Float>,
                         maxDistance: Float = .greatestFiniteMagnitude) -> (index: Int, distance: Float)? {
        let length = simd_length(direction)
        guard length > 0 else { return nil }
        let unit = direction / length
        return walk(origin: origin, direction: unit, maxDistance: maxDistance) { box in
            box.hitDistance(ofRayFrom: origin, direction: direction, maxDistance: maxDistance)
        }
    }

    /// **The cells under the path, in order, nearest first** — a grid walk over the ground plane, by distance along
    /// the 3D direction, which is the same parameter as along its shadow on the ground. Stops at the first cell whose
    /// far edge is past the nearest hit found so far: nothing further on can be nearer.
    private func walk(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float,
                      hit: (BoundingBox) -> Float?) -> (index: Int, distance: Float)? {
        guard !bounds.isEmpty else { return nil }
        var best: (index: Int, distance: Float)?
        func test(_ key: SIMD2<Int32>) {
            guard let near = buckets[key] else { return }
            for index in near {
                if let distance = hit(bounds[Int(index)]), best == nil || distance < best!.distance {
                    best = (Int(index), distance)
                }
            }
        }
        var key = Self.key(SIMD2(origin.x, origin.z), cell)
        let flat = SIMD2(direction.x, direction.z)
        // Straight up or down: one column of cells.
        guard simd_length(flat) > 1e-6 else { test(key); return best }

        // Where along the path the next x and z cell edges are, and how far apart they come.
        let stepX: Int32 = flat.x > 0 ? 1 : -1, stepZ: Int32 = flat.y > 0 ? 1 : -1
        func edge(_ k: Int32, _ step: Int32) -> Float { Float(step > 0 ? k + 1 : k) * cell }
        var nextX = flat.x != 0 ? (edge(key.x, stepX) - origin.x) / flat.x : .infinity
        var nextZ = flat.y != 0 ? (edge(key.y, stepZ) - origin.z) / flat.y : .infinity
        let acrossX = flat.x != 0 ? cell / abs(flat.x) : .infinity
        let acrossZ = flat.y != 0 ? cell / abs(flat.y) : .infinity

        while true {
            test(key)
            let leaves = min(nextX, nextZ)
            if let best, best.distance <= leaves { return best }
            if leaves > maxDistance { return best }
            if nextX < nextZ { key.x += stepX; nextX += acrossX } else { key.y += stepZ; nextZ += acrossZ }
            // Out past everything filed, heading further out: nothing more to meet.
            if (key.x > highest.x && stepX > 0) || (key.x < lowest.x && stepX < 0)
                || (key.y > highest.y && stepZ > 0) || (key.y < lowest.y && stepZ < 0) { return best }
        }
    }
}
