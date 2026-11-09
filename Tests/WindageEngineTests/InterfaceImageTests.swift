import Metal
import Testing
import simd
@testable import WindageEngine

@Suite("Interface images: sliced, filled, clipped")
struct InterfaceImageTests {

    /// The area the triangles cover, on screen.
    private static func area(_ corners: [InterfaceImage.Corner]) -> Float {
        stride(from: 0, to: corners.count - 2, by: 3).reduce(Float(0)) { sum, k in
            let a = corners[k].position, b = corners[k + 1].position, c = corners[k + 2].position
            return sum + abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        }
    }

    @Test("Whole, it is one quad over the rectangle with the whole texture on it")
    func whole() {
        let t = InterfaceImage().triangles(origin: SIMD2(10, 20), size: SIMD2(40, 30), textureSize: SIMD2(64, 64))
        #expect(t.count == 6)
        #expect(Self.area(t) == 1200)
        #expect(t.contains { $0.position == SIMD2(10, 20) && $0.uv == SIMD2(0, 0) })
        #expect(t.contains { $0.position == SIMD2(50, 50) && $0.uv == SIMD2(1, 1) })
    }

    @Test("Sliced, the corners keep their size at the border's scale and the middle stretches")
    func sliced() {
        // A 100-texel frame with a 20-texel border, drawn at half scale over 300 × 80.
        let cut = InterfaceImage(border: SIMD4(20, 20, 20, 20), borderScale: 0.5)
        let t = cut.triangles(origin: .zero, size: SIMD2(300, 80), textureSize: SIMD2(100, 100))
        #expect(t.count == 9 * 6)
        #expect(abs(Self.area(t) - 300 * 80) < 0.01)
        // The top-left corner piece is 10 × 10 on screen and reads texels 0…20.
        #expect(t.contains { $0.position == SIMD2(10, 10) && abs($0.uv.x - 0.2) < 1e-6 && abs($0.uv.y - 0.2) < 1e-6 })
        // The right edge's inner line sits 10 in from the right.
        #expect(t.contains { $0.position.x == 290 && abs($0.uv.x - 0.8) < 1e-6 })
        // Without its middle, a frame covers only its border.
        let frame = InterfaceImage(border: SIMD4(20, 20, 20, 20), borderScale: 0.5, fillsCentre: false)
            .triangles(origin: .zero, size: SIMD2(300, 80), textureSize: SIMD2(100, 100))
        #expect(abs(Self.area(frame) - (300 * 80 - 280 * 60)) < 0.01)
    }

    @Test("A border wider than the rectangle shrinks in proportion rather than overlapping")
    func narrowSlice() {
        let t = InterfaceImage(border: SIMD4(40, 0, 40, 0), borderScale: 1)
            .triangles(origin: .zero, size: SIMD2(40, 10), textureSize: SIMD2(100, 10))
        #expect(abs(Self.area(t) - 400) < 0.01)
        #expect(t.allSatisfy { $0.position.x >= 0 && $0.position.x <= 40 })
    }

    @Test("Filled from a side, it covers that share and reads that share of the texture")
    func sideFills() {
        let left = InterfaceImage(fill: .horizontal(amount: 0.25))
            .triangles(origin: .zero, size: SIMD2(200, 10), textureSize: SIMD2(64, 8))
        #expect(Self.area(left) == 500)
        #expect(left.allSatisfy { $0.position.x <= 50 && $0.uv.x <= 0.25 })
        let right = InterfaceImage(fill: .horizontal(amount: 0.25, fromRight: true))
            .triangles(origin: .zero, size: SIMD2(200, 10), textureSize: SIMD2(64, 8))
        #expect(right.allSatisfy { $0.position.x >= 150 && $0.uv.x >= 0.75 })
        let up = InterfaceImage(fill: .vertical(amount: 0.5))
            .triangles(origin: .zero, size: SIMD2(10, 100), textureSize: SIMD2(8, 64))
        #expect(up.allSatisfy { $0.position.y >= 50 })
        #expect(InterfaceImage(fill: .horizontal(amount: 0)).triangles(origin: .zero, size: SIMD2(1, 1),
                                                                        textureSize: SIMD2(1, 1)).isEmpty)
    }

    @Test("Filled round, a full turn covers the rectangle corners and all, a quarter a quarter of it")
    func radial() {
        let full = InterfaceImage(fill: .radial(amount: 1))
            .triangles(origin: .zero, size: SIMD2(100, 60), textureSize: SIMD2(64, 64))
        #expect(abs(Self.area(full) - 6000) < 0.5)
        // From the top, clockwise, a quarter is the top-right quarter of the rectangle.
        let quarter = InterfaceImage(fill: .radial(amount: 0.25))
            .triangles(origin: .zero, size: SIMD2(100, 60), textureSize: SIMD2(64, 64))
        #expect(abs(Self.area(quarter) - 1500) < 0.5)
        #expect(quarter.allSatisfy { $0.position.x >= 50 - 1e-3 && $0.position.y <= 30 + 1e-3 })
        let other = InterfaceImage(fill: .radial(amount: 0.25, clockwise: false))
            .triangles(origin: .zero, size: SIMD2(100, 60), textureSize: SIMD2(64, 64))
        #expect(other.allSatisfy { $0.position.x <= 50 + 1e-3 && $0.position.y <= 30 + 1e-3 })
        // The texture maps straight across: the centre reads the texture's centre.
        #expect(full.contains { $0.position == SIMD2(50, 30) && $0.uv == SIMD2(0.5, 0.5) })
    }

    @Test("Clipped, only what lies inside is kept, its texture coordinates cut with it")
    func clipped() {
        let t = InterfaceImage().triangles(origin: .zero, size: SIMD2(100, 100), textureSize: SIMD2(64, 64))
        let cut = InterfaceImage.clip(t, to: SIMD2(25, 0), size: SIMD2(50, 100))
        #expect(abs(Self.area(cut) - 5000) < 0.01)
        #expect(cut.allSatisfy { $0.position.x >= 25 && $0.position.x <= 75 })
        #expect(cut.contains { $0.position.x == 25 && abs($0.uv.x - 0.25) < 1e-6 })
        #expect(InterfaceImage.clip(t, to: SIMD2(200, 0), size: SIMD2(10, 10)).isEmpty)
        #expect(InterfaceImage.clip(t, to: SIMD2(-10, -10), size: SIMD2(200, 200)) == t)
    }

    /// A sliced white frame with its middle left out, and a line of text in a second font, clipped.
    private final class Cut: GameLoop {
        let hud: HUDRenderer, frame: MTLTexture, font: FontAtlas
        init(_ hud: HUDRenderer, frame: MTLTexture, font: FontAtlas) { self.hud = hud; self.frame = frame; self.font = font }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            hud.begin(viewportSize: SIMD2(64, 64))
            hud.image(frame, origin: SIMD2(4, 4), size: SIMD2(56, 24),
                      cut: InterfaceImage(border: SIMD4(1, 1, 1, 1), borderScale: 4, fillsCentre: false))
            hud.text("WWWW", atBaseline: SIMD2(0, 60), pointSize: 24, color: InterfaceColor(srgb: SIMD4(1, 1, 1, 1)),
                     font: font, clip: (SIMD2(0, 36), SIMD2(32, 28)))
            hud.fillRect(origin: SIMD2(60, 60), size: SIMD2(4, 4), color: InterfaceColor(srgb: SIMD4(1, 1, 1, 1)))
            hud.draw(into: encoder, frameSlot: frameSlot)
        }
    }

    @Test("Drawn: a sliced frame keeps its border and leaves its middle; text in a second font stops at its clip")
    @MainActor
    func drawn() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let frame = try #require(device.makeTexture(descriptor: descriptor))
        frame.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                      withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
        let renderer = try FrameRenderer(device: device)
        let hud = try HUDRenderer(device: device)
        let second = try FontAtlas(device: device, font: .boldSystemFont(ofSize: FontAtlas.rasterHeight))
        renderer.residencySet.addAllocations(hud.allocations + [frame, second.allocation])
        let game = Cut(hud, frame: frame, font: second)   // the renderer holds its game weakly
        renderer.game = game
        let target = try #require(device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat, width: 64,
                                                             height: 64, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .shared
            return d
        }()))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)
        withExtendedLifetime(game) {}
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var p = [UInt8](repeating: 0, count: 4)
            target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return p.map(Int.init)
        }
        #expect(pixel(5, 16)[1] > 200, "the frame's left edge: \(pixel(5, 16))")
        #expect(pixel(32, 16)[1] < 20, "its middle left out: \(pixel(32, 16))")
        let lit = (0..<32).flatMap { x in (36..<64).map { y in pixel(x, y)[1] } }.filter { $0 > 128 }.count
        let past = (34..<58).flatMap { x in (36..<64).map { y in pixel(x, y)[1] } }.filter { $0 > 128 }.count
        #expect(lit > 20, "the second font's glyphs are drawn inside the clip")
        #expect(past == 0, "nothing past the clip")
        #expect(pixel(62, 62)[1] > 200, "a shape after the text reads the HUD's own sheet again: \(pixel(62, 62))")
    }
}
