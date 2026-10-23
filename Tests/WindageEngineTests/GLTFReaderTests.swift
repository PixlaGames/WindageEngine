//
//  GLTFReaderTests.swift
//  WindageEngineTests
//

import Foundation
import Testing
import simd
@testable import WindageEngine

/// glTF read into an ``ImportedModel``: against real files from three encoders, and against small files written
/// here so every number can be checked exactly.
///
/// **The fixtures.** `Knight.glb` is from KayKit's Adventurers pack (CC0, `KayKit-License.txt`): a skinned
/// character as an ordinary exporter writes one. The `gltfpack-*` and `blender-character-draco` files are one
/// studio-made test character (a person, 1.7 m or so, feet at y = 0), put through meshoptimizer's `gltfpack` —
/// quantized, then quantized and meshopt-compressed — and through Blender's Draco export. `face-etc1s.ktx2` is
/// that character's face texture through Binomial's encoder. All of them are the engine's to use.
struct GLTFReaderTests {

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: (name as NSString).deletingPathExtension,
                                       withExtension: (name as NSString).pathExtension))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "GLTFReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Triangles turned to start at their smallest index: the same triangle, the same winding, whichever corner
    /// an encoder started from.
    private func triangles(_ mesh: ImportedMesh) -> [[UInt32]] {
        let i = mesh.submeshes.flatMap(\.indices)
        return stride(from: 0, to: i.count, by: 3).map { t in
            let tri = [i[t], i[t + 1], i[t + 2]]
            let k = tri.firstIndex(of: tri.min()!)!
            return Array(tri[k...] + tri[..<k])
        }
    }

    // MARK: Real files

    @Test("A skinned character from an ordinary exporter comes in whole, in metres, standing up")
    func knight() throws {
        let model = try ImportedModel.read(gltf: Self.fixture("Knight.glb"))
        #expect(model.meshes.count == 9)
        for mesh in model.meshes {
            #expect(mesh.normals.count == mesh.positions.count, "\(mesh.name) normals")
            #expect(mesh.uvs.count == mesh.positions.count, "\(mesh.name) texture coordinates")
            #expect(mesh.submeshes.allSatisfy { $0.material == 0 }, "\(mesh.name) material")
        }
        let texture = try #require(model.materials.first?.baseColorTexture?.texture)
        #expect(texture.width > 0 && texture.height > 0 && texture.pixels.count == texture.width * texture.height * 4)
        #expect(model.textures.count == 1, "one image, shared")

        let bounds = try #require(model.bounds)
        let size = bounds.maximum - bounds.minimum
        #expect(size.y > 1 && size.y < 3, "\(size.y) m tall")
        #expect(abs(bounds.minimum.y) < 0.05, "feet at \(bounds.minimum.y)")
        #expect(size.y > size.z, "lying down: \(size)")
    }

    /// gltfpack keeps positions as 16-bit integers (KHR_mesh_quantization) and scales them back to metres on
    /// the node.
    @Test("A quantized, skinned character comes out in metres")
    func quantized() throws {
        let model = try ImportedModel.read(gltf: Self.fixture("gltfpack-quantized.glb"))
        let bounds = try #require(model.bounds)
        let size = bounds.maximum - bounds.minimum
        #expect(size.y > 1.4 && size.y < 2.2, "\(size.y) tall")
        #expect(abs(bounds.minimum.y) < 0.01)
    }

    /// glTF ignores a skinned mesh's own node: its joints place it. Here the node says 100 m to the side, and
    /// the one joint, standing 1 m up and bound there, says the vertices are where they are written.
    @Test("A skinned mesh stands where its joints say, not where its node is")
    func bindPlacement() throws {
        func file(jointAt height: Float, boundAt bound: Float) throws -> ImportedModel {
            var b = Builder()
            b.quad()
            // Column-major: a translation's numbers are the last four.
            let inverseBind = b.accessor([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -bound, 0, 1], type: "MAT4")
            b.json["nodes"] = [["mesh": 0, "skin": 0, "translation": [100, 0, 0]],
                               ["name": "Root", "translation": [0, height, 0]]] as [[String: Any]]
            b.json["skins"] = [["joints": [1], "inverseBindMatrices": inverseBind]]
            b.json["scenes"] = [["nodes": [0, 1]]]
            return try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "skinned"))
        }
        let bound = try #require(try file(jointAt: 1, boundAt: 1).meshes.first)
        #expect(bound.transform == matrix_identity_float4x4, "placed by its joint")
        // A joint standing 2 m up but bound at 1 m carries the vertices up with it, as any viewer draws them.
        let raised = try #require(try file(jointAt: 2, boundAt: 1).meshes.first)
        #expect(raised.transform.columns.3 == SIMD4(0, 1, 0, 1))
    }

    /// Lossless compression gives back exactly what the uncompressed file holds.
    @Test("Meshopt decodes to exactly the uncompressed file")
    func meshopt() throws {
        let plain = try ImportedModel.read(gltf: Self.fixture("gltfpack-quantized.glb"))
        let packed = try ImportedModel.read(gltf: Self.fixture("gltfpack-meshopt-khr.glb"))
        #expect(plain.meshes.count == packed.meshes.count && !plain.meshes.isEmpty)
        for (a, b) in zip(plain.meshes, packed.meshes) {
            #expect(a.positions == b.positions, "\(a.name) positions")
            #expect(a.normals == b.normals, "\(a.name) normals")
            #expect(a.uvs == b.uvs, "\(a.name) texture coordinates")
            #expect(a.transform == b.transform, "\(a.name) placement")
            // The triangle codec may start a triangle at another corner — the same triangle.
            #expect(triangles(a) == triangles(b), "\(a.name) triangles")
        }
        // Quantized coordinates come with a KHR_texture_transform that turns them back into 0…1.
        let face = try #require(packed.materials.first { $0.baseColorTexture != nil }?.baseColorTexture)
        #expect(face.transform != matrix_identity_float3x3)
    }

    @Test("A damaged meshopt stream is refused, not read past")
    func meshoptDamaged() throws {
        var bytes = try Data(contentsOf: Self.fixture("gltfpack-meshopt-khr.glb"))
        bytes = bytes.prefix(bytes.count - 4000)
        let file = try Self.folder().appending(path: "damaged.glb")
        try bytes.write(to: file)
        #expect(throws: GLTFError.unreadable(file: "damaged.glb")) { try ImportedModel.read(gltf: file) }
    }

    /// Blender compresses with Google's encoder and this decodes with Google's decoder; what is tested is that
    /// the right things are asked for and put in the right places. The same character as the gltfpack files,
    /// from another exporter, so it must stand in the same box.
    @Test("A Draco character comes out as the same surface")
    func draco() throws {
        let draco = try ImportedModel.read(gltf: Self.fixture("blender-character-draco.glb"))
        let plain = try ImportedModel.read(gltf: Self.fixture("gltfpack-quantized.glb"))
        #expect(draco.meshes.count == 7)
        for mesh in draco.meshes {
            #expect(!mesh.submeshes.isEmpty && mesh.positions.count > 3, "\(mesh.name)")
            #expect(mesh.normals.count == mesh.positions.count, "\(mesh.name)")
            #expect(mesh.normals.allSatisfy { abs(simd_length($0) - 1) < 0.01 }, "\(mesh.name) normals")
        }
        let a = try #require(draco.bounds), b = try #require(plain.bounds)
        #expect(simd_distance(a.minimum, b.minimum) < 0.01, "\(a.minimum) against \(b.minimum)")
        #expect(simd_distance(a.maximum, b.maximum) < 0.01, "\(a.maximum) against \(b.maximum)")
        func corners(_ model: ImportedModel) -> Int {
            model.meshes.reduce(0) { total, mesh in total + mesh.submeshes.reduce(0) { $0 + $1.indices.count } }
        }
        #expect(corners(draco) == corners(plain), "triangles")
    }

    @Test("Draco data that is not a mesh is refused")
    func dracoDamaged() throws {
        var bytes = try Data(contentsOf: Self.fixture("blender-character-draco.glb"))
        // Overwrite the start of the binary chunk, where the first Draco stream begins.
        let jsonLength = Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        let bin = 20 + jsonLength + 8
        bytes.replaceSubrange(bin..<bin + 16, with: [UInt8](repeating: 0xEE, count: 16))
        let file = try Self.folder().appending(path: "damaged.glb")
        try bytes.write(to: file)
        #expect(throws: GLTFError.unreadable(file: "damaged.glb")) { try ImportedModel.read(gltf: file) }
    }

    // MARK: KTX2

    /// The face is the test character's: an eye stays dark and a cheek stays skin, which is the image the right
    /// way up and the right image.
    @Test("A KTX2 texture decodes through Basis Universal")
    func ktx2() throws {
        let texture = try #require(ImportedTexture(name: "face", encoded: Data(contentsOf: Self.fixture("face-etc1s.ktx2"))))
        #expect(texture.mimeType == "image/ktx2")
        #expect(texture.width == 128 && texture.height == 64)
        func red(_ u: Double, _ v: Double) -> Int {
            Int(texture.pixels[(Int(v * Double(texture.height)) * texture.width + Int(u * Double(texture.width))) * 4])
        }
        #expect(red(0.535, 0.575) < 90, "eye")
        #expect(red(0.2, 0.3) > 180, "skin")
        #expect(texture.pngData() != nil, "a KTX2 can be written as a PNG")
    }

    @Test("A damaged KTX2 is refused")
    func ktx2Damaged() throws {
        let bytes = try Data(contentsOf: Self.fixture("face-etc1s.ktx2"))
        #expect(ImportedTexture(name: "half", encoded: bytes.prefix(bytes.count / 2)) == nil)
    }

    @Test("KHR_texture_basisu is read in preference to its fallback")
    func basisuPreferred() throws {
        var b = Builder()
        b.quad()
        let ktx = b.image(try Data(contentsOf: Self.fixture("face-etc1s.ktx2")), mimeType: "image/ktx2")
        let png = b.image(try Data(contentsOf: Self.fixture("red-top-blue-bottom.png")), mimeType: "image/png")
        b.append("textures", ["source": png, "extensions": ["KHR_texture_basisu": ["source": ktx]]])
        b.append("materials", ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]])
        b.json["extensionsUsed"] = ["KHR_texture_basisu"]
        b.json["extensionsRequired"] = ["KHR_texture_basisu"]
        let model = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "basis", as: .glb))
        let texture = try #require(model.materials.first?.baseColorTexture?.texture)
        #expect(texture.mimeType == "image/ktx2" && texture.width == 128, "the KTX2, not the fallback")
    }

    // MARK: Small files, exact numbers

    @Test("A textured quad comes through number for number")
    func exactQuad() throws {
        var b = Builder()
        b.quad(material: 0)
        let image = b.image(try Data(contentsOf: Self.fixture("red-top-blue-bottom.png")), mimeType: "image/png")
        b.append("samplers", ["magFilter": 9728, "wrapS": 33071, "wrapT": 33648])
        b.append("textures", ["source": image, "sampler": 0])
        b.append("materials", [
            "name": "Painted",
            "pbrMetallicRoughness": [
                "baseColorFactor": [0.5, 0.25, 1, 0.75], "metallicFactor": 0.25, "roughnessFactor": 0.5,
                "baseColorTexture": ["index": 0, "extensions": ["KHR_texture_transform": [
                    "offset": [0.5, 0.25], "scale": [2, 4]]]],
            ],
            "emissiveFactor": [1, 0.5, 0], "alphaMode": "MASK", "alphaCutoff": 0.3, "doubleSided": true,
            "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 4]],
        ] as [String: Any])
        b.json["nodes"] = [["mesh": 0, "translation": [1, 2, 3], "scale": [2, 2, 2], "name": "Quad"]]
        b.json["extensionsUsed"] = ["KHR_texture_transform", "KHR_materials_emissive_strength"]
        let model = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "quad"))

        let mesh = try #require(model.meshes.first)
        #expect(model.meshes.count == 1)
        #expect(mesh.name == "Quad")
        #expect(mesh.positions == Builder.quadPositions)
        #expect(mesh.uvs == Builder.quadUVs)
        #expect(mesh.normals == Array(repeating: SIMD3(0, 0, 1), count: 4))
        #expect(mesh.submeshes.map(\.indices) == [[0, 1, 2, 0, 2, 3]])
        #expect(mesh.submeshes.first?.material == 0)
        #expect(mesh.transform == simd_float4x4(columns: (SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 2, 0),
                                                          SIMD4(1, 2, 3, 1))))

        let material = try #require(model.materials.first)
        #expect(material.name == "Painted")
        #expect(material.baseColor == SIMD4(0.5, 0.25, 1, 0.75))
        #expect(material.metallic == 0.25 && material.roughness == 0.5)
        #expect(material.emissive == SIMD3(4, 2, 0), "the factor times its strength")
        #expect(material.alphaMode == .mask && material.alphaCutoff == 0.3 && material.doubleSided)
        let reference = try #require(material.baseColorTexture)
        #expect(reference.wrapS == .clamp && reference.wrapT == .mirror && reference.nearest)
        #expect(reference.transform * SIMD3(0, 0, 1) == SIMD3(0.5, 0.25, 1), "offset")
        #expect(reference.transform * SIMD3(1, 1, 1) == SIMD3(2.5, 4.25, 1), "scale, then offset")
        // Red on top: the image's first row is its top, as glTF and Metal have it.
        #expect(reference.texture.width == 4 && reference.texture.height == 4)
        let top = Array(reference.texture.pixels.prefix(4)), bottom = Array(reference.texture.pixels.suffix(4))
        #expect(top[0] > top[2] && bottom[2] > bottom[0], "top \(top), bottom \(bottom)")
        #expect(reference.texture.mimeType == "image/png")
    }

    @Test("Strips and fans become triangle lists; points and lines are left out, and said so")
    func primitiveModes() throws {
        var b = Builder()
        let positions = b.accessor(Builder.quadPositions.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3")
        let fourIndices = b.indices([0, 1, 2, 3])
        b.append("meshes", ["name": "Shapes", "primitives": [
            ["attributes": ["POSITION": positions], "indices": fourIndices, "mode": 5],
            ["attributes": ["POSITION": positions], "indices": fourIndices, "mode": 6],
            ["attributes": ["POSITION": positions], "mode": 1],
            ["attributes": ["POSITION": positions], "mode": 0],
        ]] as [String: Any])
        b.append("nodes", ["mesh": 0])
        var reports: [String] = []
        let model = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "modes")) { reports.append($0) }
        let mesh = try #require(model.meshes.first)
        // Every primitive's vertices are kept, so the submeshes' indices stay simple offsets.
        #expect(mesh.submeshes.map(\.indices) == [[0, 1, 2, 2, 1, 3], [4, 5, 6, 4, 6, 7]])
        #expect(reports.count == 2, "\(reports)")
    }

    @Test("Normals: none in the file stays none; some made where a primitive lacks them")
    func normals() throws {
        var b = Builder()
        b.quad(normals: false)
        let none = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "none"))
        #expect(none.meshes.first?.normals.isEmpty == true, "left for whoever draws it")

        var c = Builder()
        let positions = c.accessor(Builder.quadPositions.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3")
        let normals = c.accessor([Float](repeating: 0, count: 12).enumerated().map { $0.offset % 3 == 1 ? 1 : 0 },
                                 type: "VEC3")
        let indices = c.indices([0, 1, 2, 0, 2, 3])
        c.append("meshes", ["primitives": [
            ["attributes": ["POSITION": positions, "NORMAL": normals], "indices": indices],
            ["attributes": ["POSITION": positions], "indices": indices],
        ]] as [String: Any])
        c.append("nodes", ["mesh": 0])
        let mixed = try #require(try ImportedModel.read(gltf: c.write(to: Self.folder(), name: "mixed")).meshes.first)
        #expect(mixed.normals.count == 8)
        #expect(Array(mixed.normals.prefix(4)) == Array(repeating: SIMD3(0, 1, 0), count: 4), "the file's")
        #expect(Array(mixed.normals.suffix(4)) == Array(repeating: SIMD3(0, 0, 1), count: 4), "made from the faces")
    }

    @Test("Meshes are placed through their parents, and only the default scene is read")
    func scenes() throws {
        var b = Builder()
        b.quad()
        b.json["nodes"] = [
            ["children": [1], "translation": [10, 0, 0], "rotation": [0, 0.70710678, 0, 0.70710678]],
            ["mesh": 0, "translation": [0, 0, 1], "name": "Child"],
            ["mesh": 0, "name": "Elsewhere"],
        ] as [[String: Any]]
        b.json["scenes"] = [["nodes": [2]], ["nodes": [0]]]
        b.json["scene"] = 1
        let model = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "scenes"))
        #expect(model.meshes.map(\.name) == ["Child"])
        // A quarter turn about y takes the child's +z to the parent's +x.
        let origin = try #require(model.meshes.first).transform * SIMD4(0, 0, 0, 1)
        #expect(simd_distance(SIMD3(origin.x, origin.y, origin.z), SIMD3(11, 0, 0)) < 1e-5)

        // No scenes at all: every node nothing parents.
        b.json["scenes"] = nil
        b.json["scene"] = nil
        let all = try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "no-scenes"))
        #expect(all.meshes.map(\.name) == ["Child", "Elsewhere"])
    }

    @Test("A buffer beside the file is read, and a missing one is named")
    func externalBuffer() throws {
        var b = Builder()
        b.quad()
        let folder = try Self.folder()
        let url = try b.write(to: folder, name: "beside", as: .external)
        #expect(try ImportedModel.read(gltf: url).meshes.first?.positions == Builder.quadPositions)
        try FileManager.default.removeItem(at: folder.appending(path: "beside.bin"))
        #expect(throws: GLTFError.missingResource(file: "beside.gltf", resource: "beside.bin")) {
            try ImportedModel.read(gltf: url)
        }
    }

    @Test("A file that requires an extension this does not read is refused, by name")
    func unknownRequiredExtension() throws {
        var b = Builder()
        b.quad()
        b.json["extensionsUsed"] = ["KHR_mesh_quantization", "EXT_made_up_geometry"]
        b.json["extensionsRequired"] = ["KHR_mesh_quantization", "EXT_made_up_geometry"]
        let url = try b.write(to: Self.folder(), name: "required")
        #expect(throws: GLTFError.unsupportedExtension(file: "required.gltf", name: "EXT_made_up_geometry")) {
            try ImportedModel.read(gltf: url)
        }
        // Merely used is no reason to refuse: the file must still read without it.
        b.json["extensionsRequired"] = nil
        #expect(try ImportedModel.read(gltf: b.write(to: Self.folder(), name: "used")).meshes.count == 1)
        #expect(GLTFError.unsupportedExtension(file: "a.gltf", name: "EXT_x").description.contains("EXT_x"))
    }

    @Test("glTF 1.0 and files that are not glTF are refused")
    func notGLTF() throws {
        var b = Builder()
        b.quad()
        b.json["asset"] = ["version": "1.0"]
        let old = try b.write(to: Self.folder(), name: "old")
        #expect(throws: GLTFError.unsupportedVersion(file: "old.gltf", version: "1.0")) { try ImportedModel.read(gltf: old) }
        let text = try Self.folder().appending(path: "text.gltf")
        try Data("not json".utf8).write(to: text)
        #expect(throws: GLTFError.unreadable(file: "text.gltf")) { try ImportedModel.read(gltf: text) }
    }
}

// MARK: Writing small glTF files

/// Writes glTF by hand, so a test can say exactly what is in the file.
struct Builder {
    var json: [String: Any] = ["asset": ["version": "2.0"]]
    var bin = Data()

    static let quadPositions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
    /// glTF's way up: v = 0 is the top of the image, so the quad's top corners have v = 0.
    static let quadUVs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]

    mutating func accessor(_ floats: [Float], type: String) -> Int {
        let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type]!
        return accessor(floats.withUnsafeBytes { Data($0) }, componentType: 5126, type: type, count: floats.count / width)
    }

    mutating func indices(_ values: [UInt16]) -> Int {
        accessor(values.withUnsafeBytes { Data($0) }, componentType: 5123, type: "SCALAR", count: values.count)
    }

    mutating func accessor(_ bytes: Data, componentType: Int, type: String, count: Int) -> Int {
        while bin.count % 4 != 0 { bin.append(0) }
        append("bufferViews", ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count])
        bin.append(bytes)
        return append("accessors", ["bufferView": (json["bufferViews"] as! [Any]).count - 1,
                                    "componentType": componentType, "count": count, "type": type])
    }

    /// An image kept in the buffer, as a `.glb` keeps it.
    mutating func image(_ data: Data, mimeType: String) -> Int {
        while bin.count % 4 != 0 { bin.append(0) }
        let view = append("bufferViews", ["buffer": 0, "byteOffset": bin.count, "byteLength": data.count])
        bin.append(data)
        return append("images", ["bufferView": view, "mimeType": mimeType])
    }

    /// One quad facing +z, two triangles, in a mesh on a node.
    mutating func quad(material: Int? = nil, normals: Bool = true) {
        var attributes = ["POSITION": accessor(Self.quadPositions.flatMap { [$0.x, $0.y, $0.z] }, type: "VEC3"),
                          "TEXCOORD_0": accessor(Self.quadUVs.flatMap { [$0.x, $0.y] }, type: "VEC2")]
        if normals { attributes["NORMAL"] = accessor([Float](repeating: 0, count: 12).enumerated().map {
            $0.offset % 3 == 2 ? 1 : 0 }, type: "VEC3") }
        var primitive: [String: Any] = ["attributes": attributes, "indices": indices([0, 1, 2, 0, 2, 3])]
        if let material { primitive["material"] = material }
        append("meshes", ["primitives": [primitive]])
        append("nodes", ["mesh": (json["meshes"] as! [Any]).count - 1])
    }

    @discardableResult
    mutating func append(_ key: String, _ value: Any) -> Int {
        var list = json[key] as? [Any] ?? []
        list.append(value)
        json[key] = list
        return list.count - 1
    }

    /// Embedded as base64, beside it as `name.bin`, or as a `.glb`.
    enum Container { case embedded, external, glb }

    func write(to folder: URL, name: String, as container: Container = .embedded) throws -> URL {
        var json = self.json
        switch container {
        case .embedded:
            json["buffers"] = [["byteLength": bin.count,
                                "uri": "data:application/octet-stream;base64," + bin.base64EncodedString()]]
        case .external:
            json["buffers"] = [["byteLength": bin.count, "uri": "\(name).bin"]]
            try bin.write(to: folder.appending(path: "\(name).bin"))
        case .glb:
            json["buffers"] = [["byteLength": bin.count]]
        }
        var text = try JSONSerialization.data(withJSONObject: json)
        guard container == .glb else {
            let url = folder.appending(path: "\(name).gltf")
            try text.write(to: url)
            return url
        }
        while text.count % 4 != 0 { text.append(0x20) }
        var binary = bin
        while binary.count % 4 != 0 { binary.append(0) }
        var out = Data()
        func word(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        word(0x4654_6C67); word(2); word(UInt32(28 + text.count + binary.count))
        word(UInt32(text.count)); word(0x4E4F_534A); out.append(text)
        word(UInt32(binary.count)); word(0x004E_4942); out.append(binary)
        let url = folder.appending(path: "\(name).glb")
        try out.write(to: url)
        return url
    }
}
