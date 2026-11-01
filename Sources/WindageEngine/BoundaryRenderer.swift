//
//  BoundaryRenderer.swift
//  WindageEngine
//

import Foundation
import Metal
import simd

/// Why a ``BoundaryRenderer`` could not be made.
public nonisolated enum BoundaryRendererError: Error, CustomStringConvertible, Sendable {
    /// The boundary shaders would not compile, or their pipeline would not build — the reason kept as text.
    case pipelineUnavailable(String)
    /// The device would not create one of the objects drawing needs — named here.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .pipelineUnavailable(let reason): "unable to build the boundary pipeline: \(reason)"
        case .couldNotCreate(let what): "the device would not create the \(what)"
        }
    }
}

/// Draws a ``WorldBoundary`` in its ``WorldBoundary/Look`` — a lattice, a grid, an energy field or a wall of haze —
/// into the scene.
///
/// **The whole pipeline is the engine's**, as the particles' is: a boundary is a shape and a look, with nothing of the
/// game's in it. **Into the HDR scene after the opaque geometry**, depth tested and never written, both faces drawn —
/// it is seen from inside — and blended premultiplied: its glow adds as light does, a haze covers as matter does.
///
/// Its surface is made on the CPU when the boundary's shape changes (``WorldBoundary/surface(around:rings:)``), into a
/// buffer for each frame in flight, so a boundary edited while frames are drawing never changes under one. **The same
/// number of corners whatever the shape**, so the triangles that join them are made once.
public final class BoundaryRenderer {

    /// One corner of the surface as the shader reads it: **two `float4`s**, pinned by a test.
    nonisolated struct Vertex: Equatable {
        /// Where, and the meters along the walls to it.
        var positionAndU: SIMD4<Float>
        /// Its outward normal, and the meters up the walls to it.
        var normalAndV: SIMD4<Float>
    }

    /// The frame as the shader reads it — `WEBoundaryFrame`.
    nonisolated struct Frame {
        var viewProjection: simd_float4x4
        var camera: SIMD4<Float>
        var player: SIMD4<Float>
        var color: SIMD4<Float>
        var style: SIMD4<Float>
        var pattern: SIMD4<Float>
        var ripples: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                      SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// Corners round each ring of the surface, and rings from the floor to the top.
    nonisolated static let around = 256, rings = 24
    nonisolated static let vertexCount = WorldBoundary.surfaceVertexCount(around: around, rings: rings)
    /// How many places it can be struck at once.
    public nonisolated static let rippleCapacity = 8

    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let frameBuffer: MTLBuffer
    private let indexCount: Int
    private static let vertexBytes = MemoryLayout<Vertex>.stride * vertexCount
    private static let frameStride = (MemoryLayout<Frame>.size + 255) & ~255
    /// The shape each frame slot's surface was made for — remade when the boundary's changes.
    private var madeFor: [WorldBoundary?] = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)
    private var strikes: [(point: SIMD3<Float>, time: Float)] = []

    /// - Parameters:
    ///   - colorPixelFormat: what the pass it draws into is — the engine's HDR scene unless a game draws its own.
    ///   - sampleCount: that pass's samples per pixel; a renderer is made again when it changes.
    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = FrameRenderer.sceneColorPixelFormat,
                sampleCount: Int = 1) throws {
        do {
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "BoundaryShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.library = library
            vertexFunction.name = "weBoundaryVertex"
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.library = library
            fragmentFunction.name = "weBoundaryFragment"
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "World Boundary"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.rasterSampleCount = max(sampleCount, 1)
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            // Premultiplied, as the particles are: a glow adds, a haze covers, with one blend.
            descriptor.colorAttachments[0].blendingState = .enabled
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw BoundaryRendererError.pipelineUnavailable(String(describing: error))
        }
        // Reversed-Z, like every other pass: nearer is greater.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw BoundaryRendererError.couldNotCreate("depth state")
        }
        let indices = WorldBoundary.surfaceIndices(around: Self.around, rings: Self.rings)
        guard let vertices = device.makeBuffer(length: Self.vertexBytes * FrameRenderer.maxFramesInFlight,
                                               options: .storageModeShared),
              let indexBuffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                                            options: .storageModeShared) }),
              let frames = device.makeBuffer(length: Self.frameStride * FrameRenderer.maxFramesInFlight,
                                             options: .storageModeShared) else {
            throw BoundaryRendererError.couldNotCreate("boundary buffers")
        }
        vertices.label = "Boundary Surface"
        indexBuffer.label = "Boundary Triangles"
        frames.label = "Boundary Frame"
        self.depthState = depthState
        vertexBuffer = vertices
        self.indexBuffer = indexBuffer
        frameBuffer = frames
        indexCount = indices.count
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        do {
            argumentTable = try device.makeArgumentTable(descriptor: table)
        } catch {
            throw BoundaryRendererError.couldNotCreate("argument table")
        }
    }

    public var allocations: [any MTLAllocation] { [vertexBuffer, indexBuffer, frameBuffer] }

    /// **Struck at `point`**, at `time` on the clock ``draw(_:into:frameSlot:viewProjection:camera:player:time:brightness:)``
    /// is given: a ripple spreads from it for a second and a quarter. The oldest of ``rippleCapacity`` gives way.
    public func strike(at point: SIMD3<Float>, time: Float) {
        strikes.append((point, time))
        if strikes.count > Self.rippleCapacity { strikes.removeFirst(strikes.count - Self.rippleCapacity) }
    }

    /// Draws the boundary — nothing if its look is ``WorldBoundary/Look/Visibility/hidden``.
    ///
    /// Leaves the encoder with this renderer's pipeline, depth state and argument table bound.
    ///
    /// - Parameters:
    ///   - camera: where the view is — its rim is brightest seen edge-on.
    ///   - player: whom a ``WorldBoundary/Look/Visibility/near`` boundary shows round, at their feet.
    ///   - time: seconds on any steady clock — its motion, and its ripples' ages.
    ///   - brightness: what its color is multiplied by into the scene's light, for a game whose exposure needs it.
    /// - Returns: whether it drew.
    @discardableResult
    public func draw(_ boundary: WorldBoundary, into encoder: MTL4RenderCommandEncoder, frameSlot: Int,
                     viewProjection: simd_float4x4, camera: SIMD3<Float>, player: SIMD3<Float>, time: Float,
                     brightness: Float = 1) -> Bool {
        let look = boundary.look
        guard look.visibility != .hidden, look.opacity > 0 else { return false }
        var shape = boundary
        shape.look = WorldBoundary.Look()
        if madeFor[frameSlot] != shape {
            let surface = boundary.surface(around: Self.around, rings: Self.rings)
            vertexBuffer.contents().advanced(by: Self.vertexBytes * frameSlot)
                .copyMemory(from: surface, byteCount: Self.vertexBytes)
            madeFor[frameSlot] = shape
        }
        strikes.removeAll { time - $0.time > 1.25 || time < $0.time }
        var ripples = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, -1), count: Self.rippleCapacity)
        for (i, strike) in strikes.enumerated() { ripples[i] = SIMD4(strike.point, time - strike.time) }
        let style: Float = switch look.style { case .lattice: 0; case .grid: 1; case .forceField: 2; case .haze: 3 }
        var frame = Frame(viewProjection: viewProjection, camera: SIMD4(camera, 1), player: SIMD4(player, time),
                          color: SIMD4(look.color * max(brightness, 0), look.opacity),
                          style: SIMD4(style, look.visibility == .near ? 1 : 0, look.nearDistance, look.motion),
                          pattern: SIMD4(boundary.patternCell(along: true), boundary.patternCell(along: false), 0, 0),
                          ripples: (ripples[0], ripples[1], ripples[2], ripples[3],
                                    ripples[4], ripples[5], ripples[6], ripples[7]))
        let frameOffset = Self.frameStride * frameSlot
        frameBuffer.contents().advanced(by: frameOffset).copyMemory(from: &frame, byteCount: MemoryLayout<Frame>.size)

        encoder.pushDebugGroup("World Boundary")
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        argumentTable.setAddress(vertexBuffer.gpuAddress + UInt64(Self.vertexBytes * frameSlot), index: 0)
        argumentTable.setAddress(frameBuffer.gpuAddress + UInt64(frameOffset), index: 1)
        encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer.gpuAddress, indexBufferLength: indexBuffer.length)
        encoder.popDebugGroup()
        return true
    }
}

// MARK: - The surface

nonisolated extension WorldBoundary {

    /// **A pattern cell's size along the walls or up them**, the look's ``Look/patternSize`` made to fit: along, a whole
    /// number of cells round the floor's perimeter, so the pattern meets itself where the surface closes.
    func patternCell(along: Bool) -> Float {
        let size = look.patternSize
        guard along else { return size }
        let cells = max(1, (perimeter / size).rounded())
        return perimeter / cells
    }

    static func surfaceVertexCount(around: Int, rings: Int) -> Int { rings * (around + 1) + 1 + (around + 1) }

    /// The triangles joining ``surface(around:rings:)``'s corners — the same for every shape.
    static func surfaceIndices(around: Int, rings: Int) -> [UInt32] {
        var indices: [UInt32] = []
        let row = around + 1
        for j in 0..<(rings - 1) {
            for i in 0..<around {
                let a = UInt32(j * row + i), b = a + 1, c = a + UInt32(row), d = c + 1
                indices += [a, b, d, a, d, c]
            }
        }
        let center = UInt32(rings * row), first = center + 1
        for i in 0..<around { indices += [center, first + UInt32(i), first + UInt32(i + 1)] }
        return indices
    }

    /// **A point round the floor's footprint, `arc` meters along it** from the middle of its +x side, going toward +z,
    /// with its outward normal — relative to ``center``.
    func perimeterPoint(_ arc: Float) -> (point: SIMD2<Float>, normal: SIMD2<Float>) {
        let r = cornerRadius, a = halfSize.x - r, b = halfSize.y - r
        var s = arc.truncatingRemainder(dividingBy: perimeter)
        if s < 0 { s += perimeter }
        // Half the +x side, then a corner, a side, … round to the other half of the +x side.
        let quarter = Float.pi / 2 * r
        let segments: [(length: Float, at: (Float) -> (SIMD2<Float>, SIMD2<Float>))] = [
            (b, { t in (SIMD2(halfSize.x, t), SIMD2(1, 0)) }),
            (quarter, { t in let q = r > 0 ? t / r : 0; return (SIMD2(a + r * cos(q), b + r * sin(q)), SIMD2(cos(q), sin(q))) }),
            (2 * a, { t in (SIMD2(a - t, halfSize.y), SIMD2(0, 1)) }),
            (quarter, { t in let q = .pi / 2 + (r > 0 ? t / r : 0); return (SIMD2(-a + r * cos(q), b + r * sin(q)), SIMD2(cos(q), sin(q))) }),
            (2 * b, { t in (SIMD2(-halfSize.x, b - t), SIMD2(-1, 0)) }),
            (quarter, { t in let q = .pi + (r > 0 ? t / r : 0); return (SIMD2(-a + r * cos(q), -b + r * sin(q)), SIMD2(cos(q), sin(q))) }),
            (2 * a, { t in (SIMD2(-a + t, -halfSize.y), SIMD2(0, -1)) }),
            (quarter, { t in let q = 1.5 * .pi + (r > 0 ? t / r : 0); return (SIMD2(a + r * cos(q), -b + r * sin(q)), SIMD2(cos(q), sin(q))) }),
            (b, { t in (SIMD2(halfSize.x, -b + t), SIMD2(1, 0)) }),
        ]
        for segment in segments {
            if s <= segment.length { return segment.at(s) }
            s -= segment.length
        }
        return (SIMD2(halfSize.x, 0), SIMD2(1, 0))
    }

    /// Where round the footprint each ring's corners go, meters along it: **every corner of a square footprint is one
    /// of them**, whatever the count, so its walls meet at the corner rather than across it — each rounded corner gets
    /// `perCorner`, the sides the rest by length.
    static func perimeterStops(of boundary: WorldBoundary, around: Int, perCorner: Int = 16) -> [Float] {
        let r = boundary.cornerRadius, a = boundary.halfSize.x - r, b = boundary.halfSize.y - r
        let sides = around - 4 * perCorner
        let alongZ = max(1, min(sides / 2 - 1, Int((Float(sides / 2) * b / max(a + b, 1e-6)).rounded())))
        let alongX = sides / 2 - alongZ
        let quarter = Float.pi / 2 * r
        // Half the +x side first, as `perimeterPoint` goes.
        let firstHalf = alongZ / 2, lastHalf = alongZ - firstHalf
        let parts: [(length: Float, count: Int)] = [
            (b, firstHalf), (quarter, perCorner), (2 * a, alongX), (quarter, perCorner), (2 * b, alongZ),
            (quarter, perCorner), (2 * a, alongX), (quarter, perCorner), (b, lastHalf),
        ]
        var stops: [Float] = []
        var start: Float = 0
        for part in parts {
            for k in 0..<part.count { stops.append(start + part.length * Float(k) / Float(part.count)) }
            start += part.length
        }
        return stops
    }

    /// **The boundary's surface**: `rings` rings of `around` corners from the floor to the top — a dome's walls straight
    /// to its spring and curving in above it — each closed by a copy of its first corner, then the top's middle and its ring again for the
    /// ceiling, flat (a dome's top ring has closed to a point or a ridge, and its ceiling has no area).
    func surface(around: Int, rings: Int) -> [BoundaryRenderer.Vertex] {
        let stops = Self.perimeterStops(of: self, around: around)
        let shortest = simd_reduce_min(halfSize)
        var vertices: [BoundaryRenderer.Vertex] = []
        vertices.reserveCapacity(Self.surfaceVertexCount(around: around, rings: rings))
        var climbed: Float = 0
        var last: SIMD2<Float>?
        var top: [SIMD3<Float>] = []
        for j in 0..<rings {
            let f = Float(j) / Float(rings - 1)
            let y: Float, k: Float, rise: SIMD2<Float>
            switch profile {
            case .dome:
                // The first ring on the floor, the rest up the curve from the spring to the crown.
                let q = j == 0 ? 0 : Float(j - 1) / Float(rings - 2) * .pi / 2
                let curve = height - spring
                y = j == 0 ? base : base + spring + curve * sin(q)
                k = shortest * (1 - cos(q))
                rise = simd_normalize(SIMD2(curve * cos(q), shortest * sin(q)))
            case .walls:
                y = base + height * f
                k = 0
                rise = SIMD2(1, 0)
            }
            if let last { climbed += simd_distance(last, SIMD2(k, y)) }
            last = SIMD2(k, y)
            let half = simd_max(halfSize - k, .zero)
            top = []
            for i in 0...around {
                let arc = i == around ? perimeter : stops[i]
                let (p, n) = perimeterPoint(arc)
                let at = simd_clamp(p - n * k, -half, half)
                let point = SIMD3(center.x + at.x, y, center.y + at.y)
                let normal = SIMD3(n.x * rise.x, rise.y, n.y * rise.x)
                vertices.append(.init(positionAndU: SIMD4(point, arc), normalAndV: SIMD4(normal, climbed)))
                top.append(point)
            }
        }
        let crown = SIMD3(center.x, self.top, center.y)
        vertices.append(.init(positionAndU: SIMD4(crown, crown.x), normalAndV: SIMD4(0, 1, 0, crown.z)))
        for point in top {
            vertices.append(.init(positionAndU: SIMD4(point, point.x), normalAndV: SIMD4(0, 1, 0, point.z)))
        }
        return vertices
    }
}
