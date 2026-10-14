//
//  ShadowAtlas.swift
//  WindageEngine
//

import Metal
import MetalKit
import simd

/// Why a ``ShadowAtlas`` could not be made: which of its objects the device would not create.
public nonisolated enum ShadowAtlasError: Error, CustomStringConvertible, Sendable {
    /// The depth texture — too large for this GPU, or out of memory.
    case texture
    /// The buffer holding each frame's light matrices.
    case matrixBuffer
    /// The reversed-Z depth state the pass records with.
    case depthState
    /// The argument table the pass binds its buffers through.
    case argumentTable(underlying: any Error)

    public var description: String {
        switch self {
        case .texture: "the device would not create the shadow atlas's depth texture"
        case .matrixBuffer: "the device would not create the shadow atlas's matrix buffer"
        case .depthState: "the device would not create the shadow atlas's depth state"
        case .argumentTable(let error):
            "the device would not create the shadow atlas's argument table — \(error)"
        }
    }
}

/// Shadow maps for the lights that are not the sun, packed into one texture.
///
/// ### Why an atlas rather than a texture each
///
/// A shadow map per light means a texture per light: an allocation and a residency entry that appear
/// and disappear as a level loads, a render pass each, and a shader that would have to index an array
/// of textures. One texture cut into tiles is a fixed allocation, **one render pass for every light**
/// — the viewport moves between them — and a single binding the shader samples with an offset.
///
/// ### Spot lights only, and the cost of the rest is written down
///
/// A spot's shadow map is one perspective render, which is the same shape as a cascade and shares the
/// same pipeline. **A point light needs six** — a cube, one face per direction — so shadowing every
/// lamp in a room costs six times what shadowing the aimed ones does. That is a real piece of work
/// rather than a hard one: cube tiles in the atlas, six passes per light, and a shader that picks a
/// face before it picks a tile.
///
/// Until then a point light is unshadowed, which is the same limitation the sample already had and
/// is why its lamps have short ranges: a light that reaches through a wall is only obvious when it
/// reaches far enough for it to be.
public final class ShadowAtlas {

    /// One light's share of the texture.
    public nonisolated struct Tile: Sendable, Equatable {
        /// Where this tile starts, in the atlas's texels.
        public let origin: SIMD2<Int>
        /// Its edge length, in texels.
        public let resolution: Int

        /// The tile as the shader wants it: a UV offset and a scale, so a lookup in `0…1` for one
        /// light lands inside its own tile.
        public func uvTransform(atlasResolution: Int) -> (offset: SIMD2<Float>, scale: Float) {
            let inverse = 1 / Float(atlasResolution)
            return (SIMD2(Float(origin.x) * inverse, Float(origin.y) * inverse),
                    Float(resolution) * inverse)
        }
    }

    public let texture: MTLTexture
    /// The whole atlas's edge, in texels.
    public let resolution: Int
    public let tilesPerSide: Int

    /// How many lights may cast at once — one tile each, addressed by ``Caster/slot``. **A hard number,
    /// and the shader does not need to know it** — a light either carries a tile or does not, which it
    /// says in its own data.
    public var slotCount: Int { tilesPerSide * tilesPerSide }

    /// The rasterizer's depth bias while recording. A game tunes it for its lamps.
    public var rasterBias: ShadowBias

    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let matrixBuffer: MTLBuffer
    private static let matrixStride = 256   // one light matrix per tile per frame, aligned

    /// - Parameters:
    ///   - resolution: the whole atlas's edge, in texels.
    ///   - tilesPerSide: cut into this many columns and rows, so `tilesPerSide²` lights may cast.
    ///   - rasterBias: the depth bias while recording.
    /// - Throws: ``ShadowAtlasError``, naming the object the device would not create.
    public init(device: MTLDevice, resolution: Int = 2048, tilesPerSide: Int = 4,
                rasterBias: ShadowBias = .spot) throws {
        self.resolution = max(64, resolution)
        self.tilesPerSide = max(1, tilesPerSide)
        self.rasterBias = rasterBias

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: ShadowMap.depthPixelFormat, width: self.resolution, height: self.resolution,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Private but **not memoryless**: read again in the shading pass, like the cascades.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ShadowAtlasError.texture }
        texture.label = "Shadow Atlas"
        self.texture = texture

        // Reversed-Z, matching every other pass in this engine. A shadow map written with one
        // convention and compared with the other renders a scene either fully lit or fully dark.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw ShadowAtlasError.depthState
        }
        self.depthState = depthState

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 5      // matching ShadowBufferIndex, instances included
        let table: MTL4ArgumentTable
        do {
            table = try device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw ShadowAtlasError.argumentTable(underlying: error)
        }
        guard let matrices = device.makeBuffer(
                length: ShadowAtlas.matrixStride * self.tilesPerSide * self.tilesPerSide
                      * FrameRenderer.maxFramesInFlight,
                options: .storageModeShared) else { throw ShadowAtlasError.matrixBuffer }
        matrices.label = "Shadow Atlas Matrices"
        self.argumentTable = table
        self.matrixBuffer = matrices
    }

    public var allocations: [any MTLAllocation] { [texture, matrixBuffer] }

    /// Where a slot's tile sits in the atlas.
    ///
    /// - Precondition: `slot` is in `0..<slotCount`. A bad one used to be clamped — to another light's
    ///   tile, which is a shadow in the wrong room.
    public func tile(forSlot slot: Int) -> Tile {
        precondition((0..<slotCount).contains(slot),
                     "shadow atlas slot \(slot) is outside 0..<\(slotCount)")
        let edge = resolution / tilesPerSide
        return Tile(origin: SIMD2((slot % tilesPerSide) * edge, (slot / tilesPerSide) * edge),
                    resolution: edge)
    }

    /// Where a spot light's shadow map looks from, and how it projects.
    ///
    /// **The field of view is the cone's *outer* angle doubled**, so the map covers exactly what the
    /// light can reach — no more, which would waste resolution, and no less, which would cut the
    /// shadow off inside the lit circle.
    ///
    /// Reversed-Z with an infinite far plane, like every other projection here. The light's range
    /// already cuts it off, so a far plane would be a second place to get the same number wrong.
    ///
    /// Returns `nil` for a light with no cone: a point light needs six of these, not one.
    public nonisolated static func viewProjection(for light: PunctualLight, nearPlane: Float = 0.05)
        -> simd_float4x4? {
        guard let cone = light.cone else { return nil }

        let forward = cone.direction
        var upHint = SIMD3<Float>(0, 1, 0)
        // A lamp pointing straight down is the common case and exactly where a fixed up vector is
        // degenerate — the cross product is zero and the whole basis becomes NaN.
        if abs(simd_dot(forward, upHint)) > 0.99 { upHint = SIMD3(0, 0, 1) }
        let right = simd_normalize(simd_cross(upHint, forward))
        let up = simd_cross(forward, right)

        let eye = light.position
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)
        ))

        // Widened a little past the cone, so the softened edge of the lit circle is still inside the
        // map rather than sampling whatever is beyond it.
        let fov = min(cone.outerAngle * 2.2, Float.radians(fromDegrees: 175))
        let projection = simd_float4x4(
            perspectiveFovY: fov, aspectRatio: 1, nearZ: max(nearPlane, 1e-3))
        return simd_mul(projection, view)
    }

    /// One light's shadow pass: which slot — and so which tile — and where it looks from.
    public nonisolated struct Caster: Sendable, Equatable {
        /// Which tile, in `0..<slotCount`. A caster outside that is skipped.
        public let slot: Int
        public let viewProjection: simd_float4x4

        public init(slot: Int, viewProjection: simd_float4x4) {
            self.slot = slot
            self.viewProjection = viewProjection
        }
    }

    /// Records every caster into its own tile, in **one render pass**.
    ///
    /// The viewport and scissor move between lights rather than the pass ending and starting again —
    /// a pass per light would clear and store the whole atlas each time, which is the cost of the
    /// atlas paid once per light instead of once per frame.
    public func encode(into commandBuffer: MTL4CommandBuffer,
                       frameSlot: Int,
                       casters: [Caster],
                       batches: [ShadowBatch]) {
        let descriptor = MTL4RenderPassDescriptor()
        let attachment = MTLRenderPassDepthAttachmentDescriptor()
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearDepth = FrameRenderer.reversedZClearDepth
        attachment.storeAction = .store
        descriptor.depthAttachment = attachment

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Shadow Atlas"

        // **Front-face culling**, as in the cascade pass: recording the back of an occluder pushes
        // the stored depth away from the lit surface and removes most acne before any bias.
        encoder.setCullMode(.front)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(rasterBias.constant, slopeScale: rasterBias.slopeScale, clamp: 0)
        encoder.setArgumentTable(argumentTable, stages: .vertex)

        let base = frameSlot * ShadowAtlas.matrixStride * slotCount
        for caster in casters where (0..<slotCount).contains(caster.slot) {
            let region = tile(forSlot: caster.slot)
            encoder.setViewport(MTLViewport(originX: Double(region.origin.x),
                                            originY: Double(region.origin.y),
                                            width: Double(region.resolution), height: Double(region.resolution),
                                            znear: 0, zfar: 1))
            // **Scissored as well as viewported.** A viewport limits where geometry lands; it does
            // not stop a clear or a wide triangle touching a neighbour's tile, and one light bleeding
            // into another's map is a shadow that appears in the wrong room.
            encoder.setScissorRect(MTLScissorRect(x: region.origin.x, y: region.origin.y,
                                                  width: region.resolution, height: region.resolution))

            var matrix = caster.viewProjection
            let offset = base + caster.slot * ShadowAtlas.matrixStride
            matrixBuffer.contents().advanced(by: offset)
                .copyMemory(from: &matrix, byteCount: MemoryLayout<simd_float4x4>.size)
            argumentTable.setAddress(matrixBuffer.gpuAddress + UInt64(offset),
                                     index: ShadowBufferIndex.lightViewProjection)

            for batch in batches {
                switch batch.kind {
                case .encodes(let encode):
                    // A batch that draws itself — instanced copies, a game-built mesh.
                    encoder.setRenderPipelineState(batch.pipeline)
                    encode(encoder, argumentTable,
                           ShadowPass(target: .atlasSlot(caster.slot), viewProjection: caster.viewProjection))
                case .objects(let objects):
                    guard objects.count > 0 else { continue }
                    encoder.setRenderPipelineState(batch.pipeline)
                    for index in 0..<objects.count {
                        ShadowBatch.drawObject(index, of: objects, encoder: encoder, table: argumentTable)
                    }
                }
            }
        }
        encoder.endEncoding()
    }
}
