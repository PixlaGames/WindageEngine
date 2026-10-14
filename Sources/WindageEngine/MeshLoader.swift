//
//  MeshLoader.swift
//  WindageEngine
//

import Metal
import MetalKit
import ModelIO

public enum MeshLoaderError: Error, CustomStringConvertible, Sendable {
    /// No file by that name in the bundle, or none at that URL.
    case assetNotFound(String)
    /// The file was read and holds no meshes.
    case noMeshes(String)
    /// The vertex descriptor could not be turned into Model I/O's, so nothing could be laid out by it.
    case unusableVertexDescriptor(String)
    /// Model I/O or Metal failed turning the file's meshes into buffers; the underlying error says why.
    case conversionFailed(String, underlying: any Error)

    public var description: String {
        switch self {
        case .assetNotFound(let name): "no mesh file \(name)"
        case .noMeshes(let name): "\(name) loaded but contains no meshes"
        case .unusableVertexDescriptor(let name):
            "\(name): the vertex descriptor has no attributes Model I/O can lay a mesh out by"
        case .conversionFailed(let name, let underlying): "\(name) could not be made into meshes — \(underlying)"
        }
    }
}

/// Loads geometry from disk.
///
/// **This is the piece an engine would have given us.** With no importer, the format choice is a
/// real constraint rather than a preference: Model I/O reads USD, USDZ, OBJ, PLY, STL and Alembic
/// natively, and anything outside that list — FBX above all — becomes a parser this project owns.
/// Prefer USD for anything with materials or hierarchy; OBJ is fine for placeholder geometry.
public nonisolated enum MeshLoader {

    /// Loads every mesh in a file, laid out to match the render pipeline's vertex descriptor.
    ///
    /// The descriptor is passed in rather than rebuilt here because it must be *identical* to the
    /// one the pipeline was compiled against. Model I/O will happily convert a file's own layout to
    /// whatever it is handed, so a mismatch does not fail loudly — it draws garbage.
    /// - Parameter semantics: attribute index to Model I/O semantic name, e.g.
    ///   `[0: MDLVertexAttributePosition, 1: MDLVertexAttributeTextureCoordinate]`. The game owns
    ///   these indices, because they are a contract between its shaders and its vertex descriptor —
    ///   the engine has no business guessing them.
    /// - Parameter fileExtension: the file's extension, without the dot — `"usda"`, `"usdz"`, `"obj"`.
    ///   No default: the extension is the format, and USD is preferred over OBJ, so it is named.
    public static func load(
        named name: String,
        withExtension fileExtension: String,
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor,
        semantics: [Int: String],
        bundle: Bundle = .main,
        reportingTo report: ((String) -> Void)? = nil
    ) throws -> [LoadedMesh] {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw MeshLoaderError.assetNotFound("\(name).\(fileExtension)")
        }
        return try load(url: url, device: device, vertexDescriptor: vertexDescriptor,
                        semantics: semantics, reportingTo: report)
    }

    /// The same, from a file anywhere on disk.
    ///
    /// **An engine that can only load from its own bundle cannot load anything a person chose.** A
    /// level editor opening a mesh, a mod, a character sitting in a pipeline's output folder — all of
    /// them are a URL and none of them is a bundle resource. The bundle call above is the convenience;
    /// this is the one that does the work.
    public static func load(
        url: URL,
        device: MTLDevice,
        vertexDescriptor: MTLVertexDescriptor,
        semantics: [Int: String],
        reportingTo report: ((String) -> Void)? = nil
    ) throws -> [LoadedMesh] {
        let name = url.lastPathComponent

        let modelDescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)

        // Model I/O needs the attributes *named*, not merely positioned. Without this it cannot
        // tell which incoming attribute is a position and which is a normal, and the conversion
        // silently produces zeroes — which renders as an unlit black scene, with nothing thrown and
        // nothing logged. Naming every attribute the descriptor declares is not optional.
        guard let attributes = modelDescriptor.attributes as? [MDLVertexAttribute] else {
            throw MeshLoaderError.unusableVertexDescriptor(name)
        }
        for (index, semantic) in semantics {
            attributes[index].name = semantic
        }

        // **Said here, rather than as "no meshes".** Model I/O opens a file that is not there as an empty
        // asset, and an empty asset is indistinguishable from a file with nothing in it.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MeshLoaderError.assetNotFound(url.path)
        }

        let allocator = MTKMeshBufferAllocator(device: device)

        // **Loaded without the descriptor, then given it.** Handing the descriptor to `MDLAsset` at
        // load converts the file to that layout immediately — and a tangent attribute the file does
        // not have is filled with zeroes, which is a degenerate basis rather than a missing one.
        // Tangents have to be generated while the mesh still has its own layout, so the descriptor is
        // applied afterwards.
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()

        let wantsTangents = semantics.values.contains(MDLVertexAttributeTangent)
        for mesh in allMeshes(in: asset) {
            if wantsTangents { addTangentsIfNeeded(to: mesh, named: name, reportingTo: report) }
            mesh.vertexDescriptor = modelDescriptor
        }

        let modelMeshes: [MDLMesh], metalMeshes: [MTKMesh]
        do {
            (modelMeshes, metalMeshes) = try MTKMesh.newMeshes(asset: asset, device: device)
        } catch {
            throw MeshLoaderError.conversionFailed(name, underlying: error)
        }
        guard !metalMeshes.isEmpty else { throw MeshLoaderError.noMeshes(name) }

        let transforms = nodeTransforms(in: asset)

        // Bounds and materials come from the Model I/O mesh, which still knows them — `MTKMesh`
        // carries neither, and recomputing bounds from the vertex buffers afterwards means reading
        // GPU memory back.
        return zip(metalMeshes, modelMeshes).map { metal, model in
            let box = model.boundingBox
            return LoadedMesh(
                mesh: metal,
                bounds: BoundingBox(minimum: SIMD3(box.minBounds.x, box.minBounds.y, box.minBounds.z),
                                    maximum: SIMD3(box.maxBounds.x, box.maxBounds.y, box.maxBounds.z)),
                materials: materials(of: model, count: metal.submeshes.count),
                nodeTransform: transforms[ObjectIdentifier(model)] ?? matrix_identity_float4x4)
        }
    }

    /// A tangent basis, generated when the pipeline wants one and the file did not bring it.
    ///
    /// ### What a tangent is for, and why it cannot be guessed in the shader
    ///
    /// A normal map stores directions in **tangent space** — relative to the surface, so the same map
    /// can be used on a wall and on a barrel. Getting back to world space needs the surface's own
    /// axes: the normal, and a **tangent** aligned with the texture's u direction. The tangent
    /// depends on how the texture was laid out across the triangle, which is information only the
    /// mesh has; a shader can only approximate it from screen-space derivatives, and the
    /// approximation breaks down exactly where mapping is tightest.
    ///
    /// **The `w` component is handedness, ±1**, and it is not optional: a UV island mirrored across
    /// the model — which is most characters, whose two halves share one texture — has its bitangent
    /// the other way round. Drop `w` and every mirrored surface is lit as though the light were on
    /// the wrong side.
    ///
    /// **Generated rather than required**, because Model I/O's importers rarely bring tangents even
    /// when the source format had them. A file that *does* supply one is left alone.
    private static func addTangentsIfNeeded(to mesh: MDLMesh,
                                            named name: String,
                                            reportingTo report: ((String) -> Void)?) {
        let attributes = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute] ?? [])
            .filter { $0.format != .invalid }
        let names = Set(attributes.map(\.name))
        guard !names.contains(MDLVertexAttributeTangent) else { return }

        // **Both are needed, and neither can be invented.** `addOrthTanBasis` derives the tangent
        // from the texture layout against the normals; without normals there is no surface to be
        // tangent to, and without texture coordinates there is no u direction to align with.
        guard names.contains(MDLVertexAttributeNormal),
              names.contains(MDLVertexAttributeTextureCoordinate) else {
            report?("\(name): no tangents — the mesh has "
                    + (names.contains(MDLVertexAttributeNormal) ? "no texture coordinates" : "no normals"))
            return
        }
        mesh.addOrthTanBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                             normalAttributeNamed: MDLVertexAttributeNormal,
                             tangentAttributeNamed: MDLVertexAttributeTangent)
    }

    private static func allMeshes(in asset: MDLAsset) -> [MDLMesh] {
        var result: [MDLMesh] = []
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh { result.append(mesh) }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }
        return result
    }

    /// Every mesh's place in the file's node hierarchy, composed from the root.
    ///
    /// ### The transform is not decoration, and ignoring it is how an asset comes in wrong
    ///
    /// **This loader ignored it until 2026-09-09, and a real character is what showed it.** A
    /// character out of a game engine, through an FBX, through Blender arrives with its mesh data in
    /// **centimeters** and a **scale of 0.01 on a parent node** — 176 units tall in its own space and
    /// 1.76 m in the world. Read the mesh's bounds alone and it is a hundred times too big, and the
    /// file looks wrong when it is not.
    ///
    /// It is the same shape of correction as ``AssetOrientation``: one matrix in front of the model
    /// matrix, which is enough because skinning happens in model space, so the mesh, the rig and the
    /// animation are all corrected together.
    ///
    /// **Keyed by object identity rather than by traversal order.** `MTKMesh.newMeshes` walks the
    /// asset the same way this does, so zipping would work today — and would break silently the day
    /// it does not, by putting one mesh's transform on another's geometry.
    static func nodeTransforms(in asset: MDLAsset) -> [ObjectIdentifier: simd_float4x4] {
        var result: [ObjectIdentifier: simd_float4x4] = [:]
        func descend(_ object: MDLObject, _ parent: simd_float4x4) {
            let world = object.transform.map { parent * $0.matrix } ?? parent
            if let mesh = object as? MDLMesh { result[ObjectIdentifier(mesh)] = world }
            for child in object.children.objects { descend(child, world) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index), matrix_identity_float4x4) }
        return result
    }

    /// One material per submesh, in the submeshes' own order.
    ///
    /// **Padded to the submesh count rather than trusted to match.** `MTKMesh` and `MDLMesh` agree
    /// on submesh order, but a file can leave a submesh unbound, and a materials array shorter than
    /// the submeshes it indexes is an out-of-bounds crash at draw time — in a loop that has nothing
    /// to do with loading. A default material draws.
    static func materials(of mesh: MDLMesh, count: Int) -> [Material] {
        let declared = (mesh.submeshes as? [MDLSubmesh] ?? []).map { submesh in
            submesh.material.map { Material($0) } ?? Material(name: submesh.name)
        }
        guard declared.count < count else { return Array(declared.prefix(count)) }
        return declared + Array(repeating: Material(), count: count - declared.count)
    }
}

/// A mesh, the box that contains it in its own space, and what its surfaces are made of.
///
/// **`Sendable`, unchecked, so a mesh loaded on a worker can be handed to the main actor.** Every field
/// is a `let`, and the one that is not a value — the `MTKMesh` — is made by ``MeshLoader`` and never
/// changed by the engine afterwards; its buffers are `MTLBuffer`s, which Metal makes safe to share.
/// What a game must not do is change the `MTKMesh` (its name, its vertex descriptor) from two threads.
public nonisolated struct LoadedMesh: @unchecked Sendable {
    public let mesh: MTKMesh
    public let bounds: BoundingBox

    /// One per submesh, in the same order — so `materials[i]` describes `mesh.submeshes[i]`.
    ///
    /// **A file's materials, not a game's.** What they mean to a shader is the game's business;
    /// carrying them at all is the difference between a bought asset arriving intact and arriving
    /// as untextured geometry with its surfaces thrown away on import.
    public let materials: [Material]

    /// Where this mesh sits in the file's own node hierarchy, composed from the root.
    ///
    /// **Apply it in front of the model matrix: `model * nodeTransform`.** It is usually the identity
    /// for a hand-written mesh and almost never for an exported one — a character out of an FBX
    /// pipeline has its geometry in centimeters under a parent scaled by 0.01. ``bounds`` is in the
    /// mesh's own space, so it needs the same treatment before it means anything in the world.
    public let nodeTransform: simd_float4x4

    public init(mesh: MTKMesh,
                bounds: BoundingBox,
                materials: [Material] = [],
                nodeTransform: simd_float4x4 = matrix_identity_float4x4) {
        self.mesh = mesh
        self.bounds = bounds
        self.materials = materials
        self.nodeTransform = nodeTransform
    }

    /// The material for a submesh, or a default if the file named none.
    public func material(forSubmesh index: Int) -> Material {
        materials.indices.contains(index) ? materials[index] : Material()
    }
}

/// One thing to draw: a mesh and where it sits.
///
/// Deliberately a flat list rather than a scene graph. A hierarchy earns its place when something
/// actually needs to be parented — a scope to a rifle, a rifle to a pair of hands — and inventing
/// one before then is an engine feature with no game behind it.
///
/// `Sendable` for the reason ``LoadedMesh`` is.
public nonisolated struct SceneObject: @unchecked Sendable {
    public let mesh: MTKMesh

    /// Where it is and how big it is — the half of this that a round cares about.
    ///
    /// **Held as a ``Volume`` rather than as its own bounds, so that half can travel without the
    /// mesh.** Everything that asks "what is out there" — ranging a target, tracing a round — goes
    /// through volumes, and a thing with no GPU mesh is as hittable as a thing with one.
    public let volume: Volume

    public var transform: simd_float4x4 { volume.transform }
    public var worldBounds: BoundingBox { volume.worldBounds }

    /// **The mesh's node transform is composed in**, so a placement means the same thing whether the
    /// geometry came from a hand-written OBJ at the origin or from an exported character in
    /// centimeters under a scaled parent.
    public init(loaded: LoadedMesh, transform: simd_float4x4) {
        self.mesh = loaded.mesh
        self.volume = Volume(localBounds: loaded.bounds, transform: transform * loaded.nodeTransform)
    }
}
