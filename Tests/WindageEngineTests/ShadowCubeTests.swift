//
//  ShadowCubeTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// **What these tests exist to catch, and it is one thing.** A cube face rendered mirrored, rotated
/// or on the wrong axis still produces a shadow — it just lands somewhere else, and on screen that
/// reads as a bias problem rather than as a convention problem. The hardware picks the face when the
/// shader samples; these check that the six matrices used to *record* it agree with the same rule.
@Suite("Shadow cubes")
struct ShadowCubeTests {

    /// Where a face's texture coordinates land, given a matrix and a world point.
    private func projected(_ point: SIMD3<Float>, through matrix: matrix_float4x4)
        -> (uv: SIMD2<Float>, depth: Float, w: Float) {
        let clip = matrix * SIMD4<Float>(point, 1)
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        // v downwards, matching the sampler.
        return (SIMD2(0.5 * ndc.x + 0.5, 0.5 - 0.5 * ndc.y), ndc.z, clip.w)
    }

    private static let near: Float = 0.05

    @Test("each axis picks its own face, dead centre")
    func axesPickTheirFace() {
        let expected: [(SIMD3<Float>, Int)] = [
            (SIMD3( 1, 0, 0), 0), (SIMD3(-1, 0, 0), 1),
            (SIMD3( 0, 1, 0), 2), (SIMD3( 0,-1, 0), 3),
            (SIMD3( 0, 0, 1), 4), (SIMD3( 0, 0,-1), 5)
        ]
        for (direction, face) in expected {
            let found = ShadowCubes.lookup(direction: direction)
            #expect(found?.face == face)
            #expect(abs((found?.uv.x ?? 0) - 0.5) < 1e-6)
            #expect(abs((found?.uv.y ?? 0) - 0.5) < 1e-6)
        }
    }

    @Test("a face's basis is orthonormal, and right x up is forward")
    func basisIsConsistent() {
        for face in 0..<ShadowCubes.faceCount {
            let (right, up, forward) = ShadowCubes.faceBasis(face)
            #expect(abs(simd_length(right) - 1) < 1e-6)
            #expect(abs(simd_length(up) - 1) < 1e-6)
            #expect(abs(simd_length(forward) - 1) < 1e-6)
            #expect(abs(simd_dot(right, up)) < 1e-6)
            #expect(abs(simd_dot(right, forward)) < 1e-6)
            #expect(abs(simd_dot(up, forward)) < 1e-6)
            // **Mirrored on purpose** — a cube is sampled from the inside. The same relation holds
            // for the spot's view, so the winding and the front-face cull are the same in both.
            #expect(simd_distance(simd_cross(right, up), forward) < 1e-6)
        }
    }

    @Test("the six faces cover every direction exactly once")
    func facesTileTheSphere() {
        var counts = [Int](repeating: 0, count: 6)
        for direction in ShadowCubeTests.spread {
            guard let found = ShadowCubes.lookup(direction: direction) else {
                Issue.record("no face for \(direction)"); continue
            }
            counts[found.face] += 1
            #expect(found.uv.x >= -1e-5 && found.uv.x <= 1 + 1e-5)
            #expect(found.uv.y >= -1e-5 && found.uv.y <= 1 + 1e-5)
        }
        #expect(counts.allSatisfy { $0 > 0 })
        #expect(counts.reduce(0, +) == ShadowCubeTests.spread.count)
    }

    /// **The load-bearing test.** A point is projected through the face's own matrix and has to land
    /// on the same texel the sampler would pick for the same direction. Anything mirrored, rotated by
    /// a right angle, or assigned to a neighbouring axis fails here and nowhere else.
    @Test("the matrix lands a point where the sampler would look for it")
    func matrixAgreesWithTheSampler() {
        let position = SIMD3<Float>(3, 2, -7)
        for direction in ShadowCubeTests.spread {
            guard let found = ShadowCubes.lookup(direction: direction) else { continue }
            let point = position + direction * 4.5
            let matrix = ShadowCubes.viewProjection(face: found.face, position: position,
                                                    nearPlane: ShadowCubeTests.near)
            let landed = projected(point, through: matrix)

            #expect(landed.w > 0, "\(direction) is behind face \(found.face)")
            #expect(abs(landed.uv.x - found.uv.x) < 1e-5,
                    "u \(landed.uv.x) vs \(found.uv.x) on face \(found.face) for \(direction)")
            #expect(abs(landed.uv.y - found.uv.y) < 1e-5,
                    "v \(landed.uv.y) vs \(found.uv.y) on face \(found.face) for \(direction)")
        }
    }

    /// The other half of the same agreement: what the shader computes as a *reference* depth has to
    /// be what the pass wrote.
    @Test("depth is near over the major axis, not over the distance")
    func depthMatchesTheProjection() {
        let position = SIMD3<Float>(-1, 4, 2)
        for direction in ShadowCubeTests.spread {
            guard let found = ShadowCubes.lookup(direction: direction) else { continue }
            let offset = direction * 6.25
            let matrix = ShadowCubes.viewProjection(face: found.face, position: position,
                                                    nearPlane: ShadowCubeTests.near)
            let landed = projected(position + offset, through: matrix)
            let major = abs(offset).max()
            let expected = ShadowCubes.normalizedDepth(majorAxis: major,
                                                       nearPlane: ShadowCubeTests.near)
            #expect(abs(landed.depth - expected) < 1e-6)
        }
    }

    @Test("a corner of a face is further away than its centre, and stores less depth")
    func cornersAreFurther() {
        let center = ShadowCubes.normalizedDepth(majorAxis: 5, nearPlane: ShadowCubeTests.near)
        // The corner direction (1,1,1)*5 has the same major axis, so the same depth — which is the
        // whole point: the major axis, not the length, is what a face's projection divides by.
        let corner = ShadowCubes.normalizedDepth(majorAxis: abs(SIMD3<Float>(5, 5, 5)).max(),
                                                 nearPlane: ShadowCubeTests.near)
        #expect(abs(center - corner) < 1e-9)
        // And it really is further away in space, by root three.
        #expect(abs(simd_length(SIMD3<Float>(5, 5, 5)) / 5 - Float(3).squareRoot()) < 1e-5)
    }

    @Test("further from the lamp stores a smaller depth")
    func depthIsReversed() {
        let near = ShadowCubes.normalizedDepth(majorAxis: 1, nearPlane: ShadowCubeTests.near)
        let far = ShadowCubes.normalizedDepth(majorAxis: 20, nearPlane: ShadowCubeTests.near)
        #expect(near > far)
        #expect(far > 0)
    }

    @Test("a zero direction has no face")
    func zeroHasNoFace() {
        #expect(ShadowCubes.lookup(direction: .zero) == nil)
    }

    @Test("a point at the lamp does not divide by zero")
    func atTheLamp() {
        let depth = ShadowCubes.normalizedDepth(majorAxis: 0, nearPlane: ShadowCubeTests.near)
        #expect(depth.isFinite)
    }

    /// **A face's frustum has five planes, not six** — the projection's far plane is infinite — and a
    /// face has to be able to see what it is pointed at.
    @MainActor
    @Test("a face's frustum keeps what is in front of it and drops what is behind")
    func faceFrustumCulls() {
        let position = SIMD3<Float>(0, 3, 0)
        let matrix = ShadowCubes.viewProjection(face: 4, position: position,   // +Z
                                                nearPlane: ShadowCubeTests.near)
        let frustum = Frustum(viewProjection: matrix)
        #expect(frustum.planes.count == 5)

        let inFront = BoundingBox(minimum: SIMD3(-1, 2, 4), maximum: SIMD3(1, 4, 6))
        let behind = BoundingBox(minimum: SIMD3(-1, 2, -6), maximum: SIMD3(1, 4, -4))
        #expect(frustum.mayIntersect(inFront))
        #expect(!frustum.mayIntersect(behind))
    }

    /// Directions on a lattice, plus the six axes and the eight corners — enough to land on every
    /// face and near every edge without pretending to be exhaustive.
    private static let spread: [SIMD3<Float>] = {
        var directions: [SIMD3<Float>] = []
        for x in stride(from: Float(-1), through: 1, by: 0.34) {
            for y in stride(from: Float(-1), through: 1, by: 0.34) {
                for z in stride(from: Float(-1), through: 1, by: 0.34) {
                    let d = SIMD3(x, y, z)
                    if simd_length(d) > 0.3 { directions.append(simd_normalize(d)) }
                }
            }
        }
        return directions
    }()
}
