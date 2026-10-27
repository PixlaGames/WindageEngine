//
//  DecalTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import Testing
import simd
@testable import WindageEngine

@Suite("Decal set")
struct DecalSetTests {

    /// **A mark lies along the surface it marks.** Aligned to anything else it stands up out of a
    /// hillside like a signpost.
    @Test("The basis lies in the surface, square and unit")
    func basisIsInTheSurface() {
        for normal in [SIMD3<Float>(0, 1, 0), SIMD3(0.3, 0.9, 0.2), SIMD3(1, 0, 0), SIMD3(0, 0, -1)] {
            let n = simd_normalize(normal)
            let (right, up) = DecalSet.basis(normal: normal)
            #expect(abs(simd_dot(right, n)) < 1e-4 && abs(simd_dot(up, n)) < 1e-4, "the basis leaves the surface")
            #expect(abs(simd_length(right) - 1) < 1e-4 && abs(simd_length(up) - 1) < 1e-4)
            #expect(abs(simd_dot(right, up)) < 1e-4, "the basis is not square")
        }
    }

    /// **Lifted off the surface, or it z-fights.**
    @Test("A mark sits just proud of its surface")
    func liftedOffTheSurface() {
        var set = DecalSet()
        set.mark(at: SIMD3(0, 5, 0), normal: SIMD3(0, 2, 0), size: 0.5)
        let y = set.decals[0].position.y
        #expect(y > 5 && y - 5 < 0.1, "\(y - 5) m proud")
        #expect(set.decals[0].normal == SIMD3(0, 1, 0), "the normal is kept unit length")
    }

    @Test("A mark holds, fades, and goes")
    func holdThenFade() {
        var set = DecalSet(holdSeconds: 10, fadeSeconds: 4)
        set.mark(at: .zero, normal: SIMD3(0, 1, 0), size: 1)
        for _ in 0..<99 { set.step(deltaTime: 0.1) }
        #expect(set.opacity(of: set.decals[0]) == 1, "it began fading inside its hold")
        for _ in 0..<21 { set.step(deltaTime: 0.1) }
        let halfway = set.opacity(of: set.decals[0])
        #expect(halfway > 0.4 && halfway < 0.6, "two seconds into a four-second fade: \(halfway)")
        for _ in 0..<25 { set.step(deltaTime: 0.1) }
        #expect(set.count == 0, "a faded mark was kept")
    }

    @Test("By default marks are kept until cleared")
    func keptUntilCleared() {
        var set = DecalSet()
        set.mark(at: .zero, normal: SIMD3(0, 1, 0), size: 1)
        for _ in 0..<10_000 { set.step(deltaTime: 1) }
        #expect(set.count == 1)
        set.clear()
        #expect(set.count == 0)
    }

    /// **The newest mark is the one being looked at.**
    @Test("A full set replaces its oldest mark, never its newest")
    func oldestGoes() {
        var set = DecalSet(capacity: 4)
        for i in 0..<4 {
            set.mark(at: SIMD3(Float(i), 0, 0), normal: SIMD3(0, 1, 0), size: 1)
            set.step(deltaTime: 1)
        }
        set.mark(at: SIMD3(9, 0, 0), normal: SIMD3(0, 1, 0), size: 1)
        #expect(set.count == 4)
        let xs = Set(set.decals.map(\.position.x))
        #expect(xs.contains(9) && !xs.contains(0), "\(xs)")
        // The ring is by age, not by slot: after a removal the next mark still evicts the eldest.
        set.mark(at: SIMD3(10, 0, 0), normal: SIMD3(0, 1, 0), size: 1)
        #expect(!Set(set.decals.map(\.position.x)).contains(1))
    }

    @Test("Every atlas cell is on the sheet, and out-of-range indices are held to it")
    func atlasCells() {
        let atlas = DecalAtlas(columns: 3, rows: 4)
        for column in -1...4 {
            for row in -1...5 {
                let r = atlas.rect(column: column, row: row)
                #expect(r.x >= 0 && r.x + r.z <= 1.0001 && r.y >= 0 && r.y + r.w <= 1.0001, "\(r)")
            }
        }
        #expect(atlas.rect(column: 1, row: 3) == SIMD4(1.0 / 3, 0.75, 1.0 / 3, 0.25))
        #expect(DecalAtlas.whole.rect(column: 0, row: 0) == SIMD4(0, 0, 1, 1))
    }

    @Test("The instance layout is what the shader reads")
    func instanceLayout() {
        #expect(MemoryLayout<DecalRenderer.Instance>.size == 80)
        #expect(MemoryLayout<DecalRenderer.Instance>.stride == 80)
        #expect(MemoryLayout<DecalRenderer.Frame>.size == 80)
    }
}

@Suite("Decal and particle drawing")
struct DecalDrawingTests {

    /// A mark facing the camera three meters ahead, and a puff of white dust in front of it.
    private final class MarkAndDust: GameLoop {
        let decals: DecalRenderer
        let particles: ParticleRenderer
        var set = DecalSet()
        var system: ParticleSystem
        var drawnDecals = 0, drawnParticles = 0
        init(_ decals: DecalRenderer, _ particles: ParticleRenderer) {
            self.decals = decals
            self.particles = particles
            system = ParticleSystem(recipes: [ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 0.2,
                                                             gravity: 0, drag: 0, color: SIMD3(1, 1, 1))],
                                    capacity: 8)
            set.mark(at: SIMD3(0, 0, -3), normal: SIMD3(0, 0, 1), size: 2)
            system.burst(0, at: SIMD3(0.5, 0.5, -2), seed: 1)
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let projection = simd_float4x4(perspectiveFovY: 1.2, aspectRatio: 1, nearZ: 0.1)
            drawnDecals = decals.draw(set, into: encoder, frameSlot: frameSlot, viewProjection: projection)
            drawnParticles = particles.draw(system, into: encoder, frameSlot: frameSlot, viewProjection: projection,
                                            cameraRight: SIMD3(1, 0, 0), cameraUp: SIMD3(0, 1, 0))
        }
    }

    /// **Drawn into the engine's scene at one and four samples a pixel** — the pipelines built for the count
    /// meet the targets the frame renderer made for it. Run under `MTL_DEBUG_LAYER=1` to hold that to Metal's own
    /// validation.
    @Test("A mark is drawn where it lies, in its own colour, at one and four samples a pixel", arguments: [1, 4])
    @MainActor
    func aMarkIsDrawn(samples: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
              device.supportsTextureSampleCount(samples) else { return }
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4,
                                                                       mipmapped: false)
        atlasDescriptor.storageMode = .shared
        atlasDescriptor.usage = .shaderRead
        let atlas = try #require(device.makeTexture(descriptor: atlasDescriptor))
        let red: [UInt8] = (0..<64).map { $0 % 4 == 0 || $0 % 4 == 3 ? 255 : 0 }   // opaque red, RGBA
        atlas.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: red, bytesPerRow: 16)

        let renderer = try FrameRenderer(device: device)
        renderer.sampleCount = samples
        renderer.toneMapping = .off     // the art's own colour, not the default exposure's
        let decals = try DecalRenderer(device: device, texture: atlas, capacity: 4,
                                       sampleCount: renderer.effectiveSampleCount)
        let particles = try ParticleRenderer(device: device, capacity: 8, sampleCount: renderer.effectiveSampleCount)
        renderer.residencySet.addAllocations(decals.allocations + particles.allocations)
        let game = MarkAndDust(decals, particles)
        renderer.game = game

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        renderer.residencySet.addAllocation(target)
        renderer.commitResidency()
        renderer.render(into: target)
        #expect(game.drawnDecals == 1 && game.drawnParticles == 1)

        func pixel(_ x: Int, _ y: Int) -> [Int] {
            var p = [UInt8](repeating: 0, count: 4)
            target.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return p.map(Int.init)   // BGRA
        }
        let centre = pixel(32, 32), corner = pixel(2, 2)
        #expect(centre[2] > 150 && centre[1] < 60 && centre[0] < 60, "the mark is red where it lies: \(centre)")
        #expect(corner[2] < 60, "nothing red off the mark: \(corner)")
    }
}
