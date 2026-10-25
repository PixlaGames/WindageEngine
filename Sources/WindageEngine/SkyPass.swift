import Metal
import simd

/// **Draws a ``DaySky`` behind a scene**: a full-screen triangle at the far plane, the zenith fading to the horizon, the
/// ground's colour below it and the sun's disc.
///
/// **First in the scene pass**, before anything else is drawn: it writes no depth and tests none, so everything drawn
/// after covers it. It sets its own pipeline, depth state and argument table on the encoder; set yours again after.
public final class SkyPass {
    /// Mirrors `SkyUniforms` in `SkyShaders.metal`.
    struct Uniforms {
        var inverseViewProjection: simd_float4x4
        var eye: SIMD4<Float>
        var sunDirection: SIMD4<Float>
        var sunColour: SIMD4<Float>
        var zenith: SIMD4<Float>
        var horizon: SIMD4<Float>
        var ground: SIMD4<Float>
    }
    static let stride = (MemoryLayout<Uniforms>.stride + 255) & ~255

    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let table: MTL4ArgumentTable
    private let uniforms: MTLBuffer

    /// Everything the GPU must be able to reach: add it to the renderer's residency set.
    public var allocations: [any MTLAllocation] { [uniforms] }

    public init(device: MTLDevice) throws {
        let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "SkyShaders")
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = "skyVertex"
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = "skyFragment"
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = "Sky"
        descriptor.vertexFunctionDescriptor = vertex
        descriptor.fragmentFunctionDescriptor = fragment
        descriptor.colorAttachments[0].pixelFormat = FrameRenderer.sceneColorPixelFormat
        pipeline = try compiler.makeRenderPipelineState(descriptor: descriptor)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw FrameRendererError.couldNotCreate("sky depth state")
        }
        self.depthState = depthState
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        table = try device.makeArgumentTable(descriptor: tableDescriptor)
        guard let buffer = device.makeBuffer(length: Self.stride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw FrameRendererError.couldNotCreate("sky uniforms")
        }
        buffer.label = "Sky"
        uniforms = buffer
    }

    /// Draws the sky as seen through `viewProjection` from `eye`.
    public func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, viewProjection: simd_float4x4,
                       eye: SIMD3<Float>, lighting: DaySky.Lighting) {
        var values = Uniforms(inverseViewProjection: viewProjection.inverse, eye: SIMD4(eye, 1),
                              sunDirection: SIMD4(lighting.direction, 0), sunColour: SIMD4(lighting.colour, 0),
                              zenith: SIMD4(lighting.zenith, 0), horizon: SIMD4(lighting.horizon, 0),
                              ground: SIMD4(lighting.ground, 0))
        let offset = frameSlot * Self.stride
        uniforms.contents().advanced(by: offset).copyMemory(from: &values, byteCount: MemoryLayout<Uniforms>.size)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        table.setAddress(uniforms.gpuAddress + UInt64(offset), index: 0)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
