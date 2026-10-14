//
//  ClusteredLights.swift
//  WindageEngine
//

import simd

/// The view frustum cut into a grid of cells, so a fragment can ask which lights reach *it* rather
/// than inheriting a list chosen for the whole mesh it belongs to.
///
/// ### Why per-draw selection was not enough
///
/// `LightSet` picks a few lights per object, which is correct and cheap and **only as good as the
/// draws are small**. The sample proved the failure: its ground is one eight-hundred-meter quad, so a
/// single draw got four lights for an entire level and a spot five meters up lost to lamps standing
/// closer to the plane. No budget and no ordering rule fixes that — the object is simply the wrong
/// unit to choose lights for.
///
/// A cluster is the right unit. It is a small box of the world, so the lights that reach it are few
/// by construction, and a fragment belongs to exactly one.
///
/// ### The slices are exponential, and that is not an optimization
///
/// Cut the depth range evenly and the near slices are microscopic while the far ones are hundreds of
/// meters deep — because a perspective frustum's cross-section grows with distance, an even cut puts
/// almost every cluster where there is almost no screen. Slicing by the logarithm of depth makes each
/// cluster roughly cubic, which is what makes the count manageable.
///
/// ### It needs a far distance, and this engine's projection does not have one
///
/// ``simd_float4x4/init(perspectiveFovY:aspectRatio:nearZ:depthRange:)`` has an **infinite** far plane on purpose — there is no
/// view distance to tune and nothing to clip at range. Clustering cannot work with that: the
/// logarithm needs a finite end. So ``lightRange`` is its own, and it is honest rather than awkward —
/// a punctual light has a finite range by definition, so there is a distance past which none of them
/// reaches, and that is exactly the number.
public nonisolated struct ClusterGrid: Sendable, Equatable {

    /// Cells across the screen.
    public let tilesX: Int
    /// Cells down the screen.
    public let tilesY: Int
    /// Cells into the distance.
    public let slices: Int

    /// Where the first slice begins. Matches the projection's near plane.
    public let nearPlane: Float

    /// How far into the scene clusters reach. **Not a view distance** — geometry beyond it still
    /// draws, it simply receives no local lights, which is correct where no local light reaches that
    /// far anyway.
    public let lightRange: Float

    public init(tilesX: Int = 16, tilesY: Int = 8, slices: Int = 24,
                nearPlane: Float = 0.1, lightRange: Float = 120) {
        self.tilesX = max(1, tilesX)
        self.tilesY = max(1, tilesY)
        self.slices = max(1, slices)
        self.nearPlane = max(1e-4, nearPlane)
        self.lightRange = max(self.nearPlane * 2, lightRange)
    }

    public var clusterCount: Int { tilesX * tilesY * slices }

    /// `slice = log(z) * sliceScale + sliceBias`, which is the form a shader wants: two constants and
    /// a logarithm rather than a loop or a divide chain. (A slice offset, not a shadow's depth bias.)
    public var sliceScale: Float { Float(slices) / log(lightRange / nearPlane) }
    /// See ``sliceScale``.
    public var sliceBias: Float { -Float(slices) * log(nearPlane) / log(lightRange / nearPlane) }

    /// Which slice a view-space depth falls in, clamped into the grid.
    ///
    /// **Clamped rather than rejected.** A fragment nearer than the near plane cannot exist, and one
    /// beyond ``lightRange`` is better served by the last slice's lights than by none — the
    /// alternative is a hard line across the world where local lighting stops.
    public func slice(forViewDepth depth: Float) -> Int {
        guard depth > nearPlane else { return 0 }
        let raw = log(depth) * sliceScale + sliceBias
        return min(max(Int(raw), 0), slices - 1)
    }

    /// The view-space depths a slice spans.
    public func depthRange(ofSlice index: Int) -> ClosedRange<Float> {
        let clamped = min(max(index, 0), slices - 1)
        let near = nearPlane * pow(lightRange / nearPlane, Float(clamped) / Float(slices))
        let far = nearPlane * pow(lightRange / nearPlane, Float(clamped + 1) / Float(slices))
        return near...far
    }

    /// Where a cluster sits in the flat array. **Slice-major**, so the cells a light touches are
    /// contiguous in x — which is the order the assignment walks them in.
    public func index(tileX: Int, tileY: Int, slice: Int) -> Int {
        (slice * tilesY + tileY) * tilesX + tileX
    }

    /// A cluster's box in **view space**, where the camera is at the origin looking down −Z.
    ///
    /// Built from the slice's near and far depths and the tile's share of the frustum at each. The
    /// union of the two rectangles, because a cluster is a frustum wedge and its bounding box has to
    /// contain the wider, far end. `fovY` is the projection's vertical field of view in radians, as
    /// ``simd_float4x4/init(perspectiveFovY:aspectRatio:nearZ:depthRange:)`` takes it.
    public func bounds(tileX: Int, tileY: Int, slice: Int,
                       fovY: Float, aspectRatio: Float) -> BoundingBox {
        let depths = depthRange(ofSlice: slice)
        let tangent = tan(fovY * 0.5)

        func rectangle(atDepth depth: Float) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
            let halfHeight = depth * tangent
            let halfWidth = halfHeight * aspectRatio
            let x0 = (Float(tileX) / Float(tilesX)) * 2 - 1
            let x1 = (Float(tileX + 1) / Float(tilesX)) * 2 - 1
            // Screen y runs downwards and view y runs up, so the tile's rows are flipped.
            let y0 = 1 - (Float(tileY + 1) / Float(tilesY)) * 2
            let y1 = 1 - (Float(tileY) / Float(tilesY)) * 2
            return (SIMD2(x0 * halfWidth, y0 * halfHeight), SIMD2(x1 * halfWidth, y1 * halfHeight))
        }

        let near = rectangle(atDepth: depths.lowerBound)
        let far = rectangle(atDepth: depths.upperBound)
        let lower = simd_min(near.min, far.min)
        let upper = simd_max(near.max, far.max)
        // View space looks down −Z, so a depth of `d` is at z = −d and the *far* end is the minimum.
        return BoundingBox(minimum: SIMD3(lower.x, lower.y, -depths.upperBound),
                           maximum: SIMD3(upper.x, upper.y, -depths.lowerBound))
    }
}

/// Which lights reach each cluster, as the two arrays a shader reads.
///
/// **Two arrays rather than a fixed list per cluster.** A fixed list means every cluster pays for the
/// worst one — three thousand cells times a budget of eight is twenty-four thousand entries, nearly
/// all empty. An offset and a count into a shared list costs the same for an empty cluster as for a
/// full one, and puts no ceiling on how many lights a single cluster may hold.
public nonisolated struct ClusteredLights: Sendable {

    public let grid: ClusterGrid

    /// Per cluster: where its lights start in ``indices``, and how many there are.
    public let ranges: [SIMD2<UInt32>]

    /// Light indices, grouped by cluster. Indexes into the array that was assigned.
    public let indices: [UInt32]

    /// The most lights any one cluster ended up with — worth watching, because it is the number that
    /// decides the worst fragment's cost.
    public let maxLightsPerCluster: Int

    /// How many light entries did not fit in `maximumIndices` and were dropped — each one a light
    /// missing from one cluster. **Zero in a frame that fits**; anything else is a cell lit short, and
    /// a reason to raise the limit or lose lights.
    public let droppedIndexCount: Int

    /// Bins lights into the clusters they reach.
    ///
    /// - Parameters:
    ///   - viewMatrix: world to view. Lights arrive in world space and are clustered in view space,
    ///     because that is where the grid is.
    ///   - fovY: the projection's vertical field of view, in radians.
    ///   - maximumIndices: the most entries ``indices`` may hold — the shader's buffer. Entries past it
    ///     are dropped, and counted in ``droppedIndexCount``.
    ///
    /// **Walks lights rather than clusters.** Testing every cluster against every light is three
    /// thousand times however many lights there are; a light instead touches the few slices its range
    /// spans, and within those only the tiles its sphere covers. A lamp lighting one corner of a room
    /// costs a handful of tests rather than a sweep of the whole grid.
    public init(lights: [PunctualLight],
                grid: ClusterGrid,
                viewMatrix: simd_float4x4,
                fovY: Float,
                aspectRatio: Float,
                maximumIndices: Int = 1 << 16) {
        self.grid = grid

        var buckets = [[UInt32]](repeating: [], count: grid.clusterCount)

        for (lightIndex, light) in lights.enumerated() {
            let viewPosition4 = viewMatrix * SIMD4(light.position, 1)
            let center = SIMD3(viewPosition4.x, viewPosition4.y, viewPosition4.z)
            let radius = light.range
            let depth = -center.z

            // Slices the sphere spans. A light behind the camera still reaches forwards if its radius
            // carries it past the near plane, which is why this clamps rather than rejects.
            guard depth + radius > grid.nearPlane else { continue }
            let firstSlice = grid.slice(forViewDepth: max(depth - radius, grid.nearPlane + 1e-4))
            let lastSlice = grid.slice(forViewDepth: max(depth + radius, grid.nearPlane + 1e-4))

            for slice in firstSlice...lastSlice {
                for tileY in 0..<grid.tilesY {
                    for tileX in 0..<grid.tilesX {
                        let box = grid.bounds(tileX: tileX, tileY: tileY, slice: slice,
                                              fovY: fovY, aspectRatio: aspectRatio)
                        // **Sphere against the cluster's box**, not the cone: a spot's cone would be
                        // sharper, and getting it wrong drops light a player can see. Same asymmetry
                        // as everywhere else — a cluster that keeps a light it did not need costs one
                        // iteration of a loop.
                        guard simd_distance_squared(box.closestPoint(to: center), center)
                                <= radius * radius else { continue }
                        buckets[grid.index(tileX: tileX, tileY: tileY, slice: slice)]
                            .append(UInt32(lightIndex))
                    }
                }
            }
        }

        var flat: [UInt32] = []
        flat.reserveCapacity(min(maximumIndices, grid.clusterCount))
        var built = [SIMD2<UInt32>](repeating: .zero, count: grid.clusterCount)
        var busiest = 0
        var dropped = 0

        for cluster in 0..<grid.clusterCount {
            let bucket = buckets[cluster]
            // **Truncated rather than allowed to overflow.** A frame that filled every cluster would
            // otherwise grow the list without bound; dropping the tail of one cluster's list is a
            // visible fault in one cell, and running out of buffer is a visible fault everywhere.
            let room = max(0, maximumIndices - flat.count)
            let kept = bucket.prefix(room)
            built[cluster] = SIMD2(UInt32(flat.count), UInt32(kept.count))
            dropped += bucket.count - kept.count
            flat.append(contentsOf: kept)
            busiest = max(busiest, kept.count)
        }

        self.ranges = built
        self.indices = flat
        self.maxLightsPerCluster = busiest
        self.droppedIndexCount = dropped
    }
}
