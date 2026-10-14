//
//  ClusteredLightsTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct ClusterGridTests {

    private let grid = ClusterGrid(tilesX: 16, tilesY: 8, slices: 24,
                                   nearPlane: 0.1, lightRange: 120)

    @Test("Every cluster has a distinct index and they fill the array")
    func indicesAreDistinctAndComplete() {
        var seen = Set<Int>()
        for slice in 0..<grid.slices {
            for y in 0..<grid.tilesY {
                for x in 0..<grid.tilesX {
                    let index = grid.index(tileX: x, tileY: y, slice: slice)
                    #expect(index >= 0 && index < grid.clusterCount)
                    #expect(seen.insert(index).inserted, "index \(index) used twice")
                }
            }
        }
        #expect(seen.count == grid.clusterCount)
    }

    /// **The slicing has to be its own inverse.** A fragment's depth picks a slice in the shader and
    /// the assignment picks the same slice on the CPU; disagree and a light is binned into a cell no
    /// fragment ever reads.
    @Test("A depth inside a slice maps back to that slice")
    func slicingRoundTrips() {
        for index in 0..<grid.slices {
            let range = grid.depthRange(ofSlice: index)
            let middle = sqrt(range.lowerBound * range.upperBound)   // geometric, matching the cut
            #expect(grid.slice(forViewDepth: middle) == index, "slice \(index) at depth \(middle)")
        }
    }

    @Test("Slices tile the range without gap or overlap")
    func slicesAreContiguous() {
        #expect(abs(grid.depthRange(ofSlice: 0).lowerBound - grid.nearPlane) < 1e-4)
        #expect(abs(grid.depthRange(ofSlice: grid.slices - 1).upperBound - grid.lightRange) < 1e-2)
        for index in 1..<grid.slices {
            let previous = grid.depthRange(ofSlice: index - 1).upperBound
            let current = grid.depthRange(ofSlice: index).lowerBound
            #expect(abs(previous - current) < 1e-4, "a gap between slices \(index - 1) and \(index)")
        }
    }

    /// **Exponential, and this is the test that says why.** Cut evenly and the near slices are
    /// microscopic while the far ones are hundreds of metres deep, because a frustum's cross-section
    /// grows with distance. Each slice being a fixed *ratio* deep is what keeps clusters roughly cubic.
    @Test("Slices grow with distance, at a constant ratio")
    func slicesAreExponential() {
        let first = grid.depthRange(ofSlice: 0)
        let last = grid.depthRange(ofSlice: grid.slices - 1)
        #expect((last.upperBound - last.lowerBound) > (first.upperBound - first.lowerBound) * 50)

        let ratio = grid.depthRange(ofSlice: 5).upperBound / grid.depthRange(ofSlice: 5).lowerBound
        for index in 0..<grid.slices {
            let range = grid.depthRange(ofSlice: index)
            #expect(abs(range.upperBound / range.lowerBound - ratio) < 1e-3)
        }
    }

    /// Beyond the range is better served by the last slice's lights than by none — the alternative is
    /// a hard line across the world where local lighting stops.
    @Test("Depths outside the range are clamped, not rejected")
    func depthsClamp() {
        #expect(grid.slice(forViewDepth: 0.001) == 0)
        #expect(grid.slice(forViewDepth: -5) == 0)
        #expect(grid.slice(forViewDepth: 100_000) == grid.slices - 1)
    }

    // MARK: - Cluster geometry

    private let fovY = Float.radians(fromDegrees: Float(70))
    private let aspect: Float = 16.0 / 9.0

    @Test("A cluster's box spans exactly its slice in depth")
    func boxDepthMatchesSlice() {
        for slice in [0, 7, 23] {
            let box = grid.bounds(tileX: 8, tileY: 4, slice: slice, fovY: fovY, aspectRatio: aspect)
            let range = grid.depthRange(ofSlice: slice)
            // View space looks down −Z, so the far end is the minimum.
            #expect(abs(-box.minimum.z - range.upperBound) < 1e-3)
            #expect(abs(-box.maximum.z - range.lowerBound) < 1e-3)
        }
    }

    /// The union of every tile has to be the whole frustum slice, or a fragment near the screen edge
    /// falls in no cluster.
    @Test("The tiles of a slice cover the frustum")
    func tilesCoverTheFrustum() {
        let slice = 10
        let depths = grid.depthRange(ofSlice: slice)
        let halfHeight = depths.upperBound * tan(fovY * 0.5)
        let halfWidth = halfHeight * aspect

        var lower = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for y in 0..<grid.tilesY {
            for x in 0..<grid.tilesX {
                let box = grid.bounds(tileX: x, tileY: y, slice: slice, fovY: fovY, aspectRatio: aspect)
                lower = simd_min(lower, SIMD2(box.minimum.x, box.minimum.y))
                upper = simd_max(upper, SIMD2(box.maximum.x, box.maximum.y))
            }
        }
        #expect(abs(lower.x + halfWidth) < 1e-2 && abs(upper.x - halfWidth) < 1e-2)
        #expect(abs(lower.y + halfHeight) < 1e-2 && abs(upper.y - halfHeight) < 1e-2)
    }

    /// A cluster is a frustum wedge, so its box has to contain the wider far end — otherwise the
    /// corners of the view are outside every cluster.
    @Test("A cluster's box contains its far face, which is the wide one")
    func boxContainsTheFarFace() {
        let box = grid.bounds(tileX: 0, tileY: 0, slice: 12, fovY: fovY, aspectRatio: aspect)
        let depths = grid.depthRange(ofSlice: 12)
        let farHalfHeight = depths.upperBound * tan(fovY * 0.5)
        #expect(box.minimum.x <= -farHalfHeight * aspect + 1e-3)
    }
}

@MainActor
struct ClusteredLightsAssignmentTests {

    private let grid = ClusterGrid(tilesX: 8, tilesY: 4, slices: 12,
                                   nearPlane: 0.1, lightRange: 60)
    private let fovY = Float.radians(fromDegrees: Float(70))
    private let aspect: Float = 16.0 / 9.0

    private func assign(_ lights: [PunctualLight],
                        view: matrix_float4x4 = matrix_identity_float4x4) -> ClusteredLights {
        ClusteredLights(lights: lights, grid: grid, viewMatrix: view,
                        fovY: fovY, aspectRatio: aspect)
    }

    private func lightsIn(_ clustered: ClusteredLights, cluster: Int) -> [UInt32] {
        let range = clustered.ranges[cluster]
        return (0..<Int(range.y)).map { clustered.indices[Int(range.x) + $0] }
    }

    @Test("No lights means every cluster is empty")
    func emptyScene() {
        let clustered = assign([])
        #expect(clustered.ranges.count == grid.clusterCount)
        #expect(clustered.indices.isEmpty)
        #expect(clustered.ranges.allSatisfy { $0.y == 0 })
        #expect(clustered.maxLightsPerCluster == 0)
        #expect(clustered.droppedIndexCount == 0)
    }

    /// **The property the whole thing exists for.** A light lands in the clusters it reaches and in
    /// no others — which is what lets a fragment shade with a handful of lights while a level holds
    /// hundreds.
    @Test("A small light reaches only the clusters around it")
    func smallLightIsLocal() {
        // Straight ahead, 10 m away, 2 m range.
        let light = PunctualLight(position: SIMD3(0, 0, -10), color: SIMD3(repeating: 10), range: 2)
        let clustered = assign([light])

        let occupied = clustered.ranges.count { $0.y > 0 }
        #expect(occupied > 0, "a light in front of the camera reached nothing")
        #expect(occupied < grid.clusterCount / 4, "a 2 m light reached a quarter of the frustum")

        // And it is in the cluster it sits in.
        let slice = grid.slice(forViewDepth: 10)
        let center = grid.index(tileX: grid.tilesX / 2, tileY: grid.tilesY / 2, slice: slice)
        #expect(lightsIn(clustered, cluster: center).contains(0))
    }

    @Test("A light behind the camera reaches nothing")
    func behindTheCameraIsSkipped() {
        let behind = PunctualLight(position: SIMD3(0, 0, 20), color: SIMD3(repeating: 10), range: 3)
        #expect(assign([behind]).indices.isEmpty)
    }

    /// A lamp just behind the eye still spills in front of it, so rejecting by centre alone would put
    /// a dark band at the bottom of the screen every time the player backs into a light.
    @Test("A light behind the camera whose radius reaches forward is kept")
    func spillFromBehindIsKept() {
        let close = PunctualLight(position: SIMD3(0, 0, 1), color: SIMD3(repeating: 10), range: 6)
        #expect(!assign([close]).indices.isEmpty)
    }

    @Test("A light far past the clustered range reaches nothing")
    func beyondRangeIsSkipped() {
        let distant = PunctualLight(position: SIMD3(0, 0, -400), color: SIMD3(repeating: 10), range: 5)
        #expect(assign([distant]).indices.isEmpty)
    }

    /// The view matrix is what puts the grid where the camera is; ignoring it clusters the world as
    /// though the player never moved.
    @Test("Lights are clustered in view space, not world space")
    func viewMatrixIsApplied() {
        let light = PunctualLight(position: SIMD3(0, 0, -10), color: SIMD3(repeating: 10), range: 2)
        #expect(!assign([light]).indices.isEmpty)

        // Walk the camera 100 m past it and the same light is behind.
        let moved = simd_float4x4(translation: SIMD3(0, 0, 100))
        #expect(assign([light], view: moved).indices.isEmpty)
    }

    @Test("Ranges point at real spans of the index list")
    func rangesAreConsistent() {
        let lights = (0..<12).map {
            PunctualLight(position: SIMD3(Float($0) - 6, 0, -8),
                          color: SIMD3(repeating: 10), range: 3)
        }
        let clustered = assign(lights)
        var total = 0
        for range in clustered.ranges {
            #expect(Int(range.x) + Int(range.y) <= clustered.indices.count)
            total += Int(range.y)
        }
        #expect(total == clustered.indices.count, "the ranges do not tile the index list")
        #expect(clustered.maxLightsPerCluster == clustered.ranges.map { Int($0.y) }.max())
    }

    /// **A fragment shader cannot loop over every lamp in a level, and this is the number that says
    /// it no longer has to.** Per-draw selection gave one draw a fixed budget for the whole scene;
    /// clustering gives each cell only what reaches it.
    @Test("Many lights in a level leave few in any one cluster")
    func manyLightsStayLocal() {
        let lights = (0..<64).map {
            PunctualLight(position: SIMD3(Float($0 % 8) * 4 - 16, 0, -Float($0 / 8) * 5 - 5),
                          color: SIMD3(repeating: 10), range: 3)
        }
        // The production grid, because localisation is a property of how finely the frustum is cut —
        // the coarse grid the other tests use to stay fast would understate it.
        let fine = ClusterGrid(tilesX: 16, tilesY: 8, slices: 24, nearPlane: 0.1, lightRange: 60)
        let clustered = ClusteredLights(lights: lights, grid: fine,
                                        viewMatrix: matrix_identity_float4x4,
                                        fovY: fovY, aspectRatio: aspect)
        let occupancies = clustered.ranges.map { Int($0.y) }.filter { $0 > 0 }
        let average = Float(occupancies.reduce(0, +)) / Float(max(occupancies.count, 1))

        // Measured: 9 at worst and 2.2 on average, out of 64. **That ratio is the whole point** — the
        // worst fragment loops nine times instead of sixty-four, and the typical one twice.
        #expect(clustered.maxLightsPerCluster <= 12, "the busiest cluster took \(clustered.maxLightsPerCluster)")
        #expect(average < 4, "the average cluster took \(average) lights")
        #expect(clustered.maxLightsPerCluster < lights.count / 4)
        #expect(!clustered.indices.isEmpty)
    }

    /// Running out of index buffer is a visible fault everywhere; dropping the tail of one cluster's
    /// list is a visible fault in one cell.
    @Test("The index list is truncated rather than allowed to overflow")
    func indicesAreBounded() {
        let lights = (0..<40).map { _ in
            PunctualLight(position: SIMD3(0, 0, -10), color: SIMD3(repeating: 10), range: 60)
        }
        let clustered = ClusteredLights(lights: lights, grid: grid, viewMatrix: matrix_identity_float4x4,
                                        fovY: fovY, aspectRatio: aspect, maximumIndices: 100)
        #expect(clustered.indices.count <= 100)
        for range in clustered.ranges {
            #expect(Int(range.x) + Int(range.y) <= clustered.indices.count)
        }
        // **And it says so**: what was dropped plus what was kept is everything that was binned.
        let unbounded = ClusteredLights(lights: lights, grid: grid, viewMatrix: matrix_identity_float4x4,
                                         fovY: fovY, aspectRatio: aspect)
        #expect(unbounded.droppedIndexCount == 0)
        #expect(clustered.droppedIndexCount > 0)
        #expect(clustered.indices.count + clustered.droppedIndexCount == unbounded.indices.count)
    }
}

/// **The layout the shader reads.** A struct that agrees on its fields and disagrees on its padding
/// is the worst kind of mismatch: it compiles, it runs, and everything after the offending field is
/// read from the wrong address.
@MainActor
struct ClusterGridLayoutTests {

    /// Mirrors the sample's `PackedClusterGrid` and the shader's `ClusterUniforms`.
    private struct Packed {
        var tilesX: UInt32 = 0
        var tilesY: UInt32 = 0
        var slices: UInt32 = 0
        var sliceScale: Float = 0
        var sliceBias: Float = 0
        var padding0: Float = 0
        var padding1: Float = 0
        var padding2: Float = 0
    }

    /// Eight four-byte fields and nothing else. **A `SIMD3<Float>` in place of the three trailing
    /// scalars makes this 48 with 16-byte alignment**, which is exactly the mistake that made the
    /// sample's local lights vanish without a word.
    @Test("The packed grid is eight scalars, four-byte aligned")
    func packedLayoutMatchesTheShader() {
        #expect(MemoryLayout<Packed>.size == 32)
        #expect(MemoryLayout<Packed>.stride == 32)
        #expect(MemoryLayout<Packed>.alignment == 4)
    }

    /// The shader recomputes the slice from these two numbers; they have to describe the same cut the
    /// assignment used.
    @Test("The shader's two constants reproduce the grid's own slicing")
    func scaleAndBiasReproduceSlices() {
        let grid = ClusterGrid(tilesX: 16, tilesY: 8, slices: 24, nearPlane: 0.1, lightRange: 120)
        for index in 0..<grid.slices {
            let range = grid.depthRange(ofSlice: index)
            let depth = sqrt(range.lowerBound * range.upperBound)
            let shaderSide = Int(min(max(log(depth) * grid.sliceScale + grid.sliceBias, 0),
                                     Float(grid.slices - 1)))
            #expect(shaderSide == index, "the shader's slice for \(depth) is not the grid's")
        }
    }
}
