//
//  MeshNormalsTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import ModelIO
import Testing
import simd
@testable import WindageEngine

/// A mesh whose blend shapes Model I/O reads arrives without its normals; both loaders make them from its shape.
@MainActor
struct MeshNormalsTests {

    private var fixture: URL { Bundle.module.url(forResource: "shaped-rig", withExtension: "usda")! }

    /// What a smooth normal is at the fixture's pyramid: straight up at the apex, out and up at each base corner.
    private static func expected(at position: SIMD3<Float>) -> SIMD3<Float> {
        if position.y > 0.5 { return SIMD3(0, 1, 0) }
        // Each corner is in two side faces; their normals are (±2, 1, 0) and (0, 1, ±2) over √5, at equal angles.
        return normalize(SIMD3(2 * sign(position.x), 2, 2 * sign(position.z)))
    }

    private static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { dot(normalize(a), b) > 0.999 }

    @Test("Model I/O drops the normals of a mesh whose blend shapes are bound")
    func modelIODropsThem() throws {
        // The reason this exists: if a later Model I/O keeps them, the file's own normals are read, and this says so.
        let asset = MDLAsset(url: fixture, vertexDescriptor: nil, bufferAllocator: MDLMeshBufferDataAllocator())
        let mesh = try #require(asset.childObjects(of: MDLMesh.self).first as? MDLMesh)
        let names = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute] ?? []).filter { $0.format != .invalid }.map(\.name)
        #expect(names.contains(MDLVertexAttributePosition))
        #expect(!names.contains(MDLVertexAttributeNormal))
    }

    @Test("A skinned part read without normals gets them from its shape")
    func skinned() throws {
        let g = try SkinnedGeometry.read(url: fixture, vertexDescriptor: SkinnedModelTests.gameLayout(),
                                         semantics: SkinnedModelTests.semantics, skeletonJointCount: 1)
        #expect(g.vertexCount == 5)
        for (position, normal) in zip(g.restPositions, g.restNormals) {
            #expect(Self.near(normal, Self.expected(at: position)), "\(position): \(normal)")
        }
        // In the game's layout too — normals at byte 8 of buffer 1 — which is what is drawn.
        let layout = try #require(g.layouts[1])
        for vertex in 0..<g.vertexCount {
            let normal = layout.bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: vertex * layout.stride + 8, as: (Float, Float, Float).self)
            }
            #expect(Self.near(SIMD3(normal.0, normal.1, normal.2), Self.expected(at: g.restPositions[vertex])))
        }
    }

    @Test("A mesh loaded whole without normals gets them from its shape")
    func loaded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let meshes = try MeshLoader.load(url: fixture, device: device, vertexDescriptor: SkinnedModelTests.gameLayout(),
                                         semantics: SkinnedModelTests.semantics)
        let mesh = try #require(meshes.first?.mesh)
        let positions = mesh.vertexBuffers[0], attributes = mesh.vertexBuffers[1]
        #expect(mesh.vertexCount == 5)
        for vertex in 0..<mesh.vertexCount {
            let p = positions.buffer.contents().advanced(by: positions.offset + vertex * 12).loadUnaligned(as: (Float, Float, Float).self)
            let n = attributes.buffer.contents().advanced(by: attributes.offset + vertex * 20 + 8).loadUnaligned(as: (Float, Float, Float).self)
            #expect(Self.near(SIMD3(n.0, n.1, n.2), Self.expected(at: SIMD3(p.0, p.1, p.2))))
        }
    }

    @Test("Vertices at one position share a normal; each triangle counts by its angle there")
    func smoothing() {
        // A fold: two triangles meeting along x at a right angle, the edge's vertices split as at a texture seam. The
        // edge is shared, so both its copies lean halfway — (0, 1, −1)/√2 — and each far corner keeps its own face's.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1),     // a floor, facing up
            SIMD3(1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1, 0),      // a wall, facing −z, over the floor
        ]
        let normals = MeshNormals.smooth(positions: positions, triangles: [0, 1, 2, 3, 4, 5])
        let halfway = normalize(SIMD3<Float>(0, 1, -1))
        for vertex in [0, 1, 3, 4] { #expect(Self.near(normals[vertex], halfway), "\(vertex): \(normals[vertex])") }
        #expect(Self.near(normals[2], SIMD3(0, 1, 0)))
        #expect(Self.near(normals[5], SIMD3(0, 0, -1)))

        // A corner where one face is cut into two thin triangles and the other is whole still leans halfway: the two
        // halves' angles add up to the whole one's.
        let cut: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, -1), SIMD3(0, 0, -1), SIMD3(0, 1, 0)]
        let corner = MeshNormals.smooth(positions: cut, triangles: [0, 1, 2, 0, 2, 3, 1, 0, 4])[0]
        #expect(Self.near(corner, halfway), "\(corner)")

        // Nothing to go on: up.
        #expect(MeshNormals.smooth(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)], triangles: [0, 1, 2])
                == Array(repeating: SIMD3(0, 1, 0), count: 3))
    }
}
