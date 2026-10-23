//
//  MeshLoader+Imported.swift
//  WindageEngine
//

import CryptoKit
import Foundation
import MetalKit
import ModelIO
import simd

/// An ``ImportedModel`` handed to Model I/O, so a format the engine reads itself takes the same path from there
/// as one Model I/O reads: tangents, the game's vertex layout, bounds and materials.
///
/// ### Made to come out as the same model in USD would
///
/// - **Texture coordinates are turned v-up** (`v → 1 − v`), the convention of everything Model I/O imports,
///   so ``TextureStore``'s default ``TextureOrigin/bottomLeft`` puts a glTF texture the same way up as the same
///   model's texture from USD. Passing ``TextureOrigin/topLeft`` for glTF instead would mean every game knowing
///   which format each mesh came from.
/// - **KHR_texture_transform is baked into the coordinates**, because ``Material`` has nowhere to carry it and
///   a shader would have to know about it. A vertex shared by two submeshes whose textures are moved
///   differently is copied, one per submesh.
/// - **Images become files**, because a ``Material`` names its textures by URL — that is what keeps it a
///   cheap, comparable value and what ``TextureStore`` caches on. An image inside a `.glb`, in a data URI, or in
///   a format `MTKTextureLoader` does not read (KTX2, WebP) is written once to the app's temporary folder, named
///   by its contents so loading the same file twice writes nothing; a PNG or JPEG keeps its own bytes. Inside
///   the container, so a sandboxed game is unaffected.
/// - **glTF's factors are kept with their textures.** glTF multiplies a texture by its factor; Model I/O,
///   reading USD, gives a textured slot the identity instead, because USD's preview surface has no such factor.
///   For glTF the factor is known, so it is restored — a metallic-roughness map under a metallic factor of 0 is
///   not metal.
/// - **Normals are made from the faces when the file has none**, weighted by area.
///
/// What ``Material`` cannot say is left out here and kept in the ``ImportedModel``: alpha mode and cutoff,
/// double-sidedness, a normal map's scale, occlusion strength, wrapping and filtering.
nonisolated extension MeshLoader {

    static func makeAsset(_ model: ImportedModel, allocator: MDLMeshBufferAllocator,
                          reportingTo report: ((String) -> Void)?)
        -> (asset: MDLAsset, materials: [ObjectIdentifier: [ImportedMaterial?]]) {
        let asset = MDLAsset(bufferAllocator: allocator)
        var files: [ObjectIdentifier: URL?] = [:]
        func file(for texture: ImportedTexture) -> URL? {
            if let known = files[ObjectIdentifier(texture)] { return known }
            let made = textureFile(texture)
            if made == nil { report?("the image \(texture.name) could not be written for loading") }
            files[ObjectIdentifier(texture)] = made
            return made
        }
        let modelMaterials = model.materials.map { makeMaterial($0, file: file) }
        var importedMaterials: [ObjectIdentifier: [ImportedMaterial?]] = [:]

        for mesh in model.meshes {
            let count = mesh.positions.count
            guard count > 0, !mesh.submeshes.isEmpty,
                  mesh.submeshes.allSatisfy({ $0.indices.allSatisfy { Int($0) < count } }) else { continue }
            let normals = mesh.normals.count == count
                ? mesh.normals : ImportedMesh.smoothNormals(mesh.positions, mesh.submeshes.flatMap(\.indices))
            let drawn = drawnVertices(mesh, materials: model.materials)

            let descriptor = MDLVertexDescriptor()
            var buffers: [MDLMeshBuffer] = []
            func add(_ name: String, _ format: MDLVertexFormat, _ floats: [Float], width: Int) {
                let index = buffers.count
                descriptor.addOrReplaceAttribute(MDLVertexAttribute(name: name, format: format, offset: 0,
                                                                    bufferIndex: index))
                descriptor.layouts[index] = MDLVertexBufferLayout(stride: width * MemoryLayout<Float>.size)
                buffers.append(floats.withUnsafeBytes { allocator.newBuffer(with: Data($0), type: .vertex) })
            }
            // Packed by hand: a `SIMD3<Float>` is sixteen bytes in Swift, and the layouts say twelve.
            add(MDLVertexAttributePosition, .float3,
                drawn.source.flatMap { let p = mesh.positions[$0]; return [p.x, p.y, p.z] }, width: 3)
            add(MDLVertexAttributeNormal, .float3,
                drawn.source.flatMap { let n = normals[$0]; return [n.x, n.y, n.z] }, width: 3)
            if !drawn.uvs.isEmpty {
                add(MDLVertexAttributeTextureCoordinate, .float2, drawn.uvs.flatMap { [$0.x, $0.y] }, width: 2)
            }
            if mesh.colors.count == count {
                add(MDLVertexAttributeColor, .float4,
                    drawn.source.flatMap { let c = mesh.colors[$0]; return [c.x, c.y, c.z, c.w] }, width: 4)
            }

            let submeshes = zip(mesh.submeshes, drawn.indices).map { submesh, indices in
                MDLSubmesh(name: submesh.material.map { model.materials[$0].name } ?? "",
                           indexBuffer: indices.withUnsafeBytes { allocator.newBuffer(with: Data($0), type: .index) },
                           indexCount: indices.count, indexType: .uInt32, geometryType: .triangles,
                           material: submesh.material.map { modelMaterials[$0] })
            }
            let made = MDLMesh(vertexBuffers: buffers, vertexCount: drawn.source.count, descriptor: descriptor,
                               submeshes: submeshes)
            made.name = mesh.name
            // Read back by `nodeTransforms(in:)`, as a USD node's would be.
            made.transform = MDLTransform(matrix: mesh.transform)
            asset.add(made)
            importedMaterials[ObjectIdentifier(made)] = mesh.submeshes.map { $0.material.map { model.materials[$0] } }
        }
        return (asset, importedMaterials)
    }

    /// The vertices as drawn: which imported vertex each one is, its texture coordinates moved by its submesh's
    /// texture transform and turned v-up, and each submesh's indices into them.
    static func drawnVertices(_ mesh: ImportedMesh, materials: [ImportedMaterial])
        -> (source: [Int], uvs: [SIMD2<Float>], indices: [[UInt32]]) {
        let count = mesh.positions.count
        guard mesh.uvs.count == count else { return (Array(0..<count), [], mesh.submeshes.map(\.indices)) }

        // One transform per submesh: its base color's, or failing that the first texture it has. glTF lets
        // each texture move on its own; one set of coordinates cannot, and the base color is what shows.
        func transform(_ submesh: ImportedSubmesh) -> simd_float3x3 {
            guard let material = submesh.material.flatMap({ materials.indices.contains($0) ? materials[$0] : nil })
            else { return matrix_identity_float3x3 }
            return [material.baseColorTexture, material.metallicRoughnessTexture, material.normalTexture,
                    material.occlusionTexture, material.emissiveTexture].lazy.compactMap { $0 }.first?.transform
                ?? matrix_identity_float3x3
        }
        var source = Array(0..<count)
        var groups: [simd_float3x3] = []
        var owner = [Int?](repeating: nil, count: count)
        var copies: [Int: [Int: UInt32]] = [:]
        let indices = mesh.submeshes.map { submesh -> [UInt32] in
            let t = transform(submesh)
            let group = groups.firstIndex(of: t) ?? { groups.append(t); return groups.count - 1 }()
            return submesh.indices.map { index in
                let vertex = Int(index)
                if owner[vertex] == nil { owner[vertex] = group }
                if owner[vertex] == group { return index }
                if let copy = copies[vertex]?[group] { return copy }
                let copy = UInt32(source.count)
                source.append(vertex)
                owner.append(group)
                copies[vertex, default: [:]][group] = copy
                return copy
            }
        }
        let uvs = source.indices.map { k -> SIMD2<Float> in
            let uv = mesh.uvs[source[k]]
            let moved = owner[k].map { groups[$0] * SIMD3(uv, 1) } ?? SIMD3(uv, 1)
            return SIMD2(moved.x, 1 - moved.y)
        }
        return (source, uvs, indices)
    }

    /// A Model I/O material that ``Material/init(_:name:)`` reads as it reads a USD preview surface's.
    ///
    /// **Built on the plain scattering function, not the physically plausible one**: the latter arrives with a
    /// Disney parameter set already filled in, and every property set here would have to win against it.
    /// `setProperty` replaces by name, so each one set here is the only one carrying its semantic.
    static func makeMaterial(_ m: ImportedMaterial, file: (ImportedTexture) -> URL?) -> MDLMaterial {
        let material = MDLMaterial(name: m.name, scatteringFunction: MDLScatteringFunction())
        func url(_ reference: ImportedTextureReference?) -> URL? { reference.flatMap { file($0.texture) } }

        if let map = url(m.baseColorTexture) {
            material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, url: map))
        } else {
            material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float4: m.baseColor))
        }
        material.setProperty(MDLMaterialProperty(name: "opacity", semantic: .opacity, float: m.baseColor.w))
        // Both read from the one packed map, roughness in green and metalness in blue — `TextureSlot`'s
        // `packedChannel`, which is glTF's packing.
        if let map = url(m.metallicRoughnessTexture) {
            material.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, url: map))
            material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, url: map))
        } else {
            material.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, float: m.metallic))
            material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: m.roughness))
        }
        if let map = url(m.emissiveTexture) {
            material.setProperty(MDLMaterialProperty(name: "emission", semantic: .emission, url: map))
        } else {
            material.setProperty(MDLMaterialProperty(name: "emission", semantic: .emission, float3: m.emissive))
        }
        if let map = url(m.normalTexture) {
            material.setProperty(MDLMaterialProperty(name: "normal", semantic: .tangentSpaceNormal, url: map))
        }
        if let map = url(m.occlusionTexture) {
            material.setProperty(MDLMaterialProperty(name: "ambientOcclusion", semantic: .ambientOcclusion, url: map))
        }
        return material
    }

    /// The materials Model I/O's gave, with glTF's factors put back beside their textures — see above.
    static func withFactors(_ materials: [Material], from imported: [ImportedMaterial?]) -> [Material] {
        materials.enumerated().map { index, material in
            guard let source = imported.indices.contains(index) ? imported[index] : nil else { return material }
            var restored = material
            restored.baseColor = source.baseColor
            restored.metallic = source.metallic
            restored.roughness = source.roughness
            restored.emissive = source.emissive
            return restored
        }
    }

    /// The image as a file `MTKTextureLoader` reads, in the temporary folder, named by its contents.
    static func textureFile(_ texture: ImportedTexture) -> URL? {
        guard let (data, fileExtension) = texture.portableData() else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.temporaryDirectory.appending(path: "WindageEngine-textures",
                                                                       directoryHint: .isDirectory)
        let file = folder.appending(path: "\(digest).\(fileExtension)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}

nonisolated extension ImportedMesh {
    /// Normals made from the faces, each vertex's the area-weighted average of the triangles that use it. Up,
    /// for a vertex no triangle uses.
    static func smoothNormals(_ positions: [SIMD3<Float>], _ indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        return normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }
}
