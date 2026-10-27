//
//  ParticleLifeTests.swift
//  WindageEngineTests
//

import Foundation
import Metal
import Testing
import simd
@testable import WindageEngine

/// Particles that live: a swarm that wanders and stays put, fades in, beats its wings and is drawn from a sprite.
@Suite("Living particles")
struct ParticleLifeTests {

    private let butterfly = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 14, size: 0.45,
                                           gravity: 0, drag: 0.5, color: SIMD3(1, 1, 1),
                                           wander: 1.2, wanderRate: 0.25, maxSpeed: 1, spawnRadius: 3,
                                           fadeIn: 1, fadeOut: 1.5, flapRate: 6, sprite: 2, aspect: 1.2,
                                           alignment: .velocity, axis: SIMD3(0, 0, 1), stretch: 0.3)

    private func swarm(seconds: Float = 20) -> ParticleSystem {
        var system = ParticleSystem(recipes: [butterfly], capacity: 64)
        var emitter = ParticleEmitter(recipe: 0, rate: 1, seedBase: 7)
        emitter.prewarm(&system, at: SIMD3(10, 2, -5), seconds: seconds)
        return system
    }

    @Test("A prewarmed swarm is already flying, near where it was born, never faster than its top speed")
    func swarmStaysNear() {
        let system = swarm()
        #expect(system.liveCount >= 10, "prewarming twenty seconds left \(system.liveCount)")
        for particle in system.live {
            #expect(simd_length(particle.velocity) <= 1.0001, "faster than its top speed")
            // Born within 3 m, and at 1 m/s at most for its life — a loose bound; most are far closer.
            #expect(simd_distance(particle.position, SIMD3(10, 2, -5)) < 3 + particle.age * 1.0001)
        }
        let moving = system.live.filter { simd_length($0.velocity) > 0.05 }
        #expect(moving.count > system.liveCount / 2, "a wanderer that does not wander")
    }

    @Test("The same swarm flies the same way twice, and its members do not move as one")
    func deterministicAndIndividual() {
        let a = swarm(), b = swarm()
        #expect(zip(a.live, b.live).allSatisfy { simd_distance($0.position, $1.position) < 1e-5 })
        let headings = Set(a.live.map { Int((atan2($0.velocity.z, $0.velocity.x) * 4).rounded()) })
        #expect(headings.count > 4, "the swarm heads one way")
    }

    @Test("A spawn radius spreads births through a sphere")
    func spawnRadius() {
        var system = ParticleSystem(recipes: [butterfly], capacity: 400)
        for seed in 0..<300 { system.burst(0, at: .zero, seed: seed) }
        let distances = system.live.map { simd_length($0.position) }
        #expect(distances.allSatisfy { $0 <= 3.0001 })
        #expect(distances.filter { $0 > 1.5 }.count > 150, "crowded at the middle: a sphere fills from its edge")
    }

    @Test("It fades in rather than appearing, and its wings beat between a quarter and full width")
    func fadeInAndFlap() {
        var system = ParticleSystem(recipes: [butterfly], capacity: 4)
        system.burst(0, at: .zero, seed: 1)
        let born = system.appearance(of: system.live[0]).coverage
        system.step(deltaTime: 0.5)
        let half = system.appearance(of: system.live[0]).coverage
        system.step(deltaTime: 1)
        let full = system.appearance(of: system.live[0]).coverage
        #expect(born == 0 && half > 0.3 && half < 0.7 && full > 0.85, "\(born), \(half), \(full)")
        var widths: [Float] = []
        for _ in 0..<60 { system.step(deltaTime: 1.0 / 60); widths.append(system.width(of: system.live[0])) }
        #expect(widths.min()! < 0.35 && widths.max()! > 0.95 && widths.allSatisfy { $0 >= 0.25 && $0 <= 1 })
        var still = ParticleSystem(recipes: [ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 1, size: 1,
                                                            color: .one)], capacity: 1)
        still.burst(0, at: .zero, seed: 1)
        #expect(still.width(of: still.live[0]) == 1)
    }

    @Test("A fade-out keeps it solid until its last seconds, then takes it away")
    func fadeOut() {
        var system = ParticleSystem(recipes: [ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 1,
                                                             gravity: 0, drag: 0, color: .one, fade: 0, fadeOut: 2)],
                                    capacity: 1)
        system.burst(0, at: .zero, seed: 1)
        let life = system.live[0].lifetime
        system.step(deltaTime: life * 0.5)
        #expect(system.appearance(of: system.live[0]).coverage == 1, "faded before its last seconds")
        system.step(deltaTime: life * 0.5 - 1)
        let late = system.appearance(of: system.live[0]).coverage
        #expect(abs(late - 0.5) < 0.02, "a second from the end of a two-second fade-out: \(late)")
    }

    @Test("Square to the view by default, as tall as its aspect, along its motion stretched by speed, and along an axis")
    func alignments() {
        let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
        func extent(_ recipe: ParticleRecipe, velocity: SIMD3<Float> = .zero) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
            var system = ParticleSystem(recipes: [recipe], capacity: 1)
            system.burst(0, at: .zero, direction: velocity == .zero ? SIMD3(0, 1, 0) : velocity, seed: 1)
            return system.extent(of: system.live[0], cameraRight: right, cameraUp: up)
        }
        let size: Float = 2
        let facing = extent(ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 9, size: size, color: .one, aspect: 1.5))
        let s0 = facing.right.x * 2   // the burst varies size by ±30%; read the width it gave
        #expect(facing.right.y == 0 && abs(facing.up.y - s0 * 0.75) < 1e-4, "\(facing)")

        let wind = extent(ParticleRecipe(count: 1, speed: 10, spread: 0, lifetime: 9, size: size, gravity: 0, drag: 0,
                                         color: .one, alignment: .velocity, stretch: 0.1), velocity: SIMD3(1, 0, 0))
        #expect(abs(simd_normalize(wind.up).x) > 0.999, "a streak lies along its motion: \(wind.up)")
        #expect(simd_length(wind.up) > simd_length(wind.right) + 0.2, "and is stretched by its speed")
        #expect(abs(simd_dot(wind.right, wind.up)) < 1e-4)

        let sun = simd_normalize(SIMD3<Float>(0.3, 1, 0.2))
        let beam = extent(ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 9, size: size, color: .one,
                                         alignment: .axis, axis: sun))
        #expect(simd_distance(simd_normalize(beam.up), sun) < 1e-4, "a shaft leans along the sun")
        #expect(abs(simd_dot(beam.right, sun)) < 1e-4 && abs(beam.right.z) < 1e-4, "and turns to face the view")
    }

    @Test("A recipe survives being saved, and a file that names only a colour takes the defaults")
    func codable() throws {
        let back = try JSONDecoder().decode(ParticleRecipe.self, from: JSONEncoder().encode(butterfly))
        #expect(back == butterfly)
        let minimal = try JSONDecoder().decode(ParticleRecipe.self, from: Data(#"{"color":[1,0.5,0]}"#.utf8))
        #expect(minimal.maxSpeed == .infinity && minimal.sprite == nil && minimal.wander == 0 && minimal.lifetime == 1)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ParticleRecipe.self, from: Data("{}".utf8)) }
    }

    @Test("Prewarming several emitters together ages each swarm only by its own seconds")
    func prewarmTogether() {
        var system = ParticleSystem(recipes: [butterfly], capacity: 128)
        var emitters = [ParticleEmitter(recipe: 0, rate: 1, seedBase: 1), ParticleEmitter(recipe: 0, rate: 1, seedBase: 2)]
        ParticleEmitter.prewarm(&emitters, at: [SIMD3(0, 0, 0), SIMD3(50, 0, 0)], into: &system, seconds: 10)
        let near = system.live.filter { $0.position.x < 25 }, far = system.live.filter { $0.position.x >= 25 }
        #expect(near.count >= 8 && far.count >= 8, "\(near.count) and \(far.count)")
        #expect(system.live.allSatisfy { $0.age <= 10.05 }, "a swarm aged past its prewarm")
    }
}

@Suite("Particle sprites")
struct ParticleSpriteTests {

    private final class OneSprite: GameLoop {
        let renderer: ParticleRenderer
        var system: ParticleSystem
        init(_ renderer: ParticleRenderer) {
            self.renderer = renderer
            system = ParticleSystem(recipes: [ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 2,
                                                             gravity: 0, drag: 0, color: .one, sprite: 1)],
                                    capacity: 4)
            system.burst(0, at: SIMD3(0, 0, -3), seed: 1)
        }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {
            let projection = simd_float4x4(perspectiveFovY: 1.2, aspectRatio: 1, nearZ: 0.1)
            renderer.draw(system, into: encoder, frameSlot: frameSlot, viewProjection: projection,
                          cameraRight: SIMD3(1, 0, 0), cameraUp: SIMD3(0, 1, 0))
        }
    }

    /// A two-cell sheet, red then green: the particle names cell 1, so it must come out green — the right cell, its
    /// own colour, at one and four samples a pixel.
    @Test("A particle with a sprite is drawn in its cell's colour", arguments: [1, 4])
    @MainActor
    func spriteDrawn(samples: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4),
              device.supportsTextureSampleCount(samples) else { return }
        let sheet = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 4, mipmapped: false)
        sheet.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: sheet))
        var texels: [UInt8] = []
        for _ in 0..<4 { for x in 0..<8 { texels += x < 4 ? [255, 0, 0, 255] : [0, 255, 0, 255] } }
        texture.replace(region: MTLRegionMake2D(0, 0, 8, 4), mipmapLevel: 0, withBytes: texels, bytesPerRow: 32)

        let frame = try FrameRenderer(device: device)
        frame.sampleCount = samples
        frame.toneMapping = .off
        let particles = try ParticleRenderer(device: device, capacity: 4, sampleCount: frame.effectiveSampleCount,
                                             sprites: texture, atlas: DecalAtlas(columns: 2, rows: 1))
        frame.residencySet.addAllocations(particles.allocations)
        let game = OneSprite(particles)
        frame.game = game
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat, width: 64,
                                                              height: 64, mipmapped: false)
        target.usage = .renderTarget
        target.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: target))
        frame.residencySet.addAllocation(output)
        frame.commitResidency()
        frame.render(into: output)
        var pixel = [UInt8](repeating: 0, count: 4)
        output.getBytes(&pixel, bytesPerRow: 256, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        // BGRA: green, not red.
        #expect(Int(pixel[1]) > 150 && Int(pixel[2]) < 60, "the sprite's centre is \(pixel)")
    }
}
