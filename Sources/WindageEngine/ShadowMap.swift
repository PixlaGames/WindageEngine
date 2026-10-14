//
//  ShadowMap.swift
//  WindageEngine
//

import Metal
import MetalKit
import simd

/// One kind of geometry for a shadow pass: a pipeline, and how to reach each thing drawn with it.
///
/// **Shared by every shadow pass** — ``ShadowMap``'s cascades, ``ShadowAtlas``'s spots and
/// ``ShadowCubes``' lamps take the same list — which is why it is not nested in any of them.
///
/// **Batches rather than one loop, because a skinned mesh has a different vertex layout** and so
/// needs a different pipeline. Rolling that into a per-object loop means changing pipeline per
/// object; a list of batches changes it once per kind.
///
/// ### Two kinds, and each has only what it uses
///
/// - **Objects** — ``init(pipeline:count:mesh:uniformAddress:jointPaletteAddress:bounds:)``: one
///   `MTKMesh` per object, which the pass draws object by object, culling by ``ShadowCubes`` where
///   bounds are given.
/// - **Self-encoding** — ``init(pipeline:encode:)``: instanced copies, or a mesh a game builds into its
///   own buffers, like a heightfield it sculpts. The pass binds the light matrix and the pipeline and
///   hands over the encoder and the argument table.
///
/// The two were one struct with every field public, so a self-encoding batch carried a `mesh` that
/// stopped the program if read. Now what each kind holds is the engine's, and neither has a field
/// that means nothing for it.
///
/// Closures rather than arrays because a game's drawables are its own — an array here would mean
/// building a copy of the scene every frame to hand over.
public struct ShadowBatch {

    /// The game's shadow pipeline for this kind of geometry — see
    /// ``ShadowMap/pipelineDescriptor(vertexFunction:vertexDescriptor:label:)``.
    public let pipeline: MTLRenderPipelineState

    let kind: Kind

    enum Kind {
        case objects(Objects)
        case encodes((MTL4RenderCommandEncoder, MTL4ArgumentTable, ShadowPass) -> Void)
    }

    struct Objects {
        let count: Int
        let mesh: (Int) -> MTKMesh
        let uniformAddress: (Int) -> UInt64
        let jointPaletteAddress: ((Int) -> UInt64)?
        let bounds: ((Int) -> BoundingBox)?
    }

    /// A batch of objects, one `MTKMesh` each, drawn by the pass object by object.
    ///
    /// - Parameters:
    ///   - count: how many objects; the closures are asked for `0..<count`.
    ///   - uniformAddress: where an object's uniforms sit for the frame slot being encoded. **Already
    ///     written**: the shadow pass reads the same `model` matrix the main pass will, which is what
    ///     keeps a shadow attached to the thing that cast it.
    ///   - jointPaletteAddress: where its joint palette sits, or nil for anything not skinned. Also
    ///     already written — a shadow posed one frame behind its character is a shadow that lags a
    ///     wave.
    ///   - bounds: an object's bounds in **world** space, for passes that can cull. **nil means draw
    ///     everything.** A cascade covers what the camera covers, so there is little to cull;
    ///     ``ShadowCubes`` renders the same scene six times from one point, where a light's range and a
    ///     face's frustum remove most of it. A batch that cannot cheaply say where its objects are
    ///     keeps the conservative behavior, which costs draws rather than deleting shadows.
    public init(pipeline: MTLRenderPipelineState,
                count: Int,
                mesh: @escaping (Int) -> MTKMesh,
                uniformAddress: @escaping (Int) -> UInt64,
                jointPaletteAddress: ((Int) -> UInt64)? = nil,
                bounds: ((Int) -> BoundingBox)? = nil) {
        self.pipeline = pipeline
        self.kind = .objects(Objects(count: max(0, count), mesh: mesh, uniformAddress: uniformAddress,
                                     jointPaletteAddress: jointPaletteAddress, bounds: bounds))
    }

    /// A batch that encodes its own draws — instanced copies drawn with an instance count, or a mesh a
    /// game builds into its own buffers.
    ///
    /// Called once per pass — per cascade, atlas tile or cube face — with the pipeline and the light
    /// matrix already bound; the closure binds what its vertex function reads (``ShadowBufferIndex``)
    /// and encodes its draws. The ``ShadowPass`` says which pass, so it can draw only what that pass can
    /// see. Drawn whole into every cube face: the pass cannot cull what it cannot see into.
    public init(pipeline: MTLRenderPipelineState,
                encode: @escaping (MTL4RenderCommandEncoder, MTL4ArgumentTable, ShadowPass) -> Void) {
        self.pipeline = pipeline
        self.kind = .encodes(encode)
    }

    /// How many objects the pass draws one by one, or `nil` for a batch that encodes its own draws.
    public var objectCount: Int? {
        if case .objects(let objects) = kind { return objects.count }
        return nil
    }

    /// Binds one object's uniforms, joints and vertices and draws its submeshes — the loop every pass
    /// shares, so the three cannot drift apart.
    static func drawObject(_ index: Int, of objects: Objects,
                           encoder: MTL4RenderCommandEncoder, table: MTL4ArgumentTable) {
        table.setAddress(objects.uniformAddress(index), index: ShadowBufferIndex.uniforms)
        if let joints = objects.jointPaletteAddress {
            table.setAddress(joints(index), index: ShadowBufferIndex.jointPalette)
        }
        let mesh = objects.mesh(index)
        for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
            table.setAddress(vertexBuffer.buffer.gpuAddress + UInt64(vertexBuffer.offset), index: bufferIndex)
        }
        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(primitiveType: submesh.primitiveType,
                                          indexCount: submesh.indexCount,
                                          indexType: submesh.indexType,
                                          indexBuffer: submesh.indexBuffer.buffer.gpuAddress
                                              + UInt64(submesh.indexBuffer.offset),
                                          indexBufferLength: submesh.indexBuffer.length)
        }
    }
}

/// Which pass a self-encoding ``ShadowBatch`` is being asked to draw into: **so it can draw only what
/// that pass can see.** A sun cascade near the eye covers a few meters; drawing a whole wood into it was
/// three quarters of a measured frame.
public nonisolated struct ShadowPass: Sendable, Equatable {

    /// What is being recorded. An index alone meant a cascade, a tile or a cube face depending on who
    /// was asking, so it says which.
    public enum Target: Sendable, Equatable {
        /// One of ``ShadowMap``'s cascades, nearest first.
        case cascade(Int)
        /// A spot light's tile of ``ShadowAtlas`` — the caster's ``ShadowAtlas/Caster/slot``.
        case atlasSlot(Int)
        /// One face of a lamp's cube in ``ShadowCubes``: the caster's ``ShadowCubes/Caster/slot`` and the
        /// face, `0..<6` in the order `+X, −X, +Y, −Y, +Z, −Z`.
        case cubeFace(slot: Int, face: Int)
    }

    public let target: Target
    /// World to this pass's light clip space — build a `Frustum` from it to cull.
    public let viewProjection: simd_float4x4

    public init(target: Target, viewProjection: simd_float4x4) {
        self.target = target
        self.viewProjection = viewProjection
    }
}

/// Where a shadow pass's argument table puts each thing, and therefore what a game's shadow vertex
/// function must declare. **Stated as constants rather than left in a comment**, because a mismatch
/// here does not fail — it reads a matrix out of the wrong buffer and records the scene from nowhere.
///
/// The same for all three passes.
public nonisolated enum ShadowBufferIndex {
    /// The mesh's vertex buffer. Set from the mesh for a batch of objects, so a game never binds it.
    public static let vertices = 0
    /// The game's per-object uniforms, whatever they are.
    public static let uniforms = 1
    /// This pass's light view-projection, a single `float4x4`, supplied by the engine.
    public static let lightViewProjection = 2
    /// The joint palette, for a skinned batch.
    public static let jointPalette = 3
    /// The copies' transforms, for an instanced batch that encodes its own draws — the
    /// ``InstanceBuffer`` contract: one `float4x4` per copy, indexed by `[[instance_id]]`.
    public static let instances = 4
}

/// The rasterizer's depth bias for a shadow pass: a constant part and a part scaled by the surface's
/// slope to the light.
///
/// **Negative, because depth is reversed.** Under reversed-Z, pushing a recorded occluder *away* from
/// the light means a smaller value, so the sign is the opposite of every textbook. Getting it wrong
/// doubles the acne instead of removing it, which reads as the bias having no effect.
///
/// One type for all three passes — each pass's `rasterBias` — and each defaults to its own numbers: the
/// cascades ``ShadowBias/cascades`` (scaled per cascade by ``ShadowCascades/biasScales``), a spot's tile
/// ``ShadowBias/spot`` and a lamp's cube ``ShadowBias/cube``.
///
/// Not the same thing as ``ShadowCascades/normalizedDepthBias(forCascade:)``, which a *shader* adds
/// when it compares; this one is applied by the rasterizer when the map is recorded.
public nonisolated struct ShadowBias: Sendable, Equatable {
    /// Added to every depth, in normalized depth units.
    public var constant: Float
    /// Times the depth's slope across the pixel — the one that matters: a surface nearly edge-on to the
    /// light spans many depth values within one texel, and needs room proportional to that slope.
    public var slopeScale: Float

    public init(constant: Float, slopeScale: Float) {
        self.constant = constant
        self.slopeScale = slopeScale
    }

    /// The sun's cascades, before each cascade's scale.
    public static let cascades = ShadowBias(constant: -0.0006, slopeScale: -1.8)
    /// A spot light's tile in ``ShadowAtlas``.
    public static let spot = ShadowBias(constant: -0.0015, slopeScale: -2.5)
    /// A lamp's cube in ``ShadowCubes``: no constant part — its depth is `near / distance`, where a
    /// constant would mean a different distance on every face's corner.
    public static let cube = ShadowBias(constant: 0, slopeScale: -2.5)
}

/// Why a ``ShadowMap`` could not be made: which of its objects the device would not create.
public nonisolated enum ShadowMapError: Error, CustomStringConvertible, Sendable {
    /// The depth texture array — too large for this GPU, or out of memory.
    case texture
    /// The buffer holding each frame's light matrices.
    case matrixBuffer
    /// The reversed-Z depth state the pass records with.
    case depthState
    /// The argument table the pass binds its buffers through.
    case argumentTable(underlying: any Error)

    public var description: String {
        switch self {
        case .texture: "the device would not create the shadow map's depth texture array"
        case .matrixBuffer: "the device would not create the shadow map's matrix buffer"
        case .depthState: "the device would not create the shadow map's depth state"
        case .argumentTable(let error):
            "the device would not create the shadow map's argument table — \(error)"
        }
    }
}

/// The sun's shadow pass: the scene recorded from the light's point of view, once per cascade.
///
/// **Extracted 2026-09-09, from two implementations that had drifted into being the same thing.**
/// `ShadowCascades` — the arithmetic — has been here since it was written; the *pass* was not, and it
/// existed twice: once in this repository's sample and once in a game. Every part that varied between
/// them turned out to be one of two things, and both are supplied per ``ShadowBatch``.
///
/// > **This was previously parked as "waiting for a third consumer", and that was the wrong reason.**
/// > A third copy would have been more evidence about a question that was already answerable. What
/// > actually settled it was teaching the sample's pass to draw *skinned* meshes: a second vertex
/// > layout inside one consumer forced exactly the abstraction two consumers had been hinting at.
///
/// ### What the engine owns, and what it cannot
///
/// | here | the game's |
/// |---|---|
/// | the depth texture array, its format and its per-cascade slices | the **pipelines** — they are compiled against the game's shaders and its vertex descriptor |
/// | the reversed-Z depth state, the front-face cull, the slope-scaled bias | the **uniform layout** — what a `model` matrix sits inside is the game's struct |
/// | the per-cascade pass descriptors and the encoder loop | the joint palette, where there is one |
/// | the light matrices, per frame in flight | the cascade *numbers* — a courtyard and a sniper range want different splits |
///
/// A pipeline cannot come from here: it needs a vertex function and a vertex descriptor that only
/// the game has. **What can come from here is everything that has to be right for a pipeline to
/// work at all** — see ``pipelineDescriptor(vertexFunction:vertexDescriptor:label:)``.
public final class ShadowMap {

    /// Depth only, and this is not the engine's main depth format by accident: a cascade array is
    /// read again in a later pass, where a packed or stencil format would only cost bandwidth.
    public static let depthPixelFormat: MTLPixelFormat = .depth32Float

    public let cascades: ShadowCascades
    public let texture: MTLTexture

    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let matrixBuffer: MTLBuffer
    private static let matrixStride = MemoryLayout<simd_float4x4>.stride

    /// - Parameter cascades: **the game's numbers.** A courtyard seventy meters across and a range
    ///   where the target is at 800 m want different splits and a different light depth range;
    ///   `ShadowCascades` takes them as arguments for that reason.
    /// - Throws: ``ShadowMapError``, naming the object the device would not create.
    public init(device: MTLDevice, cascades: ShadowCascades) throws {
        self.cascades = cascades

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = ShadowMap.depthPixelFormat
        descriptor.width = cascades.resolution
        descriptor.height = cascades.resolution
        descriptor.arrayLength = cascades.count
        descriptor.usage = [.renderTarget, .shaderRead]
        // Private, but **not memoryless**: unlike a main depth buffer this is read again in a later
        // pass, so it has to survive its own render pass.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShadowMapError.texture }
        texture.label = "Shadow Cascades"
        self.texture = texture

        guard let matrices = device.makeBuffer(
            length: ShadowMap.matrixStride * cascades.count * FrameRenderer.maxFramesInFlight,
            options: .storageModeShared) else { throw ShadowMapError.matrixBuffer }
        matrices.label = "Cascade Matrices"
        matrixBuffer = matrices

        // Reversed-Z like every other pass in this engine: nearer the light is a *greater* value.
        // **The same convention as the main pass, and it has to be** — a shadow map written with one
        // convention and compared with the other renders a scene either fully lit or fully dark.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw ShadowMapError.depthState
        }
        self.depthState = depthState

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 5   // through ShadowBufferIndex.instances
        do {
            argumentTable = try device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw ShadowMapError.argumentTable(underlying: error)
        }
    }

    /// A pipeline descriptor with everything a shadow pass needs set correctly, ready for the game's
    /// vertex function.
    ///
    /// **Three things have to be right and none of them is obvious.** No fragment function and no
    /// color attachment, because nothing is being shaded and everything but the depth write is
    /// wasted; a raster sample count of one, because a multisampled shadow map costs four times the
    /// memory to record the same occlusion; and the depth format matching the texture, which is the
    /// one that fails loudly rather than quietly.
    ///
    /// The game still supplies the vertex function and the vertex descriptor, which is exactly the
    /// part the engine cannot know.
    public static func pipelineDescriptor(vertexFunction: MTL4LibraryFunctionDescriptor,
                                          vertexDescriptor: MTLVertexDescriptor,
                                          label: String = "Shadow") -> MTL4RenderPipelineDescriptor {
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = nil
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        return descriptor
    }

    /// Everything the GPU must be able to reach.
    public var allocations: [any MTLAllocation] { [texture, matrixBuffer] }

    /// This frame's light matrices, in the order a fragment shader reading the cascades expects.
    ///
    /// Computed once and handed back, so the shadow pass and the main pass cannot disagree about
    /// where the light was looking — two calls to `cascadeMatrices` a frame apart would.
    @discardableResult
    public func updateMatrices(frameSlot: Int,
                               camera: Camera,
                               sunDirection: SIMD3<Float>) -> [simd_float4x4] {
        updateMatrices(frameSlot: frameSlot, cameraPosition: camera.position, cameraForward: camera.forward,
                       sunDirection: sunDirection)
    }

    /// The same, for a view that is not a ``Camera`` — an orbiting editor camera, a cutscene's rail.
    /// The cascades need only where the eye is and which way it looks.
    @discardableResult
    public func updateMatrices(frameSlot: Int,
                               cameraPosition: SIMD3<Float>,
                               cameraForward: SIMD3<Float>,
                               sunDirection: SIMD3<Float>) -> [simd_float4x4] {
        let matrices = cascades.cascadeMatrices(cameraPosition: cameraPosition,
                                                cameraForward: cameraForward,
                                                sunDirection: sunDirection)
        let base = frameSlot * cascades.count * ShadowMap.matrixStride
        for (index, matrix) in matrices.enumerated() {
            var value = matrix
            matrixBuffer.contents().advanced(by: base + index * ShadowMap.matrixStride)
                .copyMemory(from: &value, byteCount: MemoryLayout<simd_float4x4>.size)
        }
        return matrices
    }

    /// Records every batch from the sun's point of view, once per cascade.
    ///
    /// ``updateMatrices(frameSlot:camera:sunDirection:)`` must have run for this frame slot, and the
    /// per-object uniforms must already be written — the pass reads the same `model` matrix the main
    /// pass will, which is what keeps a shadow attached to the thing that cast it.
    public func encode(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, batches: [ShadowBatch]) {
        let matrixBase = frameSlot * cascades.count * ShadowMap.matrixStride

        for cascade in 0..<cascades.count {
            let descriptor = MTL4RenderPassDescriptor()
            let attachment = MTLRenderPassDepthAttachmentDescriptor()
            attachment.texture = texture
            attachment.slice = cascade
            attachment.loadAction = .clear
            attachment.clearDepth = FrameRenderer.reversedZClearDepth
            attachment.storeAction = .store        // read again in the main pass
            descriptor.depthAttachment = attachment

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = "Shadow Cascade \(cascade)"

            // **Front-face culling.** Recording the *back* of an occluder pushes the stored depth
            // away from the lit surface, which removes most shadow acne before any bias is applied.
            // Bias then only has to cover what is left, instead of being cranked up until contact
            // shadows detach from their casters.
            encoder.setCullMode(.front)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setDepthStencilState(depthState)

            // Slope-scaled bias handles what culling does not: a surface nearly edge-on to the light
            // spans many depth values inside one texel and needs proportionally more room. Scaled
            // per cascade, because a cascade covering 8x the world per texel needs 8x the bias.
            let scale = cascades.biasScales[cascade]
            encoder.setDepthBias(cascades.rasterBias.constant * scale,
                                 slopeScale: cascades.rasterBias.slopeScale * scale,
                                 clamp: 0)

            encoder.setArgumentTable(argumentTable, stages: .vertex)
            argumentTable.setAddress(
                matrixBuffer.gpuAddress + UInt64(matrixBase + cascade * ShadowMap.matrixStride),
                index: ShadowBufferIndex.lightViewProjection)

            for batch in batches {
                switch batch.kind {
                case .encodes(let encode):
                    encoder.setRenderPipelineState(batch.pipeline)
                    let matrix = matrixBuffer.contents()
                        .advanced(by: matrixBase + cascade * ShadowMap.matrixStride)
                        .load(as: simd_float4x4.self)
                    encode(encoder, argumentTable, ShadowPass(target: .cascade(cascade), viewProjection: matrix))
                case .objects(let objects):
                    guard objects.count > 0 else { continue }
                    encoder.setRenderPipelineState(batch.pipeline)
                    for index in 0..<objects.count {
                        ShadowBatch.drawObject(index, of: objects, encoder: encoder, table: argumentTable)
                    }
                }
            }
            encoder.endEncoding()
        }
    }
}
