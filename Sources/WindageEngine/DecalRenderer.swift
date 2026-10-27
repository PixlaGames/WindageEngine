//
//  DecalRenderer.swift
//  WindageEngine
//

import Foundation
import Metal
import simd

/// Why a ``DecalRenderer`` could not be made.
public nonisolated enum DecalRendererError: Error, CustomStringConvertible, Sendable {
    /// The decal shaders would not compile, or their pipeline would not build — the reason kept as text.
    case pipelineUnavailable(String)
    /// The device would not create one of the objects drawing needs — named here.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .pipelineUnavailable(let reason): "unable to build the decal pipeline: \(reason)"
        case .couldNotCreate(let what): "the device would not create the \(what)"
        }
    }
}

/// Draws a ``DecalSet`` as quads lying on their surfaces, each showing one cell of an atlas.
///
/// **After the opaque scene, depth tested and never written**, like ``ParticleRenderer``: a mark behind a
/// rock is hidden by it, and two marks overlapping do not punch holes in each other. Draw decals
/// **before** particles, so dust thrown up from a strike hangs in front of the mark it left.
///
/// **Premultiplied over**: the texel's alpha times the decal's opacity covers what is behind it.
/// Sampled **clamped, never repeated** — a mark reads one cell of an atlas, and a repeating sampler
/// bleeds the neighbouring cell in along every edge.
public final class DecalRenderer {

    /// One mark as the shader reads it. **Five `float4`s**, pinned by a test on size and stride.
    struct Instance {
        var position: SIMD4<Float>
        var right: SIMD4<Float>
        var up: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var tint: SIMD4<Float>
    }

    struct Frame {
        var viewProjection: simd_float4x4
        var light: SIMD4<Float>
    }

    public let capacity: Int
    public let texture: MTLTexture
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let instanceBuffer: MTLBuffer
    private let frameBuffer: MTLBuffer
    private let instanceBytes: Int
    private static let frameStride = (MemoryLayout<Frame>.size + 255) & ~255

    /// - Parameters:
    ///   - texture: the atlas every mark is cut from. Mipmapped, or marks at range shimmer.
    ///   - capacity: the most marks drawn in one frame — the ``DecalSet/capacity`` of the set drawn.
    ///   - colorPixelFormat: what the pass it draws into is. The engine's HDR scene unless a game draws
    ///     its scene into a target of its own.
    ///   - sampleCount: that pass's samples per pixel. Made again when it changes.
    /// - Throws: ``DecalRendererError`` when the shaders, the pipeline or a buffer cannot be made.
    public init(device: MTLDevice, texture: MTLTexture, capacity: Int,
                colorPixelFormat: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                sampleCount: Int = 1) throws {
        self.capacity = max(1, capacity)
        self.texture = texture
        instanceBytes = MemoryLayout<Instance>.stride * self.capacity
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "DecalShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.library = library
            vertexFunction.name = "weDecalVertex"
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.library = library
            fragmentFunction.name = "weDecalFragment"

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "Decals"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.rasterSampleCount = max(sampleCount, 1)
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].blendingState = .enabled
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw DecalRendererError.pipelineUnavailable(String(describing: error))
        }

        // Reversed-Z, like every other pass: nearer is greater.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw DecalRendererError.couldNotCreate("depth state")
        }
        guard let instances = device.makeBuffer(length: instanceBytes * FrameRenderer.maxFramesInFlight,
                                                options: .storageModeShared),
              let frames = device.makeBuffer(length: DecalRenderer.frameStride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw DecalRendererError.couldNotCreate("decal buffers")
        }
        instances.label = "Decal Instances"
        frames.label = "Decal Frame"
        self.depthState = depthState
        instanceBuffer = instances
        frameBuffer = frames

        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        table.maxTextureBindCount = 1
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw DecalRendererError.couldNotCreate("argument table")
        }
    }

    public var allocations: [any MTLAllocation] { [instanceBuffer, frameBuffer, texture] }

    /// Draws every mark, in one instanced draw.
    ///
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    ///
    /// - Parameters:
    ///   - viewProjection: world to clip, the scene's.
    ///   - light: multiplies every mark — the light falling on the surfaces they lie on, or white to
    ///     draw them as made.
    /// - Returns: how many were drawn.
    @discardableResult
    public func draw(_ set: DecalSet,
                     into encoder: MTL4RenderCommandEncoder,
                     frameSlot: Int,
                     viewProjection: simd_float4x4,
                     light: SIMD3<Float> = SIMD3(repeating: 1)) -> Int {
        let base = instanceBytes * frameSlot
        let instances = instanceBuffer.contents().advanced(by: base)
            .bindMemory(to: Instance.self, capacity: capacity)
        var count = 0
        for decal in set.decals {
            guard count < capacity else { break }
            let opacity = decal.tint.w * set.opacity(of: decal)
            guard opacity > 0 else { continue }
            let (right, up) = DecalSet.basis(normal: decal.normal)
            let half = decal.size * 0.5
            instances[count] = Instance(position: SIMD4(decal.position, 1),
                                        right: SIMD4(right * half, 0),
                                        up: SIMD4(up * half, 0),
                                        uvRect: decal.uvRect,
                                        tint: SIMD4(SIMD3(decal.tint.x, decal.tint.y, decal.tint.z), opacity))
            count += 1
        }
        guard count > 0 else { return 0 }

        var frame = Frame(viewProjection: viewProjection, light: SIMD4(light, 1))
        let frameOffset = DecalRenderer.frameStride * frameSlot
        frameBuffer.contents().advanced(by: frameOffset)
            .copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)

        encoder.pushDebugGroup("Decals")
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(instanceBuffer.gpuAddress + UInt64(base), index: 0)
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameOffset), index: 1)
        argumentTable.setTexture(texture.gpuResourceID, index: 0)
        encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: count)
        encoder.popDebugGroup()
        return count
    }
}
