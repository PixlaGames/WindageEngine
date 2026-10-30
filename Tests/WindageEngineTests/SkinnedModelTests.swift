//
//  SkinnedModelTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import ModelIO
import Testing
import simd
@testable import WindageEngine

@MainActor
struct SkinnedModelTests {

    private var fixture: URL { Bundle.module.url(forResource: "two-part-rig", withExtension: "usda")! }

    /// A game's static layout: positions alone in buffer 0, texture coordinates and normals interleaved in buffer 1 —
    /// the shape a game keeps so a depth pass reads positions and nothing else.
    static func gameLayout() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3; d.attributes[0].offset = 0; d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float2; d.attributes[1].offset = 0; d.attributes[1].bufferIndex = 1
        d.attributes[2].format = .float3; d.attributes[2].offset = 8; d.attributes[2].bufferIndex = 1
        d.layouts[0].stride = 12
        d.layouts[1].stride = 20
        return d
    }

    static let semantics: [Int: String] = [0: MDLVertexAttributePosition, 1: MDLVertexAttributeTextureCoordinate,
                                           2: MDLVertexAttributeNormal]

    @Test("Every skinned part is merged into one mesh, its triangles grouped by material")
    func merged() throws {
        let g = try SkinnedGeometry.read(url: fixture, vertexDescriptor: Self.gameLayout(), semantics: Self.semantics,
                                         skeletonJointCount: 2)
        #expect(g.meshCount == 3)
        #expect(g.vertexCount == 12)
        #expect(g.layouts[0]?.stride == 12 && g.layouts[0]?.bytes.count == 12 * 12)
        #expect(g.layouts[1]?.stride == 20 && g.layouts[1]?.bytes.count == 12 * 20)
        // Body and Band share Cloth; Arm is Plate. Two parts, four triangles and two.
        #expect(g.parts.map(\.material.name).sorted() == ["Cloth", "Plate"])
        #expect(g.parts.map { $0.indices.count }.sorted() == [6, 12])
        // Every index is into the merged vertices, and each triangle stays with its own part's vertices.
        #expect(g.parts.allSatisfy { $0.indices.allSatisfy { $0 < 12 } })
        let plate = try #require(g.parts.first { $0.material.name == "Plate" })
        #expect(plate.indices.allSatisfy { g.joints[Int($0)].x == 1 && g.weights[Int($0)].x == 1 })
        // The band is half and half, as written.
        #expect(g.weights.filter { abs($0.x - 0.5) < 1e-6 && abs($0.y - 0.5) < 1e-6 }.count == 4)
        #expect(g.weights.allSatisfy { abs($0.x + $0.y + $0.z + $0.w - 1) < 1e-5 })
        #expect(g.bounds.minimum == SIMD3(-0.5, 0, 0) && g.bounds.maximum == SIMD3(0.5, 2, 0))
    }

    /// **By what a material is, not what it is called**: a character creator's parts each bring a material of their own
    /// name that is the same surface, and one draw beats a draw per part.
    @Test("Materials that differ only in name are one part")
    func sameSurfaceMerges() {
        let cloth = Material(name: "lambert178", baseColor: SIMD4(1, 0, 0, 1))
        var renamed = cloth
        renamed.name = "COLOR4"
        #expect(SkinnedGeometry.sameSurface(cloth, renamed))
        var other = cloth
        other.roughness = 0.1
        #expect(!SkinnedGeometry.sameSurface(cloth, other))
    }

    @Test("A vertex weighted to a joint the skeleton lacks is refused")
    func jointOutOfRange() throws {
        #expect(throws: SkinnedModelError.jointOutOfRange(file: "two-part-rig.usda", joint: 1, jointCount: 1)) {
            try SkinnedGeometry.read(url: fixture, vertexDescriptor: Self.gameLayout(), semantics: Self.semantics,
                                     skeletonJointCount: 1)
        }
    }

    @Test("A file with no skinned mesh says so")
    func noSkin() throws {
        let statue = try #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda"))
        #expect(throws: SkinnedModelError.noSkinnedMeshes("textured-quad.usda")) {
            try SkinnedGeometry.read(url: statue, vertexDescriptor: Self.gameLayout(), semantics: Self.semantics,
                                     skeletonJointCount: 2)
        }
    }

    /// **The GPU's skin is the CPU's skin**: the arm joint turned a quarter about X, every vertex skinned by the
    /// pass and read back, against the same sum done here — positions, normals, and the texture coordinates left
    /// where they were between them.
    @Test("The skinning pass poses every vertex as the palette says, in the game's own layout")
    func skinsOnTheGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
              let queue = device.makeMTL4CommandQueue(), let allocator = device.makeCommandAllocator(),
              let commands = device.makeCommandBuffer(), let event = device.makeSharedEvent() else { return }
        let model = try SkinnedModel(url: fixture, device: device, vertexDescriptor: Self.gameLayout(),
                                     semantics: Self.semantics)
        #expect(model.rig.clips.map(\.name).sorted() == ["Lower", "Raise"])
        #expect(model.mesh.submeshes.count == 2)
        let instance = try model.makeInstance()
        var locals = instance.pose.localTransforms
        locals[1].rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        instance.pose.set(to: locals)

        let pass = try SkinningPass(device: device)
        let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        residency.addAllocations(model.allocations + instance.allocations)
        residency.commit()
        queue.addResidencySet(residency)
        let slot = 1
        commands.beginCommandBuffer(allocator: allocator)
        pass.encode(into: commands, frameSlot: slot, instances: [instance])
        commands.endCommandBuffer()
        queue.commit([commands])
        queue.signalEvent(event, value: 1)
        #expect(event.wait(untilSignaledValue: 1, timeoutMS: 5000))

        let g = model.geometry
        let positions = try #require(instance.posedBuffer(0, frameSlot: slot)).contents()
        let generics = try #require(instance.posedBuffer(1, frameSlot: slot)).contents()
        let rest = try #require(g.layouts[1]).bytes
        let palette = instance.pose.skinningMatrices
        for v in 0..<g.vertexCount {
            var skin = simd_float4x4()
            for lane in 0..<4 { skin += palette[Int(g.joints[v][lane])] * g.weights[v][lane] }
            let expected = skin * SIMD4(g.restPositions[v], 1)
            let p = positions.advanced(by: v * 12).loadUnaligned(as: (Float, Float, Float).self)
            #expect(simd_distance(SIMD3(p.0, p.1, p.2), SIMD3(expected.x, expected.y, expected.z)) < 1e-5, "vertex \(v)")
            let n = generics.advanced(by: v * 20 + 8).loadUnaligned(as: (Float, Float, Float).self)
            let turned = simd_normalize(SIMD3((skin * SIMD4(g.restNormals[v], 0)).x, (skin * SIMD4(g.restNormals[v], 0)).y,
                                              (skin * SIMD4(g.restNormals[v], 0)).z))
            #expect(simd_distance(SIMD3(n.0, n.1, n.2), turned) < 1e-5, "normal \(v)")
            let uv = generics.advanced(by: v * 20).loadUnaligned(as: (Float, Float).self)
            let restUV = rest.withUnsafeBytes { $0.baseAddress!.advanced(by: v * 20).loadUnaligned(as: (Float, Float).self) }
            #expect(uv == restUV, "uv \(v)")
        }
        // The arm's tip, worked by hand: (0.1, 2, 0) is a metre above the joint at (0, 1, 0), and a quarter turn
        // about X carries it a metre toward +Z.
        let arm = try #require((0..<g.vertexCount).first { g.restPositions[$0] == SIMD3(0.1, 2, 0) })
        let tip = positions.advanced(by: arm * 12).loadUnaligned(as: (Float, Float, Float).self)
        #expect(simd_distance(SIMD3(tip.0, tip.1, tip.2), SIMD3(0.1, 1, 1)) < 1e-5)
        // The other slots were not touched: still at rest.
        let other = try #require(instance.posedBuffer(0, frameSlot: 0)).contents()
        let still = other.advanced(by: arm * 12).loadUnaligned(as: (Float, Float, Float).self)
        #expect(SIMD3(still.0, still.1, still.2) == SIMD3(0.1, 2, 0))
        // And where the game binds them: posed layouts from the instance, the rest from the mesh.
        #expect(instance.vertexBufferAddress(0, frameSlot: slot) == instance.posedBuffer(0, frameSlot: slot)!.gpuAddress)
    }
}
