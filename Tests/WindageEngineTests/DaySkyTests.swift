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
}
