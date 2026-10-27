import Testing
import Metal
import simd
@testable import WindageEngine

struct DaySkyTests {
    @Test("The sun rises in the east, passes south and sets in the west")
    func theSunCrossesTheSky() {
        let dawn = DaySky.sunDirection(at: 6.01).direction
        let noon = DaySky.sunDirection(at: 12).direction
        let dusk = DaySky.sunDirection(at: 17.99).direction
        #expect(dawn.x > 0.99 && abs(dawn.y) < 0.01)
        #expect(noon.z > 0 && abs(noon.x) < 1e-4)
        #expect(abs(asin(noon.y) - DaySky.noonElevation) < 1e-4)
        #expect(dusk.x < -0.99)
        #expect(DaySky.sunDirection(at: 0).elevation < 0, "midnight is below the horizon")
    }

    @Test("Noon is bright, midnight dark but not black, and lit by a moon above the horizon")
    func noonAndMidnight() {
        let noon = DaySky(timeOfDay: 12).lighting, night = DaySky(timeOfDay: 0).lighting
        #expect(simd_reduce_max(noon.colour) > 2.5)
        #expect(simd_reduce_max(night.colour) < 0.3 && simd_reduce_max(night.colour) > 0)
        #expect(night.direction.y > 0)
        #expect(noon.exposureStops == 0 && night.exposureStops > 1, "the exposure opens as the light falls")
    }

    @Test("Dawn and dusk are warm")
    func dawnAndDuskAreWarm() {
        for hours: Float in [6.4, 17.6] {
            let light = DaySky(timeOfDay: hours).lighting.colour
            #expect(light.x > light.z * 2, "\(hours) h is warm: \(light)")
        }
    }

    @Test("Time wraps round the clock")
    func timeWraps() {
        #expect(DaySky(timeOfDay: 25).lighting == DaySky(timeOfDay: 1).lighting)
        #expect(DaySky(timeOfDay: -1).lighting == DaySky(timeOfDay: 23).lighting)
    }

    @Test("The light changes smoothly through the day")
    func smoothThroughTheDay() {
        var previous = DaySky(timeOfDay: 0).lighting
        for step in 1...480 {
            let now = DaySky(timeOfDay: Float(step) * 0.05).lighting
            #expect(simd_distance(now.colour, previous.colour) < 0.5, "a jump at \(Float(step) * 0.05) h")
            previous = now
        }
    }

    @Test("A sun set by hand lights from where it is put, with the sky of its height")
    func sunByHand() {
        let sun = DaySky.Sun(heading: 90, height: 30, colour: SIMD3(1, 0.5, 0.25), brightness: 2)
        let light = DaySky(timeOfDay: 3, sun: sun).lighting
        #expect(simd_distance(light.direction, simd_normalize(SIMD3(cos(Float.pi / 6), sin(Float.pi / 6), 0))) < 1e-4)
        #expect(light.colour == SIMD3(2, 1, 0.5))
        #expect(light.elevation > 0.5)
    }

    @Test("Fog is none by default, half at about 104 m at 0.008, and grows with distance")
    func fog() {
        #expect(DaySky().fog(atDistance: 500) == 0)
        let sky = DaySky(fogDensity: 0.008)
        #expect(abs(sky.fog(atDistance: 104) - 0.5) < 0.01)
        #expect(sky.fog(atDistance: 50) < sky.fog(atDistance: 100) && sky.fog(atDistance: 250) > 0.95)
    }

    /// The sky drawn through a whole frame: blue-ish above the horizon, the ground's dark colour below.
    private final class SkyOnly: GameLoop {
        let pass: SkyPass
        init(_ pass: SkyPass) { self.pass = pass }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let projection = simd_float4x4(perspectiveFovY: 1.2, aspectRatio: 1, nearZ: 0.1)
            pass.encode(into: encoder, frameSlot: frameSlot, viewProjection: projection, eye: .zero,
                        lighting: DaySky(timeOfDay: 15).lighting)
        }
    }

    @Test("SkyPass draws the zenith's side above the horizon and the ground's below")
    @MainActor
    func theSkyIsDrawn() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        let pass = try SkyPass(device: device)
        renderer.residencySet.addAllocations(pass.allocations)
        let game = SkyOnly(pass)
        renderer.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)
        func pixel(_ y: Int) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 4)
            target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(32, y, 1, 1), mipmapLevel: 0)
            return p   // BGRA
        }
        let above = pixel(4), below = pixel(60)
        #expect(Int(above[0]) > Int(above[2]), "above the horizon is bluer than red: \(above)")
        #expect(Int(above[0]) > Int(below[0]) + 40, "the ground below is darker: above \(above), below \(below)")
    }

    /// A game that turns multisampling on from its own settings, in its pre-passes, on its first frame.
    private final class TurnsOnMultisampling: GameLoop {
        let pass: SkyPass
        weak var renderer: FrameRenderer?
        init(_ pass: SkyPass) { self.pass = pass }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encodePrePasses(into commandBuffer: MTL4CommandBuffer, frameSlot: Int, interpolation: Float) {
            renderer?.sampleCount = 4
        }
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let projection = simd_float4x4(perspectiveFovY: 1.2, aspectRatio: 1, nearZ: 0.1)
            pass.encode(into: encoder, frameSlot: frameSlot, viewProjection: projection, eye: .zero,
                        lighting: DaySky(timeOfDay: 15).lighting)
        }
    }

    /// **A sample count changed in the pre-passes applies to that same frame** (2026-10-26). The targets were made before
    /// the pre-passes; drawn into as they were, 4× pipelines met 1× targets — Metal's validation stops the game there, and
    /// without validation the frame is undefined. Run the suite with `MTL_DEBUG_LAYER=1` to hold it to that.
    @Test("Multisampling turned on in the pre-passes draws that frame multisampled")
    @MainActor
    func sampleCountChangedInPrePasses() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4), device.supportsTextureSampleCount(4)
        else { return }
        let renderer = try FrameRenderer(device: device)
        let pass = try SkyPass(device: device, sampleCount: 4)
        renderer.residencySet.addAllocations(pass.allocations)
        let game = TurnsOnMultisampling(pass)
        game.renderer = renderer
        renderer.game = game
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        #expect(renderer.effectiveSampleCount == 1)
        renderer.render(into: target)
        #expect(renderer.effectiveSampleCount == 4)
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 256, from: MTLRegionMake2D(32, 4, 1, 1), mipmapLevel: 0)
        #expect(pixel.contains { $0 > 20 }, "the sky was drawn: \(pixel)")
    }

    /// **Multisampled, the same sky** (2026-10-26): the scene drawn at four samples a pixel and resolved into the target
    /// the tone map reads. The sky has no edges to smooth, so it comes out as it does at one sample — which proves the
    /// targets, the resolve and a pipeline built for the count all fit together.
    @Test("At four samples a pixel the scene is drawn, resolved and shown as at one")
    @MainActor
    func multisampledIsTheSame() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        func draw(samples: Int) throws -> [UInt8] {
            let renderer = try FrameRenderer(device: device)
            renderer.sampleCount = samples
            let pass = try SkyPass(device: device, sampleCount: renderer.effectiveSampleCount)
            renderer.residencySet.addAllocations(pass.allocations)
            let game = SkyOnly(pass)
            renderer.game = game
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                      width: 64, height: 64, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = .shared
            let target = try #require(device.makeTexture(descriptor: descriptor))
            renderer.residencySet.addAllocation(target)
            renderer.commitResidency()
            renderer.render(into: target)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            target.getBytes(&pixels, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return pixels
        }
        let one = try draw(samples: 1), four = try draw(samples: 4)
        let worst = zip(one, four).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "the multisampled sky differs by \(worst) somewhere")
        #expect(one.contains { $0 > 20 }, "not two black frames")
    }
}

@Suite("A world's own sky")
struct DaySkyLookTests {

    @Test("The engine's own look changes nothing, and the sky's light is its zenith")
    func defaultsChangeNothing() {
        for hour in stride(from: Float(0), to: 24, by: 1.5) {
            let lighting = DaySky(timeOfDay: hour).lighting
            #expect(lighting.skyLight == lighting.zenith)
        }
    }

    /// **The sky drawn, not the light it casts** — a deeper sky must not darken a world's shadows.
    @Test("A deeper sky is bluer and darker overhead, and lights the world the same")
    func deeperSkyKeepsItsLight() {
        let plain = DaySky(timeOfDay: 13).lighting
        let deep = DaySky(timeOfDay: 13, saturation: 2.5, zenithBrightness: 0.5).lighting
        #expect(deep.skyLight == plain.zenith, "the light from above changed with the look")
        #expect(deep.colour == plain.colour && deep.ground == plain.ground)
        let luma = { (c: SIMD3<Float>) in simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
        #expect(abs(luma(deep.horizon) - luma(plain.horizon)) < 1e-4, "saturation moved the horizon's brightness")
        #expect(deep.horizon.z - deep.horizon.x > plain.horizon.z - plain.horizon.x, "the horizon is no bluer")
        #expect(luma(deep.zenith) < luma(plain.zenith) * 0.6, "the zenith is no darker")
        #expect(simd_reduce_min(deep.zenith) >= 0 && simd_reduce_min(deep.horizon) >= 0, "a colour went negative")
    }
}
