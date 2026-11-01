import Metal
import Testing
import simd
@testable import WindageEngine

@Suite("Images in the HUD")
struct HUDImageTests {

    /// A red image on the left, a white rectangle in the middle drawn after it, a green image on the right — then the
    /// red image again, turned a quarter, at the bottom — so each change of texture and back is drawn in order.
    private final class Images: GameLoop {
        let hud: HUDRenderer
        let red: MTLTexture, green: MTLTexture
        init(_ hud: HUDRenderer, red: MTLTexture, green: MTLTexture) {
            self.hud = hud
            self.red = red
            self.green = green
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
        func encodeHUD(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            hud.begin(viewportSize: SIMD2(64, 64))
            hud.image(red, center: SIMD2(12, 16), size: SIMD2(16, 16))
            hud.fillRect(origin: SIMD2(28, 8), size: SIMD2(8, 16), color: InterfaceColor(srgb: SIMD4(1, 1, 1, 1)))
            hud.image(green, center: SIMD2(52, 16), size: SIMD2(16, 16))
            // A half-transparent tint over a wide, short image, turned upright: it covers a tall strip.
            hud.image(red, center: SIMD2(32, 48), size: SIMD2(24, 4), rotation: .pi / 2,
                      color: InterfaceColor(srgb: SIMD4(1, 1, 1, 0.5)))
            hud.draw(into: encoder, frameSlot: frameSlot)
        }
    }

    private static func solid(_ device: MTLDevice, _ rgba: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let pixels = (0..<16).flatMap { _ in rgba }
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 16)
        return texture
    }

    @Test("Each image is drawn in its own colours, where it is put, in the order it was given; a tint fades it")
    @MainActor
    func imagesAreDrawn() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let red = try Self.solid(device, [255, 0, 0, 255]), green = try Self.solid(device, [0, 255, 0, 255])
        let renderer = try FrameRenderer(device: device)
        let hud = try HUDRenderer(device: device)
        renderer.residencySet.addAllocations(hud.allocations + [red, green])
        let game = Images(hud, red: red, green: green)
        renderer.game = game

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)

        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var p = [UInt8](repeating: 0, count: 4)
            target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return p.map(Int.init)   // BGRA
        }
        let left = pixel(12, 16), middle = pixel(32, 16), right = pixel(52, 16)
        #expect(left[2] > 240 && left[1] < 20 && left[0] < 20, "the red image: \(left)")
        #expect(middle[2] > 240 && middle[1] > 240 && middle[0] > 240, "the rectangle after it reads the glyph sheet: \(middle)")
        #expect(right[1] > 240 && right[2] < 20 && right[0] < 20, "the green image: \(right)")
        let tall = pixel(32, 40), beside = pixel(40, 48)
        #expect(tall[2] > 100 && tall[2] < 230, "turned upright and half faded: \(tall)")
        #expect(beside[2] < 20, "a wide image turned a quarter covers nothing beside it: \(beside)")
    }
}
