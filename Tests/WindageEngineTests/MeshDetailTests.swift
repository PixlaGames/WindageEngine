//
//  MeshDetailTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import ModelIO
import Testing
import simd
@testable import WindageEngine

/// A sphere of `rings` × `sides` quads, radius 1. `faceted` gives every triangle its own three vertices, as a
/// low-poly pack's hard edges do — the case a careful simplifier cannot touch.
private func sphere(rings: Int, sides: Int, faceted: Bool) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
    var points: [SIMD3<Float>] = []
    for ring in 0...rings {
        let polar = Float(ring) / Float(rings) * .pi
        for side in 0...sides {
            let around = Float(side) / Float(sides) * 2 * .pi
            points.append(SIMD3(sin(polar) * cos(around), cos(polar), sin(polar) * sin(around)))
        }
    }
    var indices: [UInt32] = []
    for ring in 0..<rings {
        for side in 0..<sides {
            let a = UInt32(ring * (sides + 1) + side), b = a + 1
            let c = a + UInt32(sides + 1), d = c + 1
            indices += [a, b, c, b, d, c]    // counter-clockwise seen from outside, as USD winds
        }
    }
    guard faceted else { return (points, indices) }
    return (indices.map { points[Int($0)] }, Array(0..<UInt32(indices.count)))
}

private func reductions(_ mesh: (positions: [SIMD3<Float>], indices: [UInt32])) -> [MeshDetail.Reduction] {
    // `SIMD3<Float>` is 16 bytes, its fourth lane padding: the stride is the type's, not three floats'.
    mesh.positions.withUnsafeBytes { bytes in
        MeshDetail.reductions(indices: mesh.indices, positions: bytes.baseAddress!, vertexCount: mesh.positions.count,
                        stride: MemoryLayout<SIMD3<Float>>.stride)
    }
}

@Test func eachLevelHasFewerTrianglesAndStraysFurther() {
    let mesh = sphere(rings: 48, sides: 64, faceted: false)
    let made = reductions(mesh)
    #expect(made.count >= 3, "\(made.count) reductions")
    var triangles = mesh.indices.count
    var error: Float = 0
    for reduction in made {
        #expect(reduction.indices.count < triangles)
        #expect(reduction.indices.count % 3 == 0)
        #expect(reduction.error >= error)
        #expect(reduction.indices.allSatisfy { Int($0) < mesh.positions.count }, "indices into the same vertices")
        triangles = reduction.indices.count
        error = reduction.error
    }
    // A unit sphere halved a few times is still round to within a few centimetres.
    #expect(made[0].error < 0.05, "first reduction strays \(made[0].error) m")
}

@Test func aFacetedMeshStillSimplifies() {
    let mesh = sphere(rings: 24, sides: 32, faceted: true)
    let made = reductions(mesh)
    #expect(made.count >= 2, "permissive collapses cross hard edges")
    #expect((made.last?.indices.count ?? .max) < mesh.indices.count / 4)
}

@Test func aSmallMeshIsLeftAlone() {
    let box = sphere(rings: 2, sides: 3, faceted: false)
    #expect(reductions(box).isEmpty)
}

@Test func farCopiesGetCoarserLevels() {
    let errors: [Float] = [0.01, 0.04, 0.2]
    let pixelsPerRadian: Float = 1000 / (40 * .pi / 180)    // a 1000-pixel-high view, 40°
    func at(_ distance: Float, scale: Float = 1) -> Int {
        MeshDetail.coarsestTier(errors: errors, distance: distance, scale: scale, pixelsPerRadian: pixelsPerRadian)
    }
    #expect(at(5) == 0, "close up, the full mesh")
    #expect(at(30) == 1)
    #expect(at(700) == 3, "far away, the coarsest")
    #expect(at(30, scale: 3) == 0, "a tree three times the size strays three times as far")
    #expect(at(0) == 0, "inside its box, the full mesh")
    #expect((1...800).map { at(Float($0)) } == (1...800).map { at(Float($0)) }.sorted(), "never finer further away")
}

@Test func aLevelsNormalsComeFromItsOwnFaces() {
    // Vertices as the renderer lays them out: position, normal, uv — 32 bytes. Faceted, each normal its face's.
    let mesh = sphere(rings: 24, sides: 32, faceted: true)
    var vertices = [Float]()
    for t in Swift.stride(from: 0, to: mesh.positions.count, by: 3) {
        let a = mesh.positions[t], b = mesh.positions[t + 1], c = mesh.positions[t + 2]
        let n = simd_normalize(simd_cross(b - a, c - a))
        for p in [a, b, c] { vertices += [p.x, p.y, p.z, n.x, n.y, n.z, 0, 0] }
    }
    let made = vertices.withUnsafeBytes { bytes in
        let reduced = MeshDetail.reductions(indices: mesh.indices, positions: bytes.baseAddress!,
                                     vertexCount: mesh.positions.count, stride: 32)
        return MeshDetail.tiers([reduced], full: [mesh.indices], vertices: bytes.baseAddress!, stride: 32,
                                   positionOffset: 0, normalOffset: 12)
    }
    #expect(made.count >= 2)
    var previous = vertices.count * 4
    for tier in made {
        #expect(tier.vertices.count < previous, "each tier is smaller than the one before")
        previous = tier.vertices.count
        let floats = tier.vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let count = floats.count / 8
        #expect(tier.submeshes[0].allSatisfy { Int($0) < count })
        // On a sphere round the origin, outward is the position's own direction. A fold the simplifier leaves
        // standing across the surface faces sideways, which is honest; facing into the sphere is the bug.
        let inward = (0..<count).filter { v in
            let p = SIMD3(floats[v * 8], floats[v * 8 + 1], floats[v * 8 + 2])
            let n = SIMD3(floats[v * 8 + 3], floats[v * 8 + 4], floats[v * 8 + 5])
            return simd_dot(simd_normalize(p), n) < -0.1
        }
        #expect(inward.isEmpty, "\(inward.count) of \(count) normals point away from the surface")
    }
}

/// The whole path a game takes: a file, ``MeshLoader``, then tiers read from the loaded mesh's own buffers.
@Test func tiersComeFromALoadedMesh() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    // A smooth sphere as OBJ, written here so the fixture cannot drift from what the test expects.
    let mesh = sphere(rings: 24, sides: 32, faceted: false)
    var obj = mesh.positions.map { "v \($0.x) \($0.y) \($0.z)\nvn \($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")
    for t in Swift.stride(from: 0, to: mesh.indices.count, by: 3) {
        let (a, b, c) = (mesh.indices[t] + 1, mesh.indices[t + 1] + 1, mesh.indices[t + 2] + 1)
        obj += "\nf \(a)//\(a) \(b)//\(b) \(c)//\(c)"
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "mesh-detail-\(UUID().uuidString).obj")
    try obj.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let layout = MTLVertexDescriptor()
    layout.attributes[0].format = .float3; layout.attributes[0].offset = 0; layout.attributes[0].bufferIndex = 0
    layout.attributes[1].format = .float3; layout.attributes[1].offset = 12; layout.attributes[1].bufferIndex = 0
    layout.layouts[0].stride = 24
    let loaded = try MeshLoader.load(url: url, device: device, vertexDescriptor: layout,
                                     semantics: [0: MDLVertexAttributePosition, 1: MDLVertexAttributeNormal])
    let tiers = MeshDetail.tiers(for: try #require(loaded.first), vertexDescriptor: layout,
                                 positionAttribute: 0, normalAttribute: 1)
    #expect(tiers.count >= 3, "\(tiers.count) tiers")
    #expect(tiers.map(\.error) == tiers.map(\.error).sorted(), "coarser tiers stray further")
    let floats = try #require(tiers.last).vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let away = Swift.stride(from: 0, to: floats.count, by: 6).filter { v in
        simd_dot(simd_normalize(SIMD3(floats[v], floats[v + 1], floats[v + 2])),
                 SIMD3(floats[v + 3], floats[v + 4], floats[v + 5])) < -0.1
    }
    #expect(away.isEmpty, "\(away.count) normals point into the sphere")
}

/// **The position need not be first.** Tiers used to read it from the start of buffer 0, so a layout with
/// the normal first simplified the normals as if they were the shape. The same sphere, laid out both ways,
/// must give the same tiers.
@Test func thePositionIsReadWhereTheLayoutPutsIt() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let mesh = sphere(rings: 24, sides: 32, faceted: false)
    var obj = mesh.positions.map { "v \($0.x) \($0.y) \($0.z)\nvn \($0.x) \($0.y) \($0.z)" }.joined(separator: "\n")
    for t in Swift.stride(from: 0, to: mesh.indices.count, by: 3) {
        let (a, b, c) = (mesh.indices[t] + 1, mesh.indices[t + 1] + 1, mesh.indices[t + 2] + 1)
        obj += "\nf \(a)//\(a) \(b)//\(b) \(c)//\(c)"
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "mesh-detail-\(UUID().uuidString).obj")
    try obj.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    func tiers(positionFirst: Bool) throws -> [MeshDetail.Tier] {
        let (position, normal) = positionFirst ? (0, 1) : (1, 0)
        let layout = MTLVertexDescriptor()
        layout.attributes[position].format = .float3; layout.attributes[position].offset = positionFirst ? 0 : 12
        layout.attributes[normal].format = .float3; layout.attributes[normal].offset = positionFirst ? 12 : 0
        layout.layouts[0].stride = 24
        let loaded = try MeshLoader.load(url: url, device: device, vertexDescriptor: layout,
                                         semantics: [position: MDLVertexAttributePosition,
                                                     normal: MDLVertexAttributeNormal])
        return MeshDetail.tiers(for: try #require(loaded.first), vertexDescriptor: layout,
                                positionAttribute: position, normalAttribute: normal)
    }
    let first = try tiers(positionFirst: true), second = try tiers(positionFirst: false)
    #expect(first.count >= 3)
    #expect(first.map(\.error) == second.map(\.error))
    #expect(first.map(\.submeshes) == second.map(\.submeshes))
}

@Test func optionsChangeHowManyTiersAreMade() {
    let mesh = sphere(rings: 24, sides: 32, faceted: false)
    let few = mesh.positions.withUnsafeBytes { bytes in
        MeshDetail.reductions(indices: mesh.indices, positions: bytes.baseAddress!, vertexCount: mesh.positions.count,
                              stride: MemoryLayout<SIMD3<Float>>.stride, options: MeshDetail.Options(maximumTiers: 2))
    }
    #expect(few.count == 2)
}

/// **A file that is not there says so**, rather than "loaded but contains no meshes" — Model I/O opens a
/// missing file as an empty asset, and the two used to be one error.
@Test func aMissingMeshFileIsNotFound() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let layout = MTLVertexDescriptor()
    layout.attributes[0].format = .float3; layout.attributes[0].offset = 0; layout.attributes[0].bufferIndex = 0
    layout.layouts[0].stride = 12
    let url = FileManager.default.temporaryDirectory.appending(path: "no-such-mesh-\(UUID().uuidString).usda")
    #expect {
        _ = try MeshLoader.load(url: url, device: device, vertexDescriptor: layout,
                                semantics: [0: MDLVertexAttributePosition])
    } throws: { error in
        guard case MeshLoaderError.assetNotFound = error else { return false }
        return true
    }
}
