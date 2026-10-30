//
//  SkinnedModel.swift
//  WindageEngine
//

import Foundation
import Metal
import MetalKit
import ModelIO
import simd

public nonisolated enum SkinnedModelError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No file at that URL.
    case assetNotFound(String)
    /// The file holds no mesh with joint indices and weights.
    case noSkinnedMeshes(String)
    /// The game's vertex layout has no position, or holds one or a normal in a format this does not write.
    case unsupportedLayout(String)
    /// A vertex names a joint the skeleton does not have.
    case jointOutOfRange(file: String, joint: Int, jointCount: Int)
    /// Metal would not make a buffer, a mesh or a pipeline; the text says which.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .assetNotFound(let name): "no character file \(name)"
        case .noSkinnedMeshes(let name): "\(name) has no skinned mesh — nothing in it carries joints and weights"
        case .unsupportedLayout(let why): "the vertex layout cannot be skinned into: \(why)"
        case .jointOutOfRange(let file, let joint, let count):
            "\(file): a vertex is weighted to joint \(joint), and the skeleton has \(count)"
        case .couldNotCreate(let what): "could not create \(what)"
        }
    }
}

/// A character's geometry at rest, every skinned mesh in its file merged into one, read with no GPU.
///
/// ### One mesh, not one per part
///
/// **A character creator exports every part as its own skinned mesh** — a body, a head, hair, each piece of armour:
/// 33 of them for one armoured knight. Drawn as they come that is 33 draws per pass per character, every one of them
/// skinned again in every shadow cascade. Merged, it is one vertex buffer and a draw per *material*, which for a
/// palette-textured character is one.
///
/// **Triangles are grouped by what their material is, not by what it is called.** A character creator's parts each
/// bring their own material — 29 for one knight, `lambert178`, `COLOR4` and the rest — that are the same surface: one
/// palette texture, the same factors. Grouped by name that was 29 draws; by content it is one.
///
/// ### Skeleton space, not node space
///
/// The vertices are left where the file authored them, which for a skinned mesh is the space its geometry bind
/// transform carries into the skeleton's — ``RigLoader`` folds that transform into the inverse bind matrices — so a
/// posed vertex is in the skeleton's own space. The skeleton's place in the file is ``Rig/nodeTransform``, applied in
/// front of the model matrix like any loaded mesh's.
public nonisolated struct SkinnedGeometry: Sendable {

    /// One run of triangles sharing a material.
    public struct Part: Sendable {
        /// Into the merged vertices.
        public let indices: [UInt32]
        public let material: Material
    }

    public let vertexCount: Int
    /// How many of the file's meshes were merged.
    public let meshCount: Int

    /// The merged vertices in the game's own layout: per Model I/O layout of the game's descriptor (the same index a
    /// mesh's `vertexBuffers` uses), its stride and bytes. Layouts the descriptor does not use are absent.
    public let layouts: [Int: (stride: Int, bytes: Data)]

    /// What skinning reads, in plain arrays: the rest positions and normals, the four influences per vertex, and
    /// tangents with their handedness when the game's layout carries tangents.
    public let restPositions: [SIMD3<Float>]
    public let restNormals: [SIMD3<Float>]
    public let restTangents: [SIMD4<Float>]?
    public let joints: [SIMD4<UInt16>]
    /// Each vertex's four weights, summing to one.
    public let weights: [SIMD4<Float>]

    public let parts: [Part]

    /// The merged vertices' bounds at rest, in skeleton space.
    public let bounds: BoundingBox

    /// Where position, normal and tangent sit in the game's layout: (Model I/O layout, byte offset), and whether the
    /// tangent is four floats.
    let position: (layout: Int, offset: Int)
    let normal: (layout: Int, offset: Int)?
    let tangent: (layout: Int, offset: Int, hasHandedness: Bool)?

    /// Reads every skinned mesh in a USD file, laid out by the game's vertex descriptor.
    ///
    /// - Parameters:
    ///   - vertexDescriptor: the game's **static** layout — the one its ordinary pipeline draws with. The posed
    ///     character is drawn by that pipeline, so the layout carries no joints and no weights; those are read
    ///     separately, for ``SkinningPass``.
    ///   - semantics: attribute index to Model I/O semantic, as for ``MeshLoader``. Position is required, and must
    ///     be `float3`; a normal, if there is one, too; a tangent may be `float3` or `float4`.
    ///   - skeletonJointCount: the rig's joints, to check every influence against. ``SkinnedModel`` passes its rig's.
    public static func read(url: URL, vertexDescriptor: MTLVertexDescriptor, semantics: [Int: String],
                            skeletonJointCount: Int) throws -> SkinnedGeometry {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { throw SkinnedModelError.assetNotFound(url.path) }
        let modelDescriptor: MDLVertexDescriptor
        do {
            modelDescriptor = try MeshLoader.namedDescriptor(vertexDescriptor, semantics: semantics, file: name)
        } catch {
            throw SkinnedModelError.unsupportedLayout("no attributes")
        }
        let attributes = (modelDescriptor.attributes as? [MDLVertexAttribute] ?? []).filter { $0.format != .invalid }
        func find(_ semantic: String) -> MDLVertexAttribute? { attributes.first { $0.name == semantic } }
        guard let positionAttribute = find(MDLVertexAttributePosition), positionAttribute.format == .float3 else {
            throw SkinnedModelError.unsupportedLayout("no float3 position")
        }
        let normalAttribute = find(MDLVertexAttributeNormal)
        if let normalAttribute, normalAttribute.format != .float3 {
            throw SkinnedModelError.unsupportedLayout("the normal is not float3")
        }
        let tangentAttribute = find(MDLVertexAttributeTangent)
        if let tangentAttribute, tangentAttribute.format != .float3, tangentAttribute.format != .float4 {
            throw SkinnedModelError.unsupportedLayout("the tangent is neither float3 nor float4")
        }
        let layoutStrides: [Int: Int] = Dictionary(uniqueKeysWithValues: (modelDescriptor.layouts as? [MDLVertexBufferLayout] ?? [])
            .enumerated().filter { $0.element.stride > 0 }.map { ($0.offset, $0.element.stride) })

        // **The game's layout plus one of skinning's own**, so a single conversion lays out both. Model I/O converts
        // the file's joint indices to four unsigned shorts and pads a vertex with fewer influences with joint 0 at
        // weight 0, which contributes nothing.
        let reading = modelDescriptor.copy() as! MDLVertexDescriptor
        let skinLayout = (reading.layouts as? [MDLVertexBufferLayout] ?? []).count
        reading.attributes.add(MDLVertexAttribute(name: MDLVertexAttributeJointIndices, format: .uShort4,
                                                  offset: 0, bufferIndex: skinLayout))
        reading.attributes.add(MDLVertexAttribute(name: MDLVertexAttributeJointWeights, format: .float4,
                                                  offset: 8, bufferIndex: skinLayout))
        reading.layouts.add(MDLVertexBufferLayout(stride: 24))

        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: MDLMeshBufferDataAllocator())
        let meshes = allMeshes(in: asset).filter { mesh in
            (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute] ?? [])
                .contains { $0.name == MDLVertexAttributeJointIndices && $0.format != .invalid }
        }
        guard !meshes.isEmpty else { throw SkinnedModelError.noSkinnedMeshes(name) }

        var layouts: [Int: Data] = Dictionary(uniqueKeysWithValues: layoutStrides.keys.map { ($0, Data()) })
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], tangents: [SIMD4<Float>] = []
        var joints: [SIMD4<UInt16>] = [], weights: [SIMD4<Float>] = []
        var groups: [(indices: [UInt32], material: Material)] = []

        for mesh in meshes {
            if tangentAttribute != nil {
                mesh.addOrthTanBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                     normalAttributeNamed: MDLVertexAttributeNormal,
                                     tangentAttributeNamed: MDLVertexAttributeTangent)
            }
            mesh.vertexDescriptor = reading
            let base = UInt32(positions.count)
            let count = mesh.vertexCount

            for (layout, stride) in layoutStrides {
                guard layout < mesh.vertexBuffers.count else { continue }
                let map = mesh.vertexBuffers[layout].map()
                layouts[layout]?.append(Data(bytes: map.bytes, count: count * stride))
                withExtendedLifetime(map) {}
            }
            func floats<T>(_ attribute: MDLVertexAttribute, as: T.Type) -> [T] {
                let stride = layoutStrides[attribute.bufferIndex] ?? 0
                let map = mesh.vertexBuffers[attribute.bufferIndex].map()
                defer { withExtendedLifetime(map) {} }
                return (0..<count).map { map.bytes.advanced(by: $0 * stride + attribute.offset).loadUnaligned(as: T.self) }
            }
            func float3s(_ attribute: MDLVertexAttribute) -> [SIMD3<Float>] {
                floats(attribute, as: (Float, Float, Float).self).map { SIMD3($0.0, $0.1, $0.2) }
            }
            positions += float3s(positionAttribute)
            normals += normalAttribute.map(float3s) ?? Array(repeating: SIMD3(0, 1, 0), count: count)
            if let tangentAttribute {
                if tangentAttribute.format == .float4 {
                    tangents += floats(tangentAttribute, as: (Float, Float, Float, Float).self).map { SIMD4($0.0, $0.1, $0.2, $0.3) }
                } else {
                    tangents += float3s(tangentAttribute).map { SIMD4($0, 1) }
                }
            }

            let skin = mesh.vertexBuffers[skinLayout].map()
            for vertex in 0..<count {
                let at = skin.bytes.advanced(by: vertex * 24)
                let j = at.loadUnaligned(as: SIMD4<UInt16>.self)
                var w = at.advanced(by: 8).loadUnaligned(as: SIMD4<Float>.self)
                for lane in 0..<4 where w[lane] > 0 && Int(j[lane]) >= skeletonJointCount {
                    throw SkinnedModelError.jointOutOfRange(file: name, joint: Int(j[lane]), jointCount: skeletonJointCount)
                }
                // **Weights that do not sum to one scale the vertex toward the skeleton's origin**, so they are
                // made to; a vertex weighted to nothing follows the first joint rather than collapsing to the origin.
                let sum = w.x + w.y + w.z + w.w
                w = sum > 1e-6 ? w / sum : SIMD4(1, 0, 0, 0)
                joints.append(j)
                weights.append(w)
            }
            withExtendedLifetime(skin) {}

            for submesh in mesh.submeshes as? [MDLSubmesh] ?? [] {
                guard submesh.geometryType == .triangles else { continue }
                let buffer = submesh.indexBuffer(asIndexType: .uInt32)
                let map = buffer.map()
                let indices = (0..<submesh.indexCount).map {
                    base + map.bytes.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self)
                }
                withExtendedLifetime(map) {}
                let material = submesh.material.map { Material($0) } ?? Material()
                if let same = groups.firstIndex(where: { Self.sameSurface($0.material, material) }) {
                    groups[same].indices += indices
                } else {
                    groups.append((indices, material))
                }
            }
        }

        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for p in positions { low = simd_min(low, p); high = simd_max(high, p) }
        return SkinnedGeometry(
            vertexCount: positions.count, meshCount: meshes.count,
            layouts: Dictionary(uniqueKeysWithValues: layouts.map { ($0.key, (layoutStrides[$0.key]!, $0.value)) }),
            restPositions: positions, restNormals: normals, restTangents: tangentAttribute == nil ? nil : tangents,
            joints: joints, weights: weights,
            parts: groups.map { Part(indices: $0.indices, material: $0.material) },
            bounds: BoundingBox(minimum: low, maximum: high),
            position: (positionAttribute.bufferIndex, positionAttribute.offset),
            normal: normalAttribute.map { ($0.bufferIndex, $0.offset) },
            tangent: tangentAttribute.map { ($0.bufferIndex, $0.offset, $0.format == .float4) })
    }

    /// Whether two materials draw the same: everything but the name.
    static func sameSurface(_ a: Material, _ b: Material) -> Bool {
        var a = a
        a.name = b.name
        return a == b
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
}

/// A skinned character as the GPU holds it at rest — one per character *file*, shared by every character drawn from
/// it. Each one drawn is a ``SkinnedInstance``.
///
/// ### Skinned once a frame, drawn by the game's own pipelines
///
/// **The engine skins; the game draws.** ``SkinningPass`` runs one compute dispatch per character per frame, writing
/// the posed vertices into buffers laid out exactly as the game's static meshes are, and everything after that — the
/// scene pass, every shadow cascade, a reflection — draws them with the pipelines the game already has for props. So
/// a game needs no skinned vertex shader, no second vertex layout and no skinned shadow pipeline, and **the joint
/// count has no ceiling but the palette's memory**: a 294-joint character costs what a 102-joint one does, plus 12 KB.
///
/// It was otherwise in every renderer this engine came from: a skinned vertex shader per game, re-skinning the same
/// character in the scene pass and again in each of four shadow cascades, with a fixed-size palette.
public final class SkinnedModel {

    /// The skeleton, and every clip the file carries.
    public let rig: Rig
    /// The character at rest, in the game's layout: what the game binds and draws, with one submesh per ``materials``
    /// entry. **Its vertex buffers are the rest pose** — draw an instance's posed buffers in their place
    /// (``SkinnedInstance/vertexBufferAddress(_:frameSlot:)``).
    public let mesh: MTKMesh
    /// One per submesh of ``mesh``.
    public let materials: [Material]
    /// At rest, in skeleton space.
    public let bounds: BoundingBox
    public let vertexCount: Int
    /// How many of the file's meshes were merged into ``mesh``.
    public let partCount: Int

    let device: MTLDevice
    let geometry: SkinnedGeometry
    let restPositions: MTLBuffer
    let restNormals: MTLBuffer
    let restTangents: MTLBuffer
    let jointBuffer: MTLBuffer
    let weightBuffer: MTLBuffer
    let parameters: MTLBuffer

    /// Loads a character exported to USD — the skeleton and its clips through ``RigLoader``, every skinned mesh merged.
    ///
    /// - Parameters: as ``SkinnedGeometry/read(url:vertexDescriptor:semantics:skeletonJointCount:)``; the descriptor is
    ///   the game's static one, the one its prop pipeline was built with.
    public init(url: URL, device: MTLDevice, vertexDescriptor: MTLVertexDescriptor, semantics: [Int: String]) throws {
        let rig = try RigLoader.load(url: url)
        let geometry = try SkinnedGeometry.read(url: url, vertexDescriptor: vertexDescriptor, semantics: semantics,
                                                skeletonJointCount: rig.skeleton.jointCount)
        self.rig = rig
        self.geometry = geometry
        self.device = device
        self.vertexCount = geometry.vertexCount
        self.partCount = geometry.meshCount
        self.bounds = geometry.bounds

        func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, 16)
            let made = values.isEmpty ? device.makeBuffer(length: length, options: .storageModeShared)
                : values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let made else { throw SkinnedModelError.couldNotCreate(label) }
            made.label = label
            return made
        }
        // Packed: the kernel reads `packed_float3`, twelve bytes a vertex, not SIMD3's sixteen.
        restPositions = try buffer(geometry.restPositions.flatMap { [$0.x, $0.y, $0.z] }, "Skin Rest Positions")
        restNormals = try buffer(geometry.restNormals.flatMap { [$0.x, $0.y, $0.z] }, "Skin Rest Normals")
        restTangents = try buffer(geometry.restTangents ?? [], "Skin Rest Tangents")
        jointBuffer = try buffer(geometry.joints, "Skin Joints")
        weightBuffer = try buffer(geometry.weights, "Skin Weights")

        let strides = geometry.layouts.mapValues(\.stride)
        var p = SkinningParameters(vertexCount: UInt32(geometry.vertexCount),
                                   positionStride: UInt32(strides[geometry.position.layout] ?? 0),
                                   positionOffset: UInt32(geometry.position.offset))
        if let normal = geometry.normal {
            p.normalStride = UInt32(strides[normal.layout] ?? 0)
            p.normalOffset = UInt32(normal.offset)
        }
        if let tangent = geometry.tangent {
            p.tangentStride = UInt32(strides[tangent.layout] ?? 0)
            p.tangentOffset = UInt32(tangent.offset)
            p.tangentHasHandedness = tangent.hasHandedness ? 1 : 0
        }
        parameters = try buffer([p], "Skin Parameters")

        // The rest mesh, built the way a loaded one is: Model I/O buffers in the game's layout, then Metal's.
        let modelDescriptor = try MeshLoader.namedDescriptor(vertexDescriptor, semantics: semantics,
                                                             file: url.lastPathComponent)
        let allocator = MTKMeshBufferAllocator(device: device)
        let layoutCount = (modelDescriptor.layouts as? [MDLVertexBufferLayout] ?? []).count
        var vertexBuffers: [MDLMeshBuffer] = []
        for layout in 0..<layoutCount {
            let bytes = geometry.layouts[layout]?.bytes ?? Data(count: 4)
            vertexBuffers.append(allocator.newBuffer(with: bytes, type: .vertex))
        }
        var submeshes: [MDLSubmesh] = []
        for part in geometry.parts {
            let indexData = part.indices.withUnsafeBytes { Data($0) }
            let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: indexData, type: .index),
                                     indexCount: part.indices.count, indexType: .uInt32, geometryType: .triangles,
                                     material: nil)
            submesh.name = part.material.name
            submeshes.append(submesh)
        }
        let model = MDLMesh(vertexBuffers: vertexBuffers, vertexCount: geometry.vertexCount,
                            descriptor: modelDescriptor, submeshes: submeshes)
        do {
            mesh = try MTKMesh(mesh: model, device: device)
        } catch {
            throw SkinnedModelError.couldNotCreate("the character's mesh: \(error)")
        }
        mesh.name = url.deletingPathExtension().lastPathComponent
        materials = geometry.parts.map(\.material)
    }

    /// The Model I/O layouts the kernel writes into — the ones an instance keeps a posed copy of, per frame in flight.
    var posedLayouts: Set<Int> {
        var set: Set<Int> = [geometry.position.layout]
        if let normal = geometry.normal { set.insert(normal.layout) }
        if let tangent = geometry.tangent { set.insert(tangent.layout) }
        return set
    }

    /// A character to draw from this file: its own pose, palette and posed vertices.
    public func makeInstance() throws -> SkinnedInstance { try SkinnedInstance(model: self) }

    /// Everything the GPU must reach for this file: add it to the renderer's residency set, with each instance's.
    public var allocations: [any MTLAllocation] {
        [restPositions, restNormals, restTangents, jointBuffer, weightBuffer, parameters]
            + mesh.vertexBuffers.map(\.buffer) + mesh.submeshes.map(\.indexBuffer.buffer)
    }
}

/// Must match `WESkinningParameters` in SkinningShaders.metal.
nonisolated struct SkinningParameters {
    var vertexCount: UInt32
    var positionStride: UInt32
    var positionOffset: UInt32
    var normalStride: UInt32 = 0
    var normalOffset: UInt32 = 0
    var tangentStride: UInt32 = 0
    var tangentOffset: UInt32 = 0
    var tangentHasHandedness: UInt32 = 0
}

/// One character drawn from a ``SkinnedModel``: its ``pose``, and the GPU memory that pose is drawn from.
///
/// **Everything per frame in flight.** The palette and the posed vertices are written for one frame while the GPU may
/// still be drawing the frame before; one copy of either is a pose half-overwritten mid-draw, which is matrices at
/// nonsense and vertices at nonsense coordinates — a GPU fault, surfacing somewhere far from here.
public final class SkinnedInstance {
    public let model: SkinnedModel
    /// Set it with a clip, a blend or a mix of clips; ``SkinningPass`` takes it from there.
    public var pose: SkeletonPose

    let palette: MTLBuffer
    let paletteStride: Int
    /// Per frame slot, per posed layout.
    let posed: [[Int: MTLBuffer]]

    init(model: SkinnedModel) throws {
        self.model = model
        pose = SkeletonPose(skeleton: model.rig.skeleton)
        let slots = FrameRenderer.maxFramesInFlight
        paletteStride = (MemoryLayout<simd_float4x4>.stride * max(model.rig.skeleton.jointCount, 1) + 255) & ~255
        guard let palette = model.device.makeBuffer(length: paletteStride * slots, options: .storageModeShared) else {
            throw SkinnedModelError.couldNotCreate("joint palette")
        }
        palette.label = "Joint Palette, \(model.mesh.name)"
        self.palette = palette

        var posed: [[Int: MTLBuffer]] = []
        for slot in 0..<slots {
            var buffers: [Int: MTLBuffer] = [:]
            for layout in model.posedLayouts {
                // A copy of the rest layout, so whatever the kernel does not write — texture coordinates, colours —
                // is already there and stays there.
                guard let bytes = model.geometry.layouts[layout]?.bytes,
                      let buffer = bytes.withUnsafeBytes({
                          model.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                      }) else { throw SkinnedModelError.couldNotCreate("posed vertices") }
                buffer.label = "Posed Vertices \(slot), \(model.mesh.name)"
                buffers[layout] = buffer
            }
            posed.append(buffers)
        }
        self.posed = posed
        for slot in 0..<slots { writePalette(frameSlot: slot) }
    }

    /// Copies the pose's skinning matrices into this frame slot's palette. ``SkinningPass/encode(into:frameSlot:instances:)``
    /// does it for every instance it skins, so a game calls this only to skin by some other means.
    public func writePalette(frameSlot: Int) {
        let matrices = pose.skinningMatrices
        palette.contents().advanced(by: frameSlot * paletteStride)
            .withMemoryRebound(to: simd_float4x4.self, capacity: matrices.count) {
                $0.update(from: matrices, count: matrices.count)
            }
    }

    /// Where to bind vertex buffer `layout` of ``SkinnedModel/mesh`` this frame — the posed copy where skinning writes
    /// into that layout, the rest buffer where it does not.
    public func vertexBufferAddress(_ layout: Int, frameSlot: Int) -> UInt64 {
        if let buffer = posed[frameSlot % posed.count][layout] { return buffer.gpuAddress }
        let rest = model.mesh.vertexBuffers[layout]
        return rest.buffer.gpuAddress + UInt64(rest.offset)
    }

    /// The posed vertices of one frame slot, for reading back — a test, or a tool measuring what was drawn.
    public func posedBuffer(_ layout: Int, frameSlot: Int) -> MTLBuffer? { posed[frameSlot % posed.count][layout] }

    func paletteAddress(frameSlot: Int) -> UInt64 { palette.gpuAddress + UInt64(frameSlot * paletteStride) }

    public var allocations: [any MTLAllocation] { [palette] + posed.flatMap { $0.values } }
}

/// Skins characters once a frame: one compute dispatch each, before anything draws them.
///
/// **Encode it first in ``GameLoop/encodePrePasses(into:frameSlot:interpolation:)``**, before the shadow passes:
/// everything that draws a character reads what this writes. The engine's own passes — the scene, ``ShadowMap``,
/// ``ShadowAtlas``, ``ShadowCubes`` — wait for compute work before their vertex stage, so nothing else is needed; a
/// game encoding a render pass of its own that draws a character must open it with
/// `barrier(afterQueueStages: .dispatch, beforeStages: .vertex, visibilityOptions: .device)`, because Metal 4 tracks
/// no hazard between passes for you.
public final class SkinningPass {
    private let pipeline: MTLComputePipelineState
    private let argumentTable: MTL4ArgumentTable

    public init(device: MTLDevice) throws {
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "SkinningShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let function = MTL4LibraryFunctionDescriptor()
            function.library = library
            function.name = "weSkinVertices"
            let descriptor = MTL4ComputePipelineDescriptor()
            descriptor.label = "Skinning"
            descriptor.computeFunctionDescriptor = function
            pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
            let table = MTL4ArgumentTableDescriptor()
            table.maxBufferBindCount = 10
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw SkinnedModelError.couldNotCreate("the skinning pipeline: \(error)")
        }
    }

    /// Writes each instance's palette from its pose and skins it into this frame slot's posed vertices.
    public func encode(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, instances: [SkinnedInstance]) {
        guard !instances.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Skinning"
        encoder.setComputePipelineState(pipeline)
        encoder.setArgumentTable(argumentTable)
        let width = pipeline.threadExecutionWidth
        for instance in instances {
            let model = instance.model
            guard model.vertexCount > 0 else { continue }
            instance.writePalette(frameSlot: frameSlot)
            let g = model.geometry
            let positions = instance.vertexBufferAddress(g.position.layout, frameSlot: frameSlot)
            argumentTable.setAddress(model.restPositions.gpuAddress, index: 0)
            argumentTable.setAddress(model.restNormals.gpuAddress, index: 1)
            argumentTable.setAddress(model.restTangents.gpuAddress, index: 2)
            argumentTable.setAddress(model.jointBuffer.gpuAddress, index: 3)
            argumentTable.setAddress(model.weightBuffer.gpuAddress, index: 4)
            argumentTable.setAddress(instance.paletteAddress(frameSlot: frameSlot), index: 5)
            argumentTable.setAddress(positions, index: 6)
            argumentTable.setAddress(g.normal.map { instance.vertexBufferAddress($0.layout, frameSlot: frameSlot) } ?? positions,
                                     index: 7)
            argumentTable.setAddress(g.tangent.map { instance.vertexBufferAddress($0.layout, frameSlot: frameSlot) } ?? positions,
                                     index: 8)
            argumentTable.setAddress(model.parameters.gpuAddress, index: 9)
            encoder.dispatchThreads(threadsPerGrid: MTLSize(width: model.vertexCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        }
        encoder.endEncoding()
    }
}
