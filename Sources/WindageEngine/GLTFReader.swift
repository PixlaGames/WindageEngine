//
//  GLTFReader.swift
//  WindageEngine
//

import Draco
import Foundation
import simd

/// Why a glTF file could not be read.
public nonisolated enum GLTFError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Not glTF, or damaged: the JSON does not parse, a chunk or a buffer is cut short, an accessor points
    /// outside its data, or compressed data does not decode.
    case unreadable(file: String)
    /// glTF, but not 2.0.
    case unsupportedVersion(file: String, version: String)
    /// The file lists an extension in `extensionsRequired` that this reader does not understand. Read anyway,
    /// its geometry or its look would come out wrong, so it is refused instead.
    case unsupportedExtension(file: String, name: String)
    /// A buffer the file keeps in another file — a `.bin` beside a `.gltf` — that could not be read: missing,
    /// or outside what the sandbox was given.
    case missingResource(file: String, resource: String)

    public var description: String {
        switch self {
        case .unreadable(let file):
            "\(file) could not be read as glTF."
        case .unsupportedVersion(let file, let version):
            "\(file) is glTF \(version). Only glTF 2.0 is read."
        case .unsupportedExtension(let file, let name):
            "\(file) requires the glTF extension \(name), which Windage Engine does not read. Exporting it again "
                + "without that extension usually works."
        case .missingResource(let file, let resource):
            "\(file) keeps its data in \(resource), which could not be read. A sandboxed app can read a file beside "
                + "a .gltf only when it has the same name, such as \((file as NSString).deletingPathExtension).bin, "
                + "and the app declares that type as a related item; otherwise check the file is there."
        }
    }
}

public nonisolated extension ImportedModel {

    /// The file extensions ``read(gltf:reportingTo:)`` reads.
    static let gltfFileExtensions: Set<String> = ["gltf", "glb"]

    /// Reads a glTF 2.0 file — `.gltf`, with its buffers embedded or in files beside it, or `.glb`.
    ///
    /// Every mesh in the default scene comes out placed by its node's transform, with its materials and their
    /// images. Skins and animations are not read: a skinned mesh comes out in its bind pose. Compressed files
    /// are read — meshopt, Draco, quantized attributes and KTX2 textures.
    ///
    /// - Parameter report: told about anything left out on the way — an image that could not be read, lines or
    ///   points that are not triangles — which does not stop the rest being read.
    /// - Throws: ``GLTFError``.
    static func read(gltf url: URL, reportingTo report: ((String) -> Void)? = nil) throws -> ImportedModel {
        try GLTFReader.read(url: url, reportingTo: report)
    }
}

/// Reads glTF 2.0 into an ``ImportedModel``. Written in Swift, because nothing Apple ships reads glTF.
///
/// **Extracted from a character-creator app's reader, with the rig taken out.** What a prop needs from a file
/// is narrower than what glTF can say, and the rest is read past rather than refused: cameras, lights, skins,
/// morph targets and animations are ignored. Only a file that *requires* an extension this does not understand
/// is turned away, because its geometry or its look would otherwise come out as garbage.
///
/// - **Every mesh is placed by its node's world transform**, composed from the scene's roots — all the nodes of
///   the default scene, or every node nothing parents when the file has no scenes, which glTF allows.
/// - **A skinned mesh comes out in its bind pose.** glTF places a skinned mesh by its joints and ignores its
///   node, so its placement is what the joints say at rest: each joint's world transform times its inverse
///   bind matrix. When every joint agrees — the usual case — that matrix is the mesh's transform. An exporter
///   may fold a transform of its own into every inverse bind (gltfpack does, to turn quantized integers back
///   into metres), and reading the node instead would leave such a mesh thousands of units wide. When the
///   joints disagree, the rig was posed away from its bind, and the node's transform is used.
nonisolated enum GLTFReader {

    /// Extensions whose presence in `extensionsRequired` changes nothing this reader gets wrong.
    /// KHR_mesh_quantization allows integer positions and normals, which the accessor reader already converts.
    /// KHR_materials_unlit's fallback is the lit material it sits on, which is what is read.
    private static let understoodExtensions: Set<String> = [
        "KHR_mesh_quantization", "KHR_materials_unlit", "EXT_meshopt_compression", "KHR_meshopt_compression",
        "KHR_draco_mesh_compression", "KHR_materials_emissive_strength", "KHR_texture_transform", "EXT_texture_webp",
        "KHR_texture_basisu",
    ]

    static func read(url: URL, reportingTo report: ((String) -> Void)?) throws -> ImportedModel {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw GLTFError.unreadable(file: file) }
        let (json, glbBinary) = try container(data, file: file)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: json)
        } catch {
            throw GLTFError.unreadable(file: file)
        }
        guard document.asset.version.hasPrefix("2.") else {
            throw GLTFError.unsupportedVersion(file: file, version: document.asset.version)
        }
        if let required = document.extensionsRequired?.first(where: { !understoodExtensions.contains($0) }) {
            throw GLTFError.unsupportedExtension(file: file, name: required)
        }
        let buffers = try (document.buffers ?? []).enumerated().map { index, buffer in
            try load(buffer, index: index, glbBinary: glbBinary, beside: url)
        }
        return try Reader(document: document, buffers: buffers, url: url, report: report).read()
    }

    // MARK: Containers and buffers

    /// The JSON, and the binary chunk when the file is a `.glb`.
    private static func container(_ data: Data, file: String) throws -> (json: Data, binary: Data?) {
        guard data.count >= 12, data.word(at: 0) == 0x4654_6C67 else { return (data, nil) }   // "glTF"
        guard data.word(at: 4) == 2 else {
            throw GLTFError.unsupportedVersion(file: file, version: String(data.word(at: 4)))
        }
        var json: Data?, binary: Data?
        var offset = 12
        let end = min(Int(data.word(at: 8)), data.count)
        while offset + 8 <= end {
            let length = Int(data.word(at: offset)), type = data.word(at: offset + 4)
            let start = offset + 8
            guard start + length <= end else { throw GLTFError.unreadable(file: file) }
            let chunk = data.subdata(in: start..<start + length)
            if type == 0x4E4F_534A, json == nil { json = chunk }          // "JSON"
            if type == 0x004E_4942, binary == nil { binary = chunk }      // "BIN\0"
            offset = start + length
        }
        guard let json else { throw GLTFError.unreadable(file: file) }
        return (json, binary)
    }

    private static func load(_ buffer: Document.Buffer, index: Int, glbBinary: Data?, beside url: URL) throws -> Data {
        let file = url.lastPathComponent
        let data: Data
        if let uri = buffer.uri {
            if uri.hasPrefix("data:") {
                guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                      let decoded = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                    throw GLTFError.unreadable(file: file)
                }
                data = decoded
            } else {
                // Relative to the file, percent-encoded as a URI.
                let path = uri.removingPercentEncoding ?? uri
                let resource = URL(filePath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                guard let read = (try? Data(contentsOf: resource)) ?? RelatedFile.read(resource, beside: url) else {
                    throw GLTFError.missingResource(file: file, resource: path)
                }
                data = read
            }
        } else if index == 0, let glbBinary {
            data = glbBinary
        } else {
            // A placeholder: the space a compressed view decodes into, with nothing stored. Only a view
            // that is decoded may point into it, and `bytes(view:)` refuses any other.
            return Data()
        }
        guard data.count >= buffer.byteLength else { throw GLTFError.unreadable(file: file) }
        return data
    }
}

// MARK: A file beside the one opened

/// Reads a file that sits beside one the person opened — a `.gltf`'s `.bin` — which the sandbox has not
/// granted, because only the file chosen was.
///
/// **macOS's answer is a related item**: the app declares the neighbour's type with
/// `NSIsRelatedItemType` in its Info.plist, and reads it through a file presenter whose primary item is
/// the file that *was* granted. The coordinated read is what extends the sandbox to it. Outside a
/// sandbox, or for a file already reachable, it is never needed — which is why it is only the fallback.
///
/// **macOS grants a related item only if it shares the primary file's name**: `hero.gltf` reaches
/// `hero.bin`, never `hero data.bin`. Blender and most exporters write the matching name. Measured in a
/// sandboxed app, since the sandbox cannot be reproduced under `swift test`.
private nonisolated final class RelatedFile: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    private init(_ url: URL, primary: URL) {
        presentedItemURL = url
        primaryPresentedItemURL = primary
    }

    static func read(_ url: URL, beside primary: URL) -> Data? {
        let presenter = RelatedFile(url, primary: primary)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &error) {
            data = try? Data(contentsOf: $0)
        }
        return data
    }
}

// MARK: Reading the document

private nonisolated struct Reader {
    let document: Document
    let buffers: [Data]
    let file: String
    let report: ((String) -> Void)?

    /// Parent of every node, and the order a depth-first walk of the scene meets them.
    private let parents: [Int?]
    private let sceneOrder: [Int]

    /// Compressed buffer views, decoded once, by view index. Everything downstream reads these as if
    /// the file had never been compressed.
    private let decoded: [Int: Data]

    /// The file itself, for finding images beside it.
    let url: URL
    /// Decoded images, shared by every material that uses them. A class so a `Reader` value can fill
    /// it as materials ask.
    private let images = ImageCache()

    init(document: Document, buffers: [Data], url: URL, report: ((String) -> Void)?) throws {
        self.document = document
        self.buffers = buffers
        self.file = url.lastPathComponent
        self.url = url
        self.report = report
        var decoded: [Int: Data] = [:]
        for (index, view) in (document.bufferViews ?? []).enumerated() {
            guard let meshopt = view.extensions?.meshopt else { continue }
            guard let source = buffers[safe: meshopt.buffer],
                  let mode = MeshoptDecoder.Mode(rawValue: meshopt.mode),
                  let filter = MeshoptDecoder.Filter(rawValue: meshopt.filter ?? "NONE") else {
                throw GLTFError.unreadable(file: file)
            }
            let start = meshopt.byteOffset ?? 0
            guard start >= 0, start + meshopt.byteLength <= source.count,
                  let data = try? MeshoptDecoder.decode(source.subdata(in: start..<start + meshopt.byteLength),
                                                        count: meshopt.count, stride: meshopt.byteStride,
                                                        mode: mode, filter: filter),
                  data.count >= view.byteLength else {
                throw GLTFError.unreadable(file: file)
            }
            decoded[index] = data
        }
        self.decoded = decoded
        let nodes = document.nodes ?? []
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.children ?? [] where nodes.indices.contains(child) { parents[child] = index }
        }
        self.parents = parents
        // The default scene's roots, or — for a file with no scenes, which glTF allows — every node
        // nothing else parents.
        let roots: [Int]
        if let scenes = document.scenes, !scenes.isEmpty {
            roots = scenes[min(document.scene ?? 0, scenes.count - 1)].nodes ?? []
        } else {
            roots = nodes.indices.filter { parents[$0] == nil }
        }
        var order: [Int] = [], seen = Set<Int>()
        func walk(_ index: Int) {
            guard nodes.indices.contains(index), seen.insert(index).inserted else { return }
            order.append(index)
            for child in nodes[index].children ?? [] { walk(child) }
        }
        roots.forEach(walk)
        sceneOrder = order
    }

    private var nodes: [Document.Node] { document.nodes ?? [] }

    func read() throws -> ImportedModel {
        // Every material in the file, in its order, so a submesh's index is the file's own.
        let materials = (document.materials ?? []).map(material)
        var meshes: [ImportedMesh] = []
        for index in sceneOrder {
            guard let meshIndex = nodes[index].mesh, let mesh = document.meshes?[safe: meshIndex] else { continue }
            if let made = try makeMesh(mesh, node: index, materialCount: materials.count) { meshes.append(made) }
        }
        for path in images.missing { report?("\(file): the image \(path) could not be read") }
        return ImportedModel(meshes: meshes, materials: materials)
    }

    /// Two matrices equal to a tolerance scaled by their size, so a matrix holding quantization's tiny
    /// scale is compared as carefully as one holding metres.
    private static func same(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        let scale = max(1e-6, (0..<4).flatMap { c in (0..<4).map { max(abs(a[c][$0]), abs(b[c][$0])) } }.max() ?? 1)
        return (0..<4).allSatisfy { c in (0..<4).allSatisfy { abs(a[c][$0] - b[c][$0]) <= scale * 1e-4 } }
    }

    /// Where a skinned mesh stands at bind: what every one of its joints, at rest, times its inverse bind
    /// matrix agrees on — see ``GLTFReader``. Nil when they disagree, or the skin has no joints in the file.
    private func bindPlacement(of skin: Document.Skin) throws -> simd_float4x4? {
        let matrices: [simd_float4x4] = try skin.inverseBindMatrices.map { try readMatrices($0) } ?? []
        let shapes = skin.joints.enumerated().compactMap { position, node -> simd_float4x4? in
            nodes.indices.contains(node) ? worldTransform(of: node) * (matrices[safe: position] ?? matrix_identity_float4x4) : nil
        }
        guard let shape = shapes.first, shapes.allSatisfy({ Self.same($0, shape) }), abs(shape.determinant) > 1e-12
        else { return nil }
        return shape
    }

    // MARK: Meshes

    /// One node's mesh: every triangle primitive, its vertices appended to the mesh's, one submesh each.
    private func makeMesh(_ mesh: Document.Mesh, node: Int, materialCount: Int) throws -> ImportedMesh? {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = [], colors: [SIMD4<Float>] = []
        var submeshes: [ImportedSubmesh] = []
        // Normals for every vertex or none: a primitive without them, merged with one that has them, has its
        // own made from its faces; a mesh where no primitive has any leaves them to whoever draws it.
        var withoutNormals: [(range: Range<Int>, indices: [UInt32])] = []
        let name = mesh.name ?? nodes[node].name ?? "mesh \(node)"

        for primitive in mesh.primitives {
            let mode = primitive.mode ?? 4
            guard [4, 5, 6].contains(mode) else {
                // Points and lines: nothing a surface renderer draws.
                report?("\(file): \(name) has points or lines, which were left out")
                continue
            }
            guard primitive.attributes["POSITION"] != nil else { continue }
            // Where this primitive's data lives: its accessors, or — Draco-compressed — one buffer view
            // decoded as a whole, with the accessors describing only what comes out.
            let source = try PrimitiveSource(primitive, reader: self)
            let base = positions.count
            let primitivePositions = try source.floats("POSITION", components: 3).map { SIMD3($0[0], $0[1], $0[2]) }
            let count = primitivePositions.count
            var indices = try source.indices() ?? Array(0..<UInt32(count))
            indices = triangles(indices, mode: mode)
            guard indices.allSatisfy({ Int($0) < count }) else { throw GLTFError.unreadable(file: file) }

            if source.has("NORMAL") {
                let read = try source.floats("NORMAL", components: 3).map { simd_normalize(SIMD3($0[0], $0[1], $0[2])) }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                normals += Array(repeating: .zero, count: base - normals.count) + read
            } else {
                withoutNormals.append((base..<base + count, indices))
            }
            // Texture coordinates and colours for every vertex or none: a primitive without them, merged with
            // one that has them, gets zeros — which sample a texture's corner rather than reading past — and
            // white, which leaves the material's colour alone.
            if source.has("TEXCOORD_0") {
                uvs += Array(repeating: .zero, count: base - uvs.count)
                let read = try source.floats("TEXCOORD_0", components: 2).map { SIMD2($0[0], $0[1]) }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                uvs += read
            }
            if source.has("COLOR_0") {
                let width = source.components("COLOR_0") == 4 ? 4 : 3
                colors += Array(repeating: SIMD4(repeating: 1), count: base - colors.count)
                let read = try source.floats("COLOR_0", components: width).map {
                    SIMD4($0[0], $0[1], $0[2], width == 4 ? $0[3] : 1)
                }
                guard read.count == count else { throw GLTFError.unreadable(file: file) }
                colors += read
            }
            positions += primitivePositions
            guard !indices.isEmpty else { continue }
            let material = primitive.material.flatMap { (0..<materialCount).contains($0) ? $0 : nil }
            submeshes.append(ImportedSubmesh(indices: indices.map { $0 + UInt32(base) }, material: material))
        }
        guard !submeshes.isEmpty else { return nil }
        if !uvs.isEmpty { uvs += Array(repeating: .zero, count: positions.count - uvs.count) }
        if !colors.isEmpty { colors += Array(repeating: SIMD4(repeating: 1), count: positions.count - colors.count) }
        if !normals.isEmpty {
            normals += Array(repeating: .zero, count: positions.count - normals.count)
            for (range, indices) in withoutNormals {
                let made = ImportedMesh.smoothNormals(Array(positions[range]), indices)
                normals.replaceSubrange(range, with: made)
            }
        }

        var transform = worldTransform(of: node)
        if let skin = nodes[node].skin.flatMap({ document.skins?[safe: $0] }), let placed = try bindPlacement(of: skin) {
            transform = placed
        }
        return ImportedMesh(name: name, transform: transform, positions: positions, normals: normals, uvs: uvs,
                            colors: colors, submeshes: submeshes)
    }

    // MARK: Materials

    /// A glTF material, factors and textures both, as glTF defines them.
    private func material(_ m: Document.Material) -> ImportedMaterial {
        let pbr = m.pbrMetallicRoughness
        let base = pbr?.baseColorFactor ?? [1, 1, 1, 1]
        let emissive = m.emissiveFactor ?? [0, 0, 0]
        let strength = m.extensions?.emissiveStrength?.emissiveStrength ?? 1
        return ImportedMaterial(
            name: m.name ?? "",
            baseColor: SIMD4(base[safe: 0] ?? 1, base[safe: 1] ?? 1, base[safe: 2] ?? 1, base[safe: 3] ?? 1),
            baseColorTexture: texture(pbr?.baseColorTexture),
            metallic: pbr?.metallicFactor ?? 1,
            roughness: pbr?.roughnessFactor ?? 1,
            metallicRoughnessTexture: texture(pbr?.metallicRoughnessTexture),
            normalTexture: texture(m.normalTexture),
            normalScale: m.normalTexture?.scale ?? 1,
            occlusionTexture: texture(m.occlusionTexture),
            occlusionStrength: m.occlusionTexture?.strength ?? 1,
            emissive: SIMD3(emissive[safe: 0] ?? 0, emissive[safe: 1] ?? 0, emissive[safe: 2] ?? 0) * strength,
            emissiveTexture: texture(m.emissiveTexture),
            alphaMode: ImportedMaterial.AlphaMode(rawValue: (m.alphaMode ?? "OPAQUE").lowercased()) ?? .opaque,
            alphaCutoff: m.alphaCutoff ?? 0.5,
            doubleSided: m.doubleSided ?? false)
    }

    /// A texture a material names, or nil when its image cannot be had — missing, unreadable, or in a
    /// format nothing here decodes. The material then draws with its factor alone, which is what a
    /// careful engine does too, and the image is reported.
    private func texture(_ info: Document.TextureInfo?) -> ImportedTextureReference? {
        guard let info, let texture = document.textures?[safe: info.index],
              let imageIndex = texture.extensions?.basisu?.source ?? texture.extensions?.webp?.source ?? texture.source,
              let image = self.image(imageIndex) else { return nil }
        let sampler = texture.sampler.flatMap { document.samplers?[safe: $0] }
        func wrap(_ mode: Int?) -> ImportedTextureReference.Wrap {
            switch mode { case 33071: .clamp; case 33648: .mirror; default: .repeating }
        }
        var transform = matrix_identity_float3x3
        if let t = info.extensions?.transform {
            // KHR_texture_transform: translation × rotation × scale, applied to (u, v, 1).
            let o = t.offset ?? [0, 0], s = t.scale ?? [1, 1], r = t.rotation ?? 0
            let translation = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(o[safe: 0] ?? 0, o[safe: 1] ?? 0, 1))
            let rotation = simd_float3x3(SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1))
            let scale = simd_float3x3(diagonal: SIMD3(s[safe: 0] ?? 1, s[safe: 1] ?? 1, 1))
            transform = translation * rotation * scale
        }
        return ImportedTextureReference(texture: image, wrapS: wrap(sampler?.wrapS), wrapT: wrap(sampler?.wrapT),
                                        nearest: sampler?.magFilter == 9728, transform: transform)
    }

    private func image(_ index: Int) -> ImportedTexture? {
        if let known = images.textures[index] { return known }
        guard !images.failed.contains(index), let image = document.images?[safe: index] else { return nil }
        let name = image.name ?? image.uri.map { ($0.removingPercentEncoding ?? $0) } ?? "image \(index)"
        var data: Data?
        if let uri = image.uri {
            if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                data = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            } else {
                let path = uri.removingPercentEncoding ?? uri
                let resource = URL(filePath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                data = (try? Data(contentsOf: resource)) ?? RelatedFile.read(resource, beside: url)
                if data == nil { images.missing.append(path) }
            }
        } else if let view = image.bufferView, let length = document.bufferViews?[safe: view]?.byteLength,
                  let (bytes, start, _) = try? bytes(view: view, byteOffset: 0, elementSize: 1, count: length) {
            data = bytes.subdata(in: start..<start + length)
        }
        guard let data, let texture = ImportedTexture(name: name, encoded: data) else {
            if data != nil { report?("\(file): the image \(name) is in a format that could not be decoded") }
            images.failed.insert(index)
            return nil
        }
        images.textures[index] = texture
        return texture
    }

    /// Root first, ending at the node itself.
    private func ancestry(of node: Int) -> [Int] {
        var chain = [node], at = node
        while let parent = parents[at], !chain.contains(parent) { chain.append(parent); at = parent }
        return chain.reversed()
    }

    private func worldTransform(of node: Int) -> simd_float4x4 {
        ancestry(of: node).reduce(matrix_identity_float4x4) { $0 * TRS(nodes[$1]).matrix }
    }

    /// Strips and fans unrolled into a plain triangle list, with degenerate triangles dropped.
    private func triangles(_ indices: [UInt32], mode: Int) -> [UInt32] {
        guard mode != 4, indices.count >= 3 else { return Array(indices.prefix(indices.count / 3 * 3)) }
        var out: [UInt32] = []
        for i in 2..<indices.count {
            let tri = mode == 5
                ? (i % 2 == 0 ? [indices[i - 2], indices[i - 1], indices[i]] : [indices[i - 1], indices[i - 2], indices[i]])
                : [indices[0], indices[i - 1], indices[i]]
            if Set(tri).count == 3 { out += tri }
        }
        return out
    }

    // MARK: Accessors

    /// An accessor's elements as floats, `components` per element, normalised integers converted as
    /// the specification says. `rawIntegers` reads integer data as its plain value — indices.
    fileprivate func readFloats(_ index: Int, components: Int, rawIntegers: Bool = false) throws -> [[Float]] {
        guard let accessor = document.accessors?[safe: index],
              let width = Document.Accessor.components[accessor.type], width >= components || accessor.type == "SCALAR" else {
            throw GLTFError.unreadable(file: file)
        }
        var values = [[Float]](repeating: [Float](repeating: 0, count: width), count: accessor.count)
        if let view = accessor.bufferView {
            let (data, offset, stride) = try bytes(view: view, byteOffset: accessor.byteOffset ?? 0,
                                                    elementSize: accessor.componentSize * width, count: accessor.count)
            let normalized = accessor.normalized == true && !rawIntegers
            data.withUnsafeBytes { raw in
                for element in 0..<accessor.count {
                    for c in 0..<width {
                        values[element][c] = Self.component(raw, at: offset + element * stride + c * accessor.componentSize,
                                                            type: accessor.componentType, normalized: normalized)
                    }
                }
            }
        }
        if let sparse = accessor.sparse {
            let at = try readIndices(sparse.indices, count: sparse.count)
            let (data, offset, _) = try bytes(view: sparse.values.bufferView, byteOffset: sparse.values.byteOffset ?? 0,
                                               elementSize: accessor.componentSize * width, count: sparse.count)
            data.withUnsafeBytes { raw in
                for (n, element) in at.enumerated() where Int(element) < accessor.count {
                    for c in 0..<width {
                        values[Int(element)][c] = Self.component(raw, at: offset + (n * width + c) * accessor.componentSize,
                                                                 type: accessor.componentType,
                                                                 normalized: accessor.normalized == true && !rawIntegers)
                    }
                }
            }
        }
        return values
    }

    /// Index data, of any integer width.
    fileprivate func readIndices(_ index: Int) throws -> [UInt32] {
        guard let accessor = document.accessors?[safe: index] else { throw GLTFError.unreadable(file: file) }
        return try readFloats(index, components: 1, rawIntegers: true).map { UInt32($0[0]) }
            .prefix(accessor.count).map { $0 }
    }

    /// A sparse accessor's indices, which live in their own small block rather than an accessor.
    private func readIndices(_ sparse: Document.Accessor.Sparse.Indices, count: Int) throws -> [UInt32] {
        let size = sparse.componentType == 5121 ? 1 : sparse.componentType == 5123 ? 2 : 4
        let (data, offset, _) = try bytes(view: sparse.bufferView, byteOffset: sparse.byteOffset ?? 0,
                                           elementSize: size, count: count)
        return data.withUnsafeBytes { raw in
            (0..<count).map { UInt32(Self.component(raw, at: offset + $0 * size, type: sparse.componentType, normalized: false)) }
        }
    }

    private func readMatrices(_ index: Int) throws -> [simd_float4x4] {
        try readFloats(index, components: 16).map { m in
            simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        }
    }

    /// A buffer view's bytes, where its first element starts, and the distance between elements —
    /// checked to lie inside the buffer, so a truncated file is refused rather than read past.
    fileprivate func bytes(view index: Int, byteOffset: Int, elementSize: Int, count: Int) throws -> (Data, Int, Int) {
        guard let view = document.bufferViews?[safe: index] else { throw GLTFError.unreadable(file: file) }
        if let data = decoded[index] {
            // Decoded views start at their own first byte.
            let stride = view.byteStride ?? elementSize
            let needed = count == 0 ? 0 : (count - 1) * stride + elementSize
            guard byteOffset >= 0, stride >= elementSize || count <= 1, byteOffset + needed <= data.count else {
                throw GLTFError.unreadable(file: file)
            }
            return (data, byteOffset, stride)
        }
        guard let buffer = buffers[safe: view.buffer] else { throw GLTFError.unreadable(file: file) }
        let stride = view.byteStride ?? elementSize
        let start = (view.byteOffset ?? 0) + byteOffset
        let needed = count == 0 ? 0 : (count - 1) * stride + elementSize
        guard start >= 0, stride >= elementSize || count <= 1,
              start + needed <= (view.byteOffset ?? 0) + view.byteLength,
              (view.byteOffset ?? 0) + view.byteLength <= buffer.count else {
            throw GLTFError.unreadable(file: file)
        }
        return (buffer, start, stride)
    }

    private static func component(_ raw: UnsafeRawBufferPointer, at offset: Int, type: Int, normalized: Bool) -> Float {
        switch type {
        case 5120: let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self)); return normalized ? max(v / 127, -1) : v
        case 5121: let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)); return normalized ? v / 255 : v
        case 5122: let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            return normalized ? max(v / 32767, -1) : v
        case 5123: let v = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            return normalized ? v / 65535 : v
        case 5125: return Float(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        default: return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
    }
}

/// Images decoded while a document is read, and those that could not be.
private nonisolated final class ImageCache {
    var textures: [Int: ImportedTexture] = [:]
    var failed: Set<Int> = []
    var missing: [String] = []
}

// MARK: Draco

/// A primitive's vertex data, from its accessors or from its Draco-compressed buffer view.
///
/// **KHR_draco_mesh_compression replaces a primitive's accessors' data, not their meaning**: the
/// accessors still say how many values and what type, but the values come out of one decoded mesh,
/// matched to glTF attributes by the unique ids the extension lists. An attribute the extension does not
/// list is read from its accessor as usual.
private nonisolated struct PrimitiveSource {
    let primitive: Document.Primitive
    let reader: Reader
    private let draco: DecodedDraco?

    init(_ primitive: Document.Primitive, reader: Reader) throws {
        self.primitive = primitive
        self.reader = reader
        if let ext = primitive.extensions?.draco {
            let length = reader.document.bufferViews?[safe: ext.bufferView]?.byteLength ?? 0
            let (data, start, _) = try reader.bytes(view: ext.bufferView, byteOffset: 0, elementSize: 1, count: length)
            guard let decoded = DecodedDraco(data.subdata(in: start..<start + length), attributes: ext.attributes) else {
                throw GLTFError.unreadable(file: reader.file)
            }
            draco = decoded
        } else {
            draco = nil
        }
    }

    func has(_ name: String) -> Bool { primitive.attributes[name] != nil }

    /// Components per element the file declares for an attribute — 3 or 4 for a colour.
    func components(_ name: String) -> Int? {
        primitive.attributes[name].flatMap { reader.document.accessors?[safe: $0] }
            .flatMap { Document.Accessor.components[$0.type] }
    }

    func floats(_ name: String, components: Int, rawIntegers: Bool = false) throws -> [[Float]] {
        if let draco, let id = draco.attributes[name] {
            guard let values = draco.floats(id, components: components) else {
                throw GLTFError.unreadable(file: reader.file)
            }
            return values
        }
        guard let accessor = primitive.attributes[name] else { throw GLTFError.unreadable(file: reader.file) }
        return try reader.readFloats(accessor, components: components, rawIntegers: rawIntegers)
    }

    func indices() throws -> [UInt32]? {
        if let draco { return draco.indices }
        return try primitive.indices.map { try reader.readIndices($0) }
    }
}

/// One Draco mesh, decoded by Google's reference decoder and copied out into Swift values at once.
private nonisolated final class DecodedDraco {
    let attributes: [String: UInt32]
    let indices: [UInt32]
    private let mesh: OpaquePointer
    private let points: Int

    init?(_ data: Data, attributes: [String: UInt32]) {
        guard let mesh = data.withUnsafeBytes({ raw in raw.baseAddress.flatMap { we_draco_decode($0, raw.count) } }) else {
            return nil
        }
        self.mesh = mesh
        self.attributes = attributes
        points = Int(we_draco_point_count(mesh))
        var indices = [UInt32](repeating: 0, count: Int(we_draco_face_count(mesh)) * 3)
        indices.withUnsafeMutableBufferPointer { we_draco_indices(mesh, $0.baseAddress!) }
        self.indices = indices
    }

    deinit { we_draco_free(mesh) }

    /// An attribute as `components` floats per point, padding or truncating what Draco stores.
    func floats(_ id: UInt32, components: Int) -> [[Float]]? {
        let stored = Int(we_draco_attribute_components(mesh, id))
        guard stored > 0 else { return nil }
        var flat = [Float](repeating: 0, count: points * stored)
        let ok = flat.withUnsafeMutableBufferPointer { we_draco_attribute_floats(mesh, id, $0.baseAddress!) }
        guard ok != 0 else { return nil }
        return (0..<points).map { p in (0..<components).map { c in c < stored ? flat[p * stored + c] : 0 } }
    }
}

// MARK: Transforms

/// A node's translation, rotation and scale — glTF's own way of writing a transform.
private nonisolated struct TRS: Equatable {
    var translation = SIMD3<Float>.zero
    var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var scale = SIMD3<Float>(repeating: 1)
    /// A node written as a matrix is kept as one: pulling it apart and putting it back together is exact
    /// only for a matrix with no shear.
    var written: simd_float4x4?

    init(_ node: Document.Node) {
        if let m = node.matrix, m.count == 16 {
            written = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                              SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
            return
        }
        if let t = node.translation, t.count == 3 { translation = SIMD3(t[0], t[1], t[2]) }
        if let r = node.rotation, r.count == 4 { rotation = simd_normalize(simd_quatf(vector: SIMD4(r[0], r[1], r[2], r[3]))) }
        if let s = node.scale, s.count == 3 { scale = SIMD3(s[0], s[1], s[2]) }
    }

    var matrix: simd_float4x4 {
        if let written { return written }
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(translation, 1)
        return m
    }
}

// MARK: The schema

/// As much of glTF 2.0's JSON as is read here. Everything else in a file is ignored by the decoder.
private nonisolated struct Document: Decodable {
    let asset: Asset
    let extensionsRequired: [String]?
    let scene: Int?
    let scenes: [Scene]?
    let nodes: [Node]?
    let meshes: [Mesh]?
    let materials: [Material]?
    let textures: [Texture]?
    let samplers: [Sampler]?
    let images: [Image]?
    let skins: [Skin]?
    let accessors: [Accessor]?
    let bufferViews: [BufferView]?
    let buffers: [Buffer]?

    struct Asset: Decodable { let version: String }
    struct Scene: Decodable { let nodes: [Int]? }
    struct Node: Decodable {
        let name: String?
        let children: [Int]?
        let mesh: Int?
        let skin: Int?
        let matrix: [Float]?
        let translation: [Float]?
        let rotation: [Float]?
        let scale: [Float]?
    }
    struct Mesh: Decodable {
        let name: String?
        let primitives: [Primitive]
    }
    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let material: Int?
        let mode: Int?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let draco: Draco?
            enum CodingKeys: String, CodingKey { case draco = "KHR_draco_mesh_compression" }
        }
        /// The buffer view holding the compressed mesh, and each glTF attribute's Draco unique id.
        struct Draco: Decodable {
            let bufferView: Int
            let attributes: [String: UInt32]
        }
    }
    struct Material: Decodable {
        let name: String?
        let pbrMetallicRoughness: PBR?
        let normalTexture: TextureInfo?
        let occlusionTexture: TextureInfo?
        let emissiveTexture: TextureInfo?
        let emissiveFactor: [Float]?
        let alphaMode: String?
        let alphaCutoff: Float?
        let doubleSided: Bool?
        let extensions: Extensions?

        struct PBR: Decodable {
            let baseColorFactor: [Float]?
            let baseColorTexture: TextureInfo?
            let metallicFactor: Float?
            let roughnessFactor: Float?
            let metallicRoughnessTexture: TextureInfo?
        }
        struct Extensions: Decodable {
            let emissiveStrength: EmissiveStrength?
            enum CodingKeys: String, CodingKey { case emissiveStrength = "KHR_materials_emissive_strength" }
            struct EmissiveStrength: Decodable { let emissiveStrength: Float? }
        }
    }
    /// A texture as a material names it. `scale` is a normal map's, `strength` an occlusion map's.
    struct TextureInfo: Decodable {
        let index: Int
        let texCoord: Int?
        let scale: Float?
        let strength: Float?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let transform: Transform?
            enum CodingKeys: String, CodingKey { case transform = "KHR_texture_transform" }
        }
        struct Transform: Decodable {
            let offset: [Float]?
            let rotation: Float?
            let scale: [Float]?
            let texCoord: Int?
        }
    }
    struct Texture: Decodable {
        let source: Int?
        let sampler: Int?
        let extensions: Extensions?
        struct Extensions: Decodable {
            let webp: Source?
            /// A KTX2 image with Basis Universal data, preferred over any PNG or JPEG fallback beside it.
            let basisu: Source?
            enum CodingKeys: String, CodingKey { case webp = "EXT_texture_webp", basisu = "KHR_texture_basisu" }
            struct Source: Decodable { let source: Int? }
        }
    }
    struct Sampler: Decodable { let magFilter: Int?; let minFilter: Int?; let wrapS: Int?; let wrapT: Int? }
    struct Image: Decodable { let uri: String?; let bufferView: Int?; let mimeType: String?; let name: String? }
    struct Skin: Decodable { let inverseBindMatrices: Int?; let joints: [Int] }
    struct Accessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let normalized: Bool?
        let count: Int
        let type: String
        let sparse: Sparse?

        struct Sparse: Decodable {
            let count: Int
            let indices: Indices
            let values: Values
            struct Indices: Decodable { let bufferView: Int; let byteOffset: Int?; let componentType: Int }
            struct Values: Decodable { let bufferView: Int; let byteOffset: Int? }
        }

        static let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]

        var componentSize: Int {
            switch componentType {
            case 5120, 5121: 1
            case 5122, 5123: 2
            default: 4
            }
        }
    }
    struct BufferView: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
        let extensions: Extensions?

        struct Extensions: Decodable {
            let ext: Meshopt?
            let khr: Meshopt?
            /// Either name: the Khronos extension is the EXT one with a newer attribute encoding, which
            /// the decoder reads by its header byte.
            var meshopt: Meshopt? { khr ?? ext }
            enum CodingKeys: String, CodingKey {
                case ext = "EXT_meshopt_compression", khr = "KHR_meshopt_compression"
            }
        }
        struct Meshopt: Decodable {
            let buffer: Int
            let byteOffset: Int?
            let byteLength: Int
            let byteStride: Int
            let count: Int
            let mode: String
            let filter: String?
        }
    }
    struct Buffer: Decodable { let uri: String?; let byteLength: Int }
}

private extension Data {
    nonisolated func word(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
