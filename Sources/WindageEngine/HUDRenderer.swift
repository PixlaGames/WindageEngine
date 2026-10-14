//
//  HUDRenderer.swift
//  WindageEngine
//

import Foundation
import Metal
import simd

/// Draws the interface, **after** the scene has been tone mapped.
///
/// **The ordering is the point of this type.** A HUD drawn inside the scene's shading would go
/// through exposure and a filmic curve like everything else, and a brand color would arrive on
/// screen desaturated and shifted — quietly, with nothing to indicate why. `FrameRenderer` calls
/// `GameLoop.encodeHUD` after the scene, and this renderer's pipeline applies no curve, so a
/// ``InterfaceColor`` lands as the exact value it was authored as.
///
/// **What this is not.** There is no layout, no widgets and no event handling. It draws colored
/// rectangles, lines, rings, filled outlines and text in screen space, which is enough for a reticle,
/// a bar, a panel, a marker or a label.
///
/// **Every position is a `SIMD2<Float>`**, in the units ``begin(viewportSize:)`` was given, and every
/// call names the shape it draws: ``fillRect(origin:size:color:)``, ``strokeRect(origin:size:thickness:color:)``,
/// ``line(from:to:thickness:color:)``, ``fillRing(center:innerRadius:outerRadius:segments:color:)``,
/// ``fillPolygon(_:color:feather:)`` and ``text(_:atBaseline:pointSize:color:)``. Layout arrives when a title actually needs it and can show
/// what shape it should be — the same extract-when-proven rule as everything else here.
/// Why a ``HUDRenderer`` could not be made.
public enum HUDRendererError: Error, CustomStringConvertible, Sendable {
    /// The glyph sheet could not be built — see ``FontAtlasError``.
    case fontAtlas(FontAtlasError)
    /// The HUD's shaders would not compile or its pipeline would not build.
    case pipeline(underlying: any Error)
    /// The device would not create one of the HUD's objects — named here.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .fontAtlas(let error): "the HUD's font atlas could not be built — \(error)"
        case .pipeline(let error): "the HUD's pipeline could not be built — \(error)"
        case .couldNotCreate(let what): "the device would not create the HUD's \(what)"
        }
    }
}

public final class HUDRenderer {

    /// Vertices reserved per frame in flight: six per rectangle, six per glyph.
    ///
    /// **Anything past this in one frame is not drawn**, and the log says so once. Set by the game at
    /// init, because what fits depends on how much text it puts up.
    public let maxVerticesPerFrame: Int

    /// Whether the log has already been told this HUD ran out of vertices.
    private var warnedAboutTruncation = false

    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let argumentTable: MTL4ArgumentTable
    private let vertexBuffer: MTLBuffer

    /// Screen-space geometry accumulated this frame, in normalized device coordinates.
    private var vertices: [Vertex] = []
    private var viewportSize = SIMD2<Float>(1, 1)

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
    }

    /// The glyph sheet, which also supplies the opaque texel solid shapes sample.
    public let font: FontAtlas

    private static let vertexStride = MemoryLayout<Vertex>.stride

    /// - Parameters:
    ///   - additionalCharacters: anything outside printable ASCII this HUD will draw. Ignored when
    ///     `font` is supplied, since that atlas has already chosen its characters.
    ///   - maxVerticesPerFrame: how much one frame's interface may hold — see ``maxVerticesPerFrame``.
    ///     The default, 8,192, is about 1,300 glyphs.
    /// - Throws: ``HUDRendererError``.
    public init(device: MTLDevice, font: FontAtlas? = nil, additionalCharacters: Set<Character> = [],
                maxVerticesPerFrame: Int = 8192) throws {
        precondition(maxVerticesPerFrame > 0, "A HUD needs room for at least one vertex")
        self.maxVerticesPerFrame = maxVerticesPerFrame
        let atlas: FontAtlas
        if let font {
            atlas = font
        } else {
            do { atlas = try FontAtlas(device: device, additionalCharacters: additionalCharacters) }
            catch let error as FontAtlasError { throw HUDRendererError.fontAtlas(error) }
        }
        self.font = atlas
        if !atlas.unavailableCharacters.isEmpty {
            NSLog("\(Engine.name): the font has no glyph for "
                  + atlas.unavailableCharacters.sorted().map(String.init).joined(separator: " "))
        }

        do {
            // The engine's own shaders — compiled into the bundle by Xcode, or compiled here at
            // startup when the package was built by `swift build`, which produces no metallib at
            // all. See ``ShaderLibrary``; without that fallback the HUD cannot initialise outside
            // Xcode, which is how anybody cloning this repo would first try to run it.
            let library = try ShaderLibrary.make(device: device, bundle: .module, sourceNamed: "HUDShaders")
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())

            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.library = library
            vertexFunction.name = "pgeHUDVertex"
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.library = library
            fragmentFunction.name = "pgeHUDFragment"

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float2
            vertexDescriptor.attributes[0].offset = MemoryLayout<Vertex>.offset(of: \.position)!
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float2
            // Taken from the type, never hand-computed. `SIMD4<Float>` is 16-byte aligned, so this
            // is 16 and not the 8 that "two floats then a colour" suggests — and getting it wrong
            // does not fail, it feeds the shader garbage. Here that read as alpha ≈ 0 and the whole
            // interface silently drew nothing.
            vertexDescriptor.attributes[1].offset = MemoryLayout<Vertex>.offset(of: \.uv)!
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.attributes[2].format = .float4
            vertexDescriptor.attributes[2].offset = MemoryLayout<Vertex>.offset(of: \.color)!
            vertexDescriptor.attributes[2].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = HUDRenderer.vertexStride
            vertexDescriptor.layouts[0].stepFunction = .perVertex

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "HUDPipeline"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.rasterSampleCount = 1
            descriptor.colorAttachments[0].pixelFormat = FrameRenderer.colorPixelFormat
            // Premultiplied alpha, so translucent panels composite over the scene correctly.
            descriptor.colorAttachments[0].blendingState = .enabled
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            pipelineState = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw HUDRendererError.pipeline(underlying: error)
        }

        // The interface sits in front of everything and occludes nothing.
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw HUDRendererError.couldNotCreate("depth state")
        }
        self.depthState = depthState

        guard let buffer = device.makeBuffer(
            length: HUDRenderer.vertexStride * maxVerticesPerFrame * FrameRenderer.maxFramesInFlight,
            options: [.storageModeShared]) else { throw HUDRendererError.couldNotCreate("vertex buffer") }
        buffer.label = "HUDVertices"
        vertexBuffer = buffer

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 2
        tableDescriptor.maxTextureBindCount = 1
        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor) else {
            throw HUDRendererError.couldNotCreate("argument table")
        }
        argumentTable = table
    }

    /// Everything the HUD's draws read, for the residency set.
    public var allocations: [any MTLAllocation] { [vertexBuffer, font.texture] }

    // MARK: - Building a frame

    /// Clears the frame and sets the coordinate space.
    ///
    /// Coordinates have **the origin at the top left**, matching how interfaces are normally
    /// described, and are converted to device coordinates here rather than at every call site.
    ///
    /// - Parameter viewportSize: the drawable's size **in the units the game lays out in** — its pixels,
    ///   as `GameLoop.viewportSizeChanged(width:height:)` reports them, or points if the game divides
    ///   by the backing scale first. Every position and size after this is in the same units.
    public func begin(viewportSize: SIMD2<Float>) {
        vertices.removeAll(keepingCapacity: true)
        self.viewportSize = SIMD2(max(viewportSize.x, 1), max(viewportSize.y, 1))
    }

    /// A filled rectangle, `origin` its top-left corner.
    public func fillRect(origin: SIMD2<Float>, size: SIMD2<Float>, color: InterfaceColor) {
        guard color.srgb.w > 0, size.x > 0, size.y > 0 else { return }
        let topLeft = toDevice(origin)
        let bottomRight = toDevice(origin + size)

        let a = SIMD2(topLeft.x, topLeft.y)
        let b = SIMD2(bottomRight.x, topLeft.y)
        let c = SIMD2(bottomRight.x, bottomRight.y)
        let d = SIMD2(topLeft.x, bottomRight.y)

        for corner in [a, b, c, a, c, d] {
            vertices.append(Vertex(position: corner, uv: font.whiteTexelUV, color: color.linear))
        }
    }

    /// A line of a given thickness, as a rotated quad.
    public func line(from start: SIMD2<Float>, to end: SIMD2<Float>, thickness: Float, color: InterfaceColor) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0, color.srgb.w > 0 else { return }

        let direction = delta / length
        let normal = SIMD2(-direction.y, direction.x) * (thickness * 0.5)

        let corners = [start + normal, end + normal, end - normal, start - normal].map(toDevice)
        for index in [0, 1, 2, 0, 2, 3] {
            vertices.append(Vertex(position: corners[index], uv: font.whiteTexelUV, color: color.linear))
        }
    }

    /// An unfilled rectangle, drawn as four edges `thickness` wide, inside `origin` and `size`.
    public func strokeRect(origin: SIMD2<Float>, size: SIMD2<Float>, thickness: Float, color: InterfaceColor) {
        fillRect(origin: origin, size: SIMD2(size.x, thickness), color: color)
        fillRect(origin: SIMD2(origin.x, origin.y + size.y - thickness), size: SIMD2(size.x, thickness),
                 color: color)
        fillRect(origin: origin, size: SIMD2(thickness, size.y), color: color)
        fillRect(origin: SIMD2(origin.x + size.x - thickness, origin.y), size: SIMD2(thickness, size.y),
                 color: color)
    }

    /// A filled polygon, **concave or convex**, given as its outline in order, either way round.
    ///
    /// **Arrived with the engine's mark (2026-09-15)**, which is a letter and not a set of rectangles. Until
    /// then this renderer drew rectangles, lines, rings and text, and a shape was approximated out of
    /// those — which is how a curve built from quads came out hatched with a hairline seam at every
    /// joint. A polygon is triangulated once, here, and its triangles share their vertices exactly, so
    /// the rasterizer's fill rule leaves no seam between them.
    ///
    /// The outline must be *simple* — no edge crossing another. One that is not is still drawn, but
    /// only in part: see ``triangulate(_:)``.
    ///
    /// **Its edges are feathered**, over `feather` of the HUD's own units — a pixel, when the viewport
    /// is given in pixels as the sample gives it. This pipeline has no multisampling, so a filled shape
    /// with any diagonal in it came out stair-stepped: the engine's mark on its own splash, the first
    /// thing a player sees, with jagged edges at 640 × 400 and visibly so at a window's size. A strip
    /// fading from the color to nothing runs round the outline instead (``rim(of:width:)``); the
    /// shader premultiplies, so the fade composites cleanly over whatever is beneath. Pass 0 for hard
    /// edges — a shape that must tile against its neighbor exactly wants those.
    public func fillPolygon(_ points: [SIMD2<Float>], color: InterfaceColor, feather: Float = 1) {
        guard color.srgb.w > 0, points.count >= 3 else { return }
        let placed = points.map(toDevice)
        let solid = color.linear
        for index in HUDRenderer.triangulate(points) {
            vertices.append(Vertex(position: placed[index], uv: font.whiteTexelUV, color: solid))
        }
        guard feather > 0 else { return }
        let outside = HUDRenderer.rim(of: points, width: feather).map(toDevice)
        var clear = solid
        clear.w = 0
        for i in points.indices {
            let j = (i + 1) % points.count
            for (position, color) in [(placed[i], solid), (placed[j], solid), (outside[j], clear),
                                       (placed[i], solid), (outside[j], clear), (outside[i], clear)] {
                vertices.append(Vertex(position: position, uv: font.whiteTexelUV, color: color))
            }
        }
    }

    /// Every point of a simple outline moved outward by `width` — along the bisector of its two edges,
    /// **mitred** so each edge moves out by the full width, and the mitre held to three widths so the
    /// sharp valleys of a letter do not throw a spike.
    nonisolated static func rim(of points: [SIMD2<Float>], width: Float) -> [SIMD2<Float>] {
        let count = points.count
        guard count >= 3 else { return points }
        var twiceArea: Float = 0
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        // With a positive signed area the inside is where a corner turns positive (see `triangulate`),
        // which puts `(d.y, −d.x)` on the outside of an edge running along `d`.
        let side: Float = twiceArea > 0 ? 1 : -1
        func outward(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let along = b - a
            guard simd_length_squared(along) > 1e-12 else { return .zero }
            let d = simd_normalize(along)
            return SIMD2(d.y, -d.x) * side
        }
        return (0..<count).map { i in
            let point = points[i]
            let before = outward(points[(i + count - 1) % count], point)
            let after = outward(point, points[(i + 1) % count])
            let sum = before + after
            guard simd_length_squared(sum) > 1e-12 else { return point + after * width }
            let bisector = simd_normalize(sum)
            let mitre = min(1 / max(simd_dot(bisector, after), 1e-3), 3)
            return point + bisector * mitre * width
        }
    }

    /// A simple polygon's triangles, as index triples into `points` — `n − 2` triangles for `n` points.
    ///
    /// **Ear clipping, not a fan.** A fan from one vertex is right for a convex shape and wrong for
    /// anything else: fanned from its top-left corner, the engine's own W covers ground outside its
    /// outline and leaves some of its inside empty (`HUDTriangulationTests` measures both). Clipping
    /// takes one convex corner at a time whose triangle holds no other vertex, which every simple
    /// polygon has. `O(n³)` in the worst case, which for an outline of a dozen points is nothing, and
    /// which is why this is for interface shapes and not for meshes.
    ///
    /// Winding-agnostic: the outline's signed area says which way round it goes. **A polygon that is
    /// not simple has no ears at some point**; rather than loop for ever, a vertex is dropped and the
    /// shape drawn short of complete.
    nonisolated static func triangulate(_ points: [SIMD2<Float>]) -> [Int] {
        let count = points.count
        guard count >= 3 else { return [] }
        func turn(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var twiceArea: Float = 0
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        var remaining = Array(0..<count)
        if twiceArea < 0 { remaining.reverse() }

        var triangles: [Int] = []
        triangles.reserveCapacity((count - 2) * 3)
        while remaining.count > 3 {
            var clipped = false
            for i in remaining.indices {
                let before = remaining[(i + remaining.count - 1) % remaining.count]
                let corner = remaining[i]
                let after = remaining[(i + 1) % remaining.count]
                let a = points[before], b = points[corner], c = points[after]
                guard turn(a, b, c) > 0 else { continue }          // reflex, or flat
                let holdsAnother = remaining.contains { j in
                    guard j != before, j != corner, j != after else { return false }
                    let p = points[j]
                    return turn(a, b, p) >= 0 && turn(b, c, p) >= 0 && turn(c, a, p) >= 0
                }
                guard !holdsAnother else { continue }
                triangles += [before, corner, after]
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { remaining.removeFirst() }
        }
        triangles += remaining
        return triangles
    }

    /// Characters already reported as missing, so the log says each one once rather than every frame.
    private nonisolated(unsafe) static var warnedAbout: Set<Character> = []

    /// Draws a line of text with its **left edge and baseline** at `origin`, and returns its width.
    ///
    /// Baseline rather than top edge, because that is the line the eye reads along: two readouts at
    /// the same baseline look aligned even when one contains a comma or a lowercase descender, and
    /// two aligned by their top edges do not.
    /// **`origin.y` is the baseline, not the top** — hence the label. Glyphs are drawn *upward* from it, which is the usual
    /// convention for text rendering and is not what somebody laying out a HUD assumes — passing a
    /// top margin puts the first line's ascenders off the top edge of the screen, which is exactly
    /// what happened to the sample and was reported as the title touching the top. The first line's
    /// `origin.y` wants to be at least one `pointSize` below where you want the text to start.
    @discardableResult
    public func text(_ string: String, atBaseline origin: SIMD2<Float>, pointSize: Float,
                     color: InterfaceColor) -> Float {
        let x = origin.x, y = origin.y
        guard color.srgb.w > 0 else { return width(of: string, pointSize: pointSize) }
        let scale = pointSize / Float(FontAtlas.rasterHeight)
        var penX = x

        for character in string {
            guard let glyph = font.glyph(for: character) else {
                // **Say so, once.** A character the atlas does not carry draws nothing, and a HUD
                // that quietly omits part of a line is a bug that survives being looked at — see
                // `FontAtlas.unavailableCharacters`. The warning is per character, not per frame.
                if HUDRenderer.warnedAbout.insert(character).inserted {
                    NSLog("\(Engine.name): no glyph for '\(character)' — it will not be drawn. "
                          + "Pass it to FontAtlas(additionalCharacters:).")
                }
                continue
            }
            let w = glyph.size.x * scale
            let h = glyph.size.y * scale

            if w > 0 && h > 0 {
                // Bearing is measured from the baseline upward, screen coordinates run downward.
                let left = penX + glyph.bearing.x * scale
                let top = y - (glyph.bearing.y + glyph.size.y) * scale

                let topLeft = toDevice(SIMD2(left, top))
                let bottomRight = toDevice(SIMD2(left + w, top + h))
                let uv0 = glyph.uvOrigin
                let uv1 = glyph.uvOrigin + glyph.uvSize

                // `uvOrigin` is already the glyph's top-left in texture space, so this maps
                // straight across with no flip.
                let corners = [
                    (SIMD2(topLeft.x, topLeft.y), SIMD2(uv0.x, uv0.y)),
                    (SIMD2(bottomRight.x, topLeft.y), SIMD2(uv1.x, uv0.y)),
                    (SIMD2(bottomRight.x, bottomRight.y), SIMD2(uv1.x, uv1.y)),
                    (SIMD2(topLeft.x, bottomRight.y), SIMD2(uv0.x, uv1.y))
                ]
                for index in [0, 1, 2, 0, 2, 3] {
                    vertices.append(Vertex(position: corners[index].0,
                                           uv: corners[index].1,
                                           color: color.linear))
                }
            }
            penX += glyph.advance * scale
        }
        return penX - x
    }

    /// Width of a string without drawing it, for right-aligning or laying out a panel behind it.
    public func width(of string: String, pointSize: Float) -> Float {
        font.width(of: string, pointSize: pointSize)
    }

    /// A filled ring — an annulus — approximated with `segments` quads.
    ///
    /// With a large enough outer radius this is a circular vignette, which is how a scope's sight
    /// picture gets its surround. Drawn as a strip of quads rather than a triangle fan so it needs
    /// no index buffer and no separate primitive type: the whole interface stays one draw call.
    public func fillRing(center: SIMD2<Float>,
                     innerRadius: Float,
                     outerRadius: Float,
                     segments: Int = 96,
                     color: InterfaceColor) {
        guard outerRadius > innerRadius, segments >= 3, color.srgb.w > 0 else { return }
        let step = (2 * Float.pi) / Float(segments)

        for index in 0..<segments {
            let a0 = Float(index) * step
            let a1 = Float(index + 1) * step
            let d0 = SIMD2(cos(a0), sin(a0))
            let d1 = SIMD2(cos(a1), sin(a1))

            let corners = [
                center + d0 * innerRadius,
                center + d1 * innerRadius,
                center + d1 * outerRadius,
                center + d0 * outerRadius
            ].map(toDevice)

            for corner in [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]] {
                vertices.append(Vertex(position: corner, uv: font.whiteTexelUV, color: color.linear))
            }
        }
    }

    /// Points, origin top-left, to normalized device coordinates.
    private func toDevice(_ point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((point.x / viewportSize.x) * 2 - 1,
              1 - (point.y / viewportSize.y) * 2)
    }

    // MARK: - Drawing

    /// Writes this frame's interface into the slot's vertices and draws it.
    ///
    /// - Parameter frameSlot: the slot `GameLoop.encodeHUD` was given, `0..<FrameRenderer.maxFramesInFlight`.
    public func draw(into encoder: MTL4RenderCommandEncoder, frameSlot: Int) {
        precondition((0..<FrameRenderer.maxFramesInFlight).contains(frameSlot),
                     "frameSlot \(frameSlot) is not one of the renderer's \(FrameRenderer.maxFramesInFlight) slots")
        guard !vertices.isEmpty else { return }
        if vertices.count > maxVerticesPerFrame, !warnedAboutTruncation {
            warnedAboutTruncation = true
            NSLog("\(Engine.name): the HUD drew \(vertices.count) vertices in one frame and has room for "
                  + "\(maxVerticesPerFrame); the rest are not drawn. Pass a larger maxVerticesPerFrame.")
        }
        let count = min(vertices.count, maxVerticesPerFrame)
        let offset = HUDRenderer.vertexStride * maxVerticesPerFrame * frameSlot

        vertexBuffer.contents().advanced(by: offset)
            .withMemoryRebound(to: Vertex.self, capacity: count) { destination in
                for index in 0..<count { destination[index] = vertices[index] }
            }

        encoder.pushDebugGroup("HUD")
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setArgumentTable(argumentTable, stages: .vertex)
        encoder.setArgumentTable(argumentTable, stages: .fragment)
        argumentTable.setAddress(vertexBuffer.gpuAddress + UInt64(offset), index: 0)
        argumentTable.setTexture(font.texture.gpuResourceID, index: 0)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: count)
        encoder.popDebugGroup()
    }
}
