//
//  ShadowMapTests.swift
//  WindageEngineTests
//

import Testing
import Metal
import simd
@testable import WindageEngine

/// The GPU half of the shadow pass.
///
/// **Deliberately few, and that is the split working.** Everything that can be *wrong* rather than
/// merely broken — splits, per-cascade bias, texel snapping, blend bands — is `ShadowCascades` and is
/// tested without a device. What is here is a texture, a format and a descriptor: things that either
/// work or draw nothing.
@MainActor
struct ShadowMapTests {

    private let cascades = ShadowCascades(splits: [8, 22, 55, 120], resolution: 256,
                                          lightDepthRange: 200)

    /// Skipped rather than failed where there is no Metal device: a headless builder should not
    /// report a red suite for hardware it does not have.
    private func makeShadowMap() -> ShadowMap? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? ShadowMap(device: device, cascades: cascades)
    }

    @Test("The texture is one depth slice per cascade")
    func textureMatchesTheCascades() {
        guard let shadowMap = makeShadowMap() else { return }
        #expect(shadowMap.texture.textureType == .type2DArray)
        #expect(shadowMap.texture.arrayLength == cascades.count)
        #expect(shadowMap.texture.width == cascades.resolution)
        #expect(shadowMap.texture.height == cascades.resolution)
        #expect(shadowMap.texture.pixelFormat == ShadowMap.depthPixelFormat)
    }

    /// **Private but not memoryless.** A main depth buffer can be thrown away when its pass ends;
    /// this one is read again in the pass that shades, so it has to survive.
    @Test("The cascades survive their own render pass")
    func textureIsNotMemoryless() {
        guard let shadowMap = makeShadowMap() else { return }
        #expect(shadowMap.texture.storageMode == .private)
        #expect(shadowMap.texture.usage.contains(.renderTarget))
        #expect(shadowMap.texture.usage.contains(.shaderRead))
    }

    /// A view zooming out wants its far cascade to follow it; the texture is made once.
    @Test("The splits can move between frames, and the matrices follow them")
    func splitsCanChange() {
        guard let shadowMap = makeShadowMap() else { return }
        let texture = shadowMap.texture
        let eye = SIMD3<Float>(0, 10, 0), forward = SIMD3<Float>(0, 0, -1), sun = simd_normalize(SIMD3<Float>(0.3, -1, 0.2))
        let near = shadowMap.updateMatrices(frameSlot: 0, cameraPosition: eye, cameraForward: forward, sunDirection: sun)
        shadowMap.cascades = ShadowCascades(splits: [8, 22, 55, 900], resolution: 256, lightDepthRange: 200)
        let far = shadowMap.updateMatrices(frameSlot: 0, cameraPosition: eye, cameraForward: forward, sunDirection: sun)
        #expect(shadowMap.texture === texture)
        #expect(far[0] == near[0], "a cascade whose split did not move is the same")
        #expect(far[3] != near[3])
        #expect(far[3] == shadowMap.cascades.cascadeMatrices(cameraPosition: eye, cameraForward: forward, sunDirection: sun)[3])
    }

    @Test("Everything the GPU reads is offered to the residency set")
    func allocationsIncludeTheTexture() {
        guard let shadowMap = makeShadowMap() else { return }
        #expect(shadowMap.allocations.contains { ($0 as? MTLTexture) === shadowMap.texture })
        #expect(shadowMap.allocations.count == 2, "the texture and the light matrices")
    }

    /// Three things have to be right for a shadow pipeline and none of them is obvious: no fragment
    /// function, one raster sample, and a vertex descriptor the game supplies.
    @Test("The pipeline descriptor is depth-only")
    func pipelineDescriptorIsDepthOnly() {
        let descriptor = ShadowMap.pipelineDescriptor(vertexFunction: MTL4LibraryFunctionDescriptor(),
                                                      vertexDescriptor: MTLVertexDescriptor(),
                                                      label: "Test")
        #expect(descriptor.fragmentFunctionDescriptor == nil)
        #expect(descriptor.rasterSampleCount == 1)
        #expect(descriptor.label == "Test")
    }

    /// **Reversed-Z, so pushing an occluder away from the light is a *smaller* value.** Positive
    /// biases are the textbook ones and they double the acne here instead of removing it — which
    /// reads as the bias having no effect at all.
    @Test("The depth biases are negative, because depth is reversed")
    func biasesAreNegative() {
        #expect(cascades.rasterBias.constant < 0)
        #expect(cascades.rasterBias.slopeScale < 0)
        #expect(ShadowBias.spot.constant < 0 && ShadowBias.spot.slopeScale < 0)
        #expect(ShadowBias.cube.constant == 0 && ShadowBias.cube.slopeScale < 0)
    }

    /// A cascade covering 8× the world per texel needs roughly 8× the bias, and the near cascade is
    /// the one everything is measured against.
    @Test("Bias scales grow with the cascade")
    func biasScalesGrow() {
        #expect(cascades.biasScales[0] == 1)
        for index in 1..<cascades.count {
            #expect(cascades.biasScales[index] > cascades.biasScales[index - 1])
        }
    }

    /// A mismatch in these does not fail — it reads a matrix out of the wrong buffer and records the
    /// scene from nowhere, so they are constants rather than a comment.
    @Test("The buffer indices are distinct and stated")
    func bufferIndicesAreDistinct() {
        let indices = [ShadowBufferIndex.vertices,
                       ShadowBufferIndex.uniforms,
                       ShadowBufferIndex.lightViewProjection,
                       ShadowBufferIndex.jointPalette]
        #expect(Set(indices).count == indices.count)
    }

    /// An editor's orbiting view has a position and a direction but is not a `Camera`. The cascades it
    /// gets must be the ones a `Camera` in the same place, looking the same way, would get.
    @Test("Cascades from a bare position and direction match a Camera's")
    func matricesFromPositionMatchACamera() {
        guard let shadowMap = makeShadowMap() else { return }
        let camera = Camera(position: SIMD3(3, 2, -7), yaw: 0.7, pitch: -0.3)
        let sun = simd_normalize(SIMD3<Float>(0.4, 0.8, 0.2))
        let fromCamera = shadowMap.updateMatrices(frameSlot: 0, camera: camera, sunDirection: sun)
        let fromParts = shadowMap.updateMatrices(frameSlot: 1, cameraPosition: camera.position,
                                                 cameraForward: camera.forward, sunDirection: sun)
        #expect(fromCamera == fromParts)
    }

    /// **Near shadows only** (2026-10-27): the cascades past the limit are cleared and drawn into by nothing.
    @Test("A casting limit draws only the nearer cascades")
    func castingLimit() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
              let shadowMap = makeShadowMap() else { return }
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 nothing(uint id [[vertex_id]]) { return float4(0, 0, 0, 1); }
            """, options: nil)
        let function = MTL4LibraryFunctionDescriptor()
        function.library = library
        function.name = "nothing"
        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let pipeline = try compiler.makeRenderPipelineState(
            descriptor: ShadowMap.pipelineDescriptor(vertexFunction: function, vertexDescriptor: MTLVertexDescriptor(), label: "Test"))
        var drawn: [Int] = []
        let batch = ShadowBatch(pipeline: pipeline) { _, _, pass in
            if case .cascade(let cascade) = pass.target { drawn.append(cascade) }
        }
        let queue = try #require(device.makeMTL4CommandQueue())
        let allocator = try #require(device.makeCommandAllocator())
        let commands = try #require(device.makeCommandBuffer())
        commands.beginCommandBuffer(allocator: allocator)
        shadowMap.encode(into: commands, frameSlot: 0, batches: [batch], castingCascades: 2)
        shadowMap.encode(into: commands, frameSlot: 0, batches: [batch])
        commands.endCommandBuffer()
        _ = queue
        #expect(drawn == [0, 1, 0, 1, 2, 3])
    }

    @Test("A batch that encodes its own draws has its own index for instances")
    func instancesHaveTheirOwnIndex() {
        let indices = [ShadowBufferIndex.vertices, ShadowBufferIndex.uniforms,
                       ShadowBufferIndex.lightViewProjection, ShadowBufferIndex.jointPalette,
                       ShadowBufferIndex.instances]
        #expect(Set(indices).count == indices.count)
    }
}
