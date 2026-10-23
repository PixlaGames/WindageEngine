//
//  GLTFMeshLoaderTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import MetalKit
import ModelIO
import Testing
import simd
@testable import WindageEngine

/// glTF through ``MeshLoader``: the same `LoadedMesh` a game gets from USD, and the same way up.
struct GLTFMeshLoaderTests {

    /// Position, normal and texture coordinates, interleaved — what a game's pipeline typically declares.
    private static func layout() -> MTLVertexDescriptor {
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float3; layout.attributes[0].offset = 0; layout.attributes[0].bufferIndex = 0
        layout.attributes[1].format = .float3; layout.attributes[1].offset = 12; layout.attributes[1].bufferIndex = 0
        layout.attributes[2].format = .float2; layout.attributes[2].offset = 24; layout.attributes[2].bufferIndex = 0
        layout.layouts[0].stride = 32
        return layout
    }

    private static let semantics = [0: MDLVertexAttributePosition, 1: MDLVertexAttributeNormal,
                                    2: MDLVertexAttributeTextureCoordinate]

    private func load(_ url: URL) throws -> [LoadedMesh] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try MeshLoader.load(url: url, device: device, vertexDescriptor: Self.layout(), semantics: Self.semantics)
    }

    /// Every vertex of a loaded mesh: position and texture coordinates, read back from its buffer.
    private func vertices(_ loaded: LoadedMesh) -> [(position: SIMD3<Float>, uv: SIMD2<Float>)] {
        let buffer = loaded.mesh.vertexBuffers[0]
        let floats = UnsafeRawPointer(buffer.buffer.contents() + buffer.offset)
            .bindMemory(to: Float.self, capacity: loaded.mesh.vertexCount * 8)
        return (0..<loaded.mesh.vertexCount).map { v in
            (SIMD3(floats[v * 8], floats[v * 8 + 1], floats[v * 8 + 2]), SIMD2(floats[v * 8 + 6], floats[v * 8 + 7]))
        }
    }

    @Test("A .glb loads as meshes to draw, placed and textured")
    func knight() throws {
        let url = try GLTFReaderTests.fixture("Knight.glb")
        let model = try ImportedModel.read(gltf: url)
        let loaded = try load(url)
        #expect(loaded.count == model.meshes.count)
        for (mesh, imported) in zip(loaded, model.meshes) {
            #expect(mesh.mesh.submeshes.count == imported.submeshes.count, "\(imported.name)")
            #expect(mesh.materials.count == imported.submeshes.count)
            #expect(simd_almost_equal_elements(mesh.nodeTransform, imported.transform, 1e-5), "\(imported.name)")
            guard case .url(let file) = try #require(mesh.materials.first?.textures[.baseColor]) else {
                Issue.record("\(imported.name): base color is not a file")
                continue
            }
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
        }
        // In metres and standing: the same box the reader found.
        let low = loaded.map { ($0.nodeTransform * SIMD4($0.bounds.minimum, 1)).y }.min()!
        #expect(abs(low) < 0.05)
    }

    /// **The test that matters most.** `textured-quad.usda` and a glTF quad written to mean the same thing
    /// must reach the shader with the same texture coordinates at the same corners, or every glTF texture is
    /// upside down beside the USD ones — and on most textures nobody would notice.
    @Test("A glTF texture lands the same way up as the same model's from USD")
    func sameWayUpAsUSD() throws {
        let usdURL = try #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda"))
        let usd = try #require(try load(usdURL).first)
        var b = Builder()
        b.quad()
        let gltf = try #require(try load(b.write(to: GLTFReaderTests.folder(), name: "quad")).first)

        let fromUSD = vertices(usd), fromGLTF = vertices(gltf)
        #expect(fromUSD.count == 4 && fromGLTF.count == 4)
        for vertex in fromGLTF {
            let match = try #require(fromUSD.first { simd_distance($0.position, vertex.position) < 1e-6 },
                                     "no USD corner at \(vertex.position)")
            #expect(match.uv == vertex.uv, "at \(vertex.position): USD \(match.uv), glTF \(vertex.uv)")
        }
    }

    /// The transform moves the coordinates in glTF's own space, before they are turned v-up.
    @Test("KHR_texture_transform is baked into the coordinates, and a shared vertex is copied")
    func textureTransform() throws {
        var b = Builder()
        let positions = b.accessor(Builder.quadPositions.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3")
        let uvs = b.accessor(Builder.quadUVs.flatMap { [$0.x, $0.y] }, type: "VEC2")
        let image = b.image(try Data(contentsOf: GLTFReaderTests.fixture("red-top-blue-bottom.png")), mimeType: "image/png")
        b.append("textures", ["source": image])
        b.append("materials", ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]])
        b.append("materials", ["pbrMetallicRoughness": ["baseColorTexture": [
            "index": 0, "extensions": ["KHR_texture_transform": ["offset": [0.5, 0], "scale": [0.5, 0.5]]]]]])
        // Two triangles sharing the diagonal's corners, 0 and 2, each with its own material.
        b.append("meshes", ["primitives": [
            ["attributes": ["POSITION": positions, "TEXCOORD_0": uvs], "indices": b.indices([0, 1, 2]), "material": 0],
            ["attributes": ["POSITION": positions, "TEXCOORD_0": uvs], "indices": b.indices([0, 2, 3]), "material": 1],
        ]] as [String: Any])
        b.append("nodes", ["mesh": 0])
        let loaded = try #require(try load(b.write(to: GLTFReaderTests.folder(), name: "moved")).first)

        // Each primitive brings its own four vertices; the second's are moved: u/2 + 0.5, v/2, then v-up.
        let drawn = vertices(loaded)
        #expect(drawn.count == 8)
        // Vertex 5 is the second primitive's corner 1, which none of its triangles uses: no material, so unmoved.
        for (k, vertex) in drawn.enumerated() where k != 5 {
            let uv = Builder.quadUVs[k % 4]
            let moved = k < 4 ? uv : SIMD2(uv.x * 0.5 + 0.5, uv.y * 0.5)
            #expect(vertex.uv == SIMD2(moved.x, 1 - moved.y), "vertex \(k)")
        }

        // One set of vertices, two transforms: the shared corners are copied, so each triangle keeps its own.
        let mesh = ImportedMesh(positions: Builder.quadPositions, uvs: Builder.quadUVs,
                                submeshes: [ImportedSubmesh(indices: [0, 1, 2], material: 0),
                                            ImportedSubmesh(indices: [0, 2, 3], material: 1)])
        let materials = try ImportedModel.read(gltf: b.write(to: GLTFReaderTests.folder(), name: "again")).materials
        let shared = MeshLoader.drawnVertices(mesh, materials: materials)
        #expect(shared.source == [0, 1, 2, 3, 0, 2], "corners 0 and 2 copied for the second submesh")
        #expect(shared.indices == [[0, 1, 2], [4, 5, 3]])
        #expect(shared.uvs[4] == SIMD2(0.5, 0.5), "corner 0 as the second triangle sees it")
        #expect(shared.uvs[0] == SIMD2(0, 0), "and as the first does")
    }

    /// glTF multiplies a texture by its factor. A metallic-roughness map under a metallic factor of 0 — what
    /// Blender writes for a surface with roughness painted and no metal — is not metal.
    @Test("glTF's factors stay with their textures")
    func factors() throws {
        var b = Builder()
        b.quad(material: 0)
        let image = b.image(try Data(contentsOf: GLTFReaderTests.fixture("red-top-blue-bottom.png")), mimeType: "image/png")
        b.append("textures", ["source": image])
        b.append("materials", ["name": "Tinted", "pbrMetallicRoughness": [
            "baseColorFactor": [0.5, 0.5, 0.5, 1], "baseColorTexture": ["index": 0],
            "metallicFactor": 0, "roughnessFactor": 0.75, "metallicRoughnessTexture": ["index": 0],
        ], "occlusionTexture": ["index": 0], "normalTexture": ["index": 0]] as [String: Any])
        let loaded = try #require(try load(b.write(to: GLTFReaderTests.folder(), name: "factors")).first)
        let material = try #require(loaded.materials.first)
        #expect(material.name == "Tinted")
        #expect(material.baseColor == SIMD4(0.5, 0.5, 0.5, 1))
        #expect(material.metallic == 0 && material.roughness == 0.75)
        #expect(Set(material.textures.keys) == [.baseColor, .metallic, .roughness, .ambientOcclusion, .normal])
        #expect(material.textures[.metallic] == material.textures[.roughness], "one packed map")
    }

    @Test("A glTF the reader refuses is a conversion failure that says why")
    func refusal() throws {
        var b = Builder()
        b.quad()
        b.json["extensionsRequired"] = ["EXT_made_up_geometry"]
        let url = try b.write(to: GLTFReaderTests.folder(), name: "refused")
        #expect {
            _ = try load(url)
        } throws: { error in
            guard case MeshLoaderError.conversionFailed(_, let underlying) = error else { return false }
            return underlying as? GLTFError == .unsupportedExtension(file: "refused.gltf", name: "EXT_made_up_geometry")
        }
    }

    @Test("A tool can have the model without drawing it")
    func modelWithoutDrawing() throws {
        let url = try GLTFReaderTests.fixture("Knight.glb")
        #expect(try MeshLoader.model(url: url).meshes.count == 9)
        let usd = try #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda"))
        #expect(throws: GLTFError.unreadable(file: "textured-quad.usda")) { try MeshLoader.model(url: usd) }
    }

    /// A reader of the game's own — an FBX one, say — hands its model straight in.
    @Test("A model read elsewhere loads as a file would")
    func fromModel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let image = try #require(ImportedTexture(name: "stripes",
                                                 encoded: Data(contentsOf: GLTFReaderTests.fixture("red-top-blue-bottom.png"))))
        let model = ImportedModel(
            meshes: [ImportedMesh(name: "Quad", transform: simd_float4x4(diagonal: SIMD4(2, 2, 2, 1)),
                                  positions: Builder.quadPositions, uvs: Builder.quadUVs,
                                  submeshes: [ImportedSubmesh(indices: [0, 1, 2, 0, 2, 3], material: 0)])],
            materials: [ImportedMaterial(name: "Striped", baseColorTexture: ImportedTextureReference(texture: image),
                                         metallic: 0, roughness: 0.4)])
        let loaded = try MeshLoader.load(model: model, named: "made", device: device, vertexDescriptor: Self.layout(),
                                         semantics: Self.semantics)
        let mesh = try #require(loaded.first)
        #expect(loaded.count == 1 && mesh.nodeTransform == simd_float4x4(diagonal: SIMD4(2, 2, 2, 1)))
        let material = try #require(mesh.materials.first)
        #expect(material.name == "Striped" && material.roughness == 0.4)
        guard case .url(let file) = try #require(material.textures[.baseColor]) else {
            Issue.record("base color is not a file")
            return
        }
        #expect(try Data(contentsOf: file) == image.encoded, "the image's own bytes, not re-encoded")
    }

    @Test("Normals are made when the file has none")
    func normals() throws {
        var b = Builder()
        b.quad(normals: false)
        let loaded = try #require(try load(b.write(to: GLTFReaderTests.folder(), name: "flat")).first)
        let buffer = loaded.mesh.vertexBuffers[0]
        let floats = UnsafeRawPointer(buffer.buffer.contents() + buffer.offset).bindMemory(to: Float.self, capacity: 32)
        for v in 0..<4 { #expect(SIMD3(floats[v * 8 + 3], floats[v * 8 + 4], floats[v * 8 + 5]) == SIMD3(0, 0, 1)) }
    }
}
