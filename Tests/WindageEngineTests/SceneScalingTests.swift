import Testing
import Metal
import AppKit
@testable import WindageEngine

struct SceneScalingTests {
    @Test("Native draws the scene at the drawable's size")
    func nativeIsTheDrawable() {
        #expect(SceneScaling.native.sceneSize(drawableWidth: 3840, drawableHeight: 2160) == (3840, 2160))
    }

    @Test("Capped draws past the threshold at the capped width, keeping the shape")
    func cappedKeepsTheShape() {
        let capped = SceneScaling.capped(width: 1920, beyond: 2600)
        #expect(capped.sceneSize(drawableWidth: 3840, drawableHeight: 2160) == (1920, 1080))
        #expect(capped.sceneSize(drawableWidth: 3024, drawableHeight: 1964) == (1920, 1247))
    }

    @Test("A drawable just over the cap is not stretched")
    func justOverIsLeftAlone() {
        let capped = SceneScaling.capped(width: 1920, beyond: 2600)
        #expect(capped.sceneSize(drawableWidth: 1960, drawableHeight: 1490) == (1960, 1490))
        #expect(capped.sceneSize(drawableWidth: 2600, drawableHeight: 1600) == (2600, 1600))
    }

    @Test("A fraction draws the scene that much smaller each way, at any size")
    func fractionScalesEveryDrawable() {
        #expect(SceneScaling.fraction(0.5).sceneSize(drawableWidth: 1960, drawableHeight: 1490) == (980, 745))
        #expect(SceneScaling.fraction(0.75).sceneSize(drawableWidth: 3840, drawableHeight: 2160) == (2880, 1620))
        #expect(SceneScaling.fraction(1).sceneSize(drawableWidth: 1200, drawableHeight: 800) == (1200, 800))
        #expect(SceneScaling.fraction(0.0001).sceneSize(drawableWidth: 100, drawableHeight: 50) == (1, 1))
    }

    /// A game that draws nothing: the frame is the clear colour, through the scaled tone map.
    private final class Empty: GameLoop {
        var sizes: [(Int, Int)] = []
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) { sizes.append((width, height)) }
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @Test("A scaled frame drawn into a texture is the scene, scaled — every pixel the clear colour")
    @MainActor
    func aScaledFrameIsWhole() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        let game = Empty()
        renderer.game = game
        renderer.toneMapping = .off
        renderer.clearColor = MTLClearColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        renderer.sceneScaling = .capped(width: 100, beyond: 300)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 400, height: 200, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)

        #expect(renderer.sceneSize == (100, 50), "the scene is drawn at the capped size")
        #expect(game.sizes.last.map { $0 == (400, 200) } == true, "the game is told the drawable's size, not the scene's")
        var pixels = [UInt8](repeating: 0, count: 400 * 200 * 4)
        target.getBytes(&pixels, bytesPerRow: 400 * 4, from: MTLRegionMake2D(0, 0, 400, 200), mipmapLevel: 0)
        // BGRA, sRGB-encoded: linear 0.25, 0.5, 0.75 are about 137, 188, 225.
        let first = Array(pixels[0..<4])
        #expect(abs(Int(first[0]) - 225) <= 2 && abs(Int(first[1]) - 188) <= 2 && abs(Int(first[2]) - 137) <= 2,
                "\(first)")
        for i in stride(from: 0, to: pixels.count, by: 4) where Array(pixels[i..<i + 4]) != first {
            Issue.record("pixel \(i / 4) is \(Array(pixels[i..<i + 4])), not \(first)")
            break
        }
    }
}

/// **A game that reads the solid scene** (``GameLoop/wantsOpaqueTextures``): the second pass is given copies at the
/// scene's size, and what the solid pass drew comes through it untouched, at one sample and at four.
@Suite("Opaque textures")
struct OpaqueTexturesTests {
    private final class Reader: GameLoop {
        var given: [(Int, Int, Int, Int)] = []
        var wantsOpaqueTextures: Bool { true }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
        func encodeTransparent(into encoder: MTL4RenderCommandEncoder, opaque: OpaqueTextures, frameSlot: Int,
                               interpolation: Float) {
            given.append((opaque.colour.width, opaque.colour.height, opaque.depth.width, opaque.depth.sampleCount))
        }
    }

    @Test("The second pass gets the copies, and the solid pass's picture comes through it", arguments: [1, 4])
    @MainActor
    func theSolidSceneComesThrough(samples: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        let game = Reader()
        renderer.game = game
        renderer.toneMapping = .off
        renderer.sampleCount = samples
        renderer.clearColor = MTLClearColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 48, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)
        renderer.render(into: target)

        #expect(game.given.count == 2, "the second pass ran once a frame")
        #expect(game.given.allSatisfy { $0 == (64, 48, 64, 1) }, "copies at the scene's size, one sample: \(game.given)")
        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
        target.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 48), mipmapLevel: 0)
        let corner = Array(pixels[0..<4]), middle = Array(pixels[(24 * 64 + 32) * 4..<(24 * 64 + 32) * 4 + 4])
        #expect(abs(Int(corner[0]) - 225) <= 2 && abs(Int(corner[1]) - 188) <= 2 && abs(Int(corner[2]) - 137) <= 2,
                "\(corner)")
        #expect(corner == middle)
    }
}

/// The engine's frame check: a PNG of the frame, and frames timed.
@Suite("Frame check")
struct FrameCheckTests {
    private final class Clear: GameLoop {
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @Test("A frame comes out as a PNG of the size asked, and frames time in sorted order")
    @MainActor
    func pngAndTiming() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        let game = Clear()
        renderer.game = game
        let png = try #require(renderer.pngFrame(width: 40, height: 30))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG")
        let image = try #require(NSImage(data: png))
        #expect(image.representations.first?.pixelsWide == 40 && image.representations.first?.pixelsHigh == 30)
        let times = renderer.timeFrames(width: 40, height: 30, count: 5, warmUp: 1)
        #expect(times.count == 5 && times == times.sorted())
    }
}
