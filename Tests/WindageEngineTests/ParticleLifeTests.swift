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

    @Test("A steady trickle of short lives reuses the slots of the dead: the pool stays as big as the most alive at once")
    func deadSlotsAreReused() {
        var foam = butterfly
        foam.lifetime = 1
        foam.wander = 0
        var system = ParticleSystem(recipes: [foam], capacity: 8192)
        var emitter = ParticleEmitter(recipe: 0, rate: 60, seedBase: 3)
        for _ in 0..<(60 * 30) {
            emitter.emit(into: &system, at: .zero, deltaTime: 1.0 / 60)
            system.step(deltaTime: 1.0 / 60)
        }
        // Sixty a second for up to 1.4 s each is under ninety alive; thirty seconds of births is 1,800.
        #expect(system.liveCount > 40 && system.liveCount < 90)
        #expect(system.particles.count < 100, "the pool grew to \(system.particles.count) for \(system.liveCount) alive")
    }

    @Test("A level spawn spreads births across a disc at the origin's height, evenly, and survives being saved")
    func levelSpawn() throws {
        var foam = butterfly
        foam.spawnsLevel = true
        var system = ParticleSystem(recipes: [foam], capacity: 400)
        for seed in 0..<300 { system.burst(0, at: SIMD3(4, 1.5, -2), seed: seed) }
        let births = system.live
        #expect(births.allSatisfy { abs($0.position.y - 1.5) < 1e-5 }, "born above or below the surface")
        let distances = births.map { simd_distance(SIMD2($0.position.x, $0.position.z), SIMD2(4, -2)) }
        #expect(distances.allSatisfy { $0 <= 3.0001 })
        // A disc evenly filled has a quarter of its area inside half its radius.
        let inner = distances.filter { $0 < 1.5 }.count
        #expect(inner > 50 && inner < 100, "\(inner) of 300 inside half the radius")
        let back = try JSONDecoder().decode(ParticleRecipe.self, from: JSONEncoder().encode(foam))
        #expect(back.spawnsLevel)
        #expect(!(try JSONDecoder().decode(ParticleRecipe.self, from: Data(#"{"color":[1,1,1]}"#.utf8))).spawnsLevel)
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

    @Test("Shafts lean along the sun, fade toward evening and are gone at night")
    func shafts() {
        let beam = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 4, color: SIMD3(1, 0.9, 0.7),
                                  glows: true)
        let noonSky = DaySky(timeOfDay: 13).lighting
        let noon = beam.shafts(of: noonSky)
        let evening = beam.shafts(of: DaySky(timeOfDay: 17).lighting)
        let night = beam.shafts(of: DaySky(timeOfDay: 1).lighting)
        #expect(noon.alignment == ParticleRecipe.Alignment.axis)
        #expect(simd_length(noon.axis - noonSky.direction) < 1e-6)
        let before: Float = simd_length(beam.color), after: Float = simd_length(noon.color)
        #expect(abs(after - before) < 0.6 * before)
        #expect(simd_length(evening.color) < after)
        #expect(night.color == SIMD3<Float>.zero)
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

@Suite("Particles that land, and what follows them")
struct ParticleFollowingTests {

    private let step: Float = 1.0 / 60
    /// A leap that lands, followed by a sit that leads to the next leap — a frog crossing the goop, three times over.
    private let leap = ParticleRecipe(count: 1, speed: 6, spread: 0, lifetime: 5, size: 1, gravity: -9.8, drag: 0,
                                      color: .one, alignment: .velocity, lands: true, then: 1, generations: 4, mesh: "Leap")
    private let sit = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 0.5, size: 1, gravity: 0, drag: 0,
                                     color: .one, then: 0, generations: 4, mesh: "Sit")

    @Test("A leap lands at the height it was born at, and what follows is born there, until the line runs out")
    func leapsAndSits() {
        var system = ParticleSystem(recipes: [leap, sit], capacity: 16)
        system.burst(0, at: SIMD3(2, 0.5, -1), seed: 3)
        var sits = 0, deepest = 0, alive = true
        var lastSit: SIMD3<Float>?
        for _ in 0..<(60 * 20) {
            system.step(deltaTime: step)
            for p in system.live {
                deepest = max(deepest, p.generation)
                if p.recipe == 1, p.age == 0 {
                    sits += 1
                    lastSit = p.position
                }
                #expect(p.position.y >= 0.5 - 1e-4, "never below the ground it was born on")
            }
            alive = system.liveCount > 0
        }
        #expect(sits == 2, "leap, sit, leap, sit, leap — the fifth generation throws nothing")
        #expect(deepest == 4)
        #expect(!alive, "the line ran out")
        #expect(abs((lastSit?.y ?? 0) - 0.5) < 1e-4, "sat where it landed")
    }

    @Test("A burst of what follows: as many as it says, and none past its generations")
    func thenCount() {
        let pop = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 0.2, size: 1, gravity: 0, drag: 0, color: .one,
                                 then: 1, thenCount: 3, generations: 1)
        let splash = ParticleRecipe(count: 1, speed: 1, spread: 1, lifetime: 2, size: 0.1, gravity: 0, drag: 0, color: .one)
        var system = ParticleSystem(recipes: [pop, splash], capacity: 16)
        system.burst(0, at: .zero, seed: 1)
        for _ in 0..<30 { system.step(deltaTime: step) }
        #expect(system.live.filter { $0.recipe == 1 }.count == 3)
        #expect(system.live.allSatisfy { $0.generation == 1 })
    }

    @Test("Softness, landing, what follows and a mesh survive being saved; a file without them takes none")
    func saved() throws {
        let data = try JSONEncoder().encode(leap)
        #expect(try JSONDecoder().decode(ParticleRecipe.self, from: data) == leap)
        var soft = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 1, size: 1, color: .one)
        soft.softness = 0.5
        #expect(try JSONDecoder().decode(ParticleRecipe.self, from: JSONEncoder().encode(soft)).softness == 0.5)
        let old = try JSONDecoder().decode(ParticleRecipe.self, from: Data(#"{"color":[1,1,1]}"#.utf8))
        #expect(old.softness == 0 && !old.lands && old.then == nil && old.mesh == nil)
    }

    @Test("A mesh particle is placed at its size, along its motion when it says, square to the world otherwise")
    func meshTransform() {
        var system = ParticleSystem(recipes: [leap, sit], capacity: 4)
        system.burst(0, at: SIMD3(1, 0, 0), direction: SIMD3(0, 1, 0), seed: 9)
        system.step(deltaTime: step)
        let p = system.live[0]
        let m = system.meshTransform(of: p)
        let size = system.appearance(of: p).size
        let forward = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        #expect(abs(simd_length(forward) - size) < 1e-4)
        #expect(simd_distance(forward / size, simd_normalize(p.velocity)) < 1e-4, "nose along its motion")
        #expect(simd_distance(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), p.position) < 1e-6)
        var still = ParticleSystem(recipes: [sit], capacity: 1)
        still.burst(0, at: SIMD3(0, 2, 0), seed: 1)
        let s = still.meshTransform(of: still.live[0])
        #expect(abs(s.columns.0.x - still.live[0].size) < 1e-5 && s.columns.0.y == 0 && s.columns.1.y > 0)
    }

    /// Drawn in the second pass with the solid scene's depth bound: a disc with softness shows (nothing solid behind it),
    /// and a mesh particle beside it draws nothing — the game draws those.
    private final class Soft: GameLoop {
        let renderer: ParticleRenderer
        var system: ParticleSystem
        init(_ renderer: ParticleRenderer) {
            self.renderer = renderer
            var disc = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 2, gravity: 0, drag: 0,
                                      color: .one, glows: true)
            disc.softness = 1
            let mesh = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 2, gravity: 0, drag: 0,
                                      color: .one, glows: true, mesh: "Frog")
            system = ParticleSystem(recipes: [disc, mesh], capacity: 4)
            system.burst(0, at: SIMD3(-0.9, 0, -3), seed: 1)
            system.burst(1, at: SIMD3(0.9, 0, -3), seed: 2)
        }
        var wantsOpaqueTextures: Bool { true }
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
        func encodeTransparent(into encoder: MTL4RenderCommandEncoder, opaque: OpaqueTextures, frameSlot: Int,
                               interpolation: Float) {
            let projection = simd_float4x4(perspectiveFovY: 1.2, aspectRatio: 1, nearZ: 0.1)
            renderer.draw(system, into: encoder, frameSlot: frameSlot, viewProjection: projection,
                          cameraRight: SIMD3(1, 0, 0), cameraUp: SIMD3(0, 1, 0), solidDepth: opaque.depth, nearPlane: 0.1)
        }
    }

    @Test("Drawn over the solid scene with its depth, a soft disc shows and a mesh particle is left to the game")
    @MainActor
    func softAndMesh() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let frame = try FrameRenderer(device: device)
        frame.toneMapping = .off
        let particles = try ParticleRenderer(device: device, capacity: 4, sampleCount: frame.effectiveSampleCount)
        frame.residencySet.addAllocations(particles.allocations)
        let game = Soft(particles)   // held here: the engine keeps its game weakly
        frame.game = game
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat, width: 64,
                                                              height: 64, mipmapped: false)
        target.usage = .renderTarget
        target.storageMode = .shared
        let output = try #require(device.makeTexture(descriptor: target))
        frame.residencySet.addAllocation(output)
        frame.commitResidency()
        frame.render(into: output)
        func pixel(_ x: Int) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: 4)
            output.getBytes(&p, bytesPerRow: 256, from: MTLRegionMake2D(x, 32, 1, 1), mipmapLevel: 0)
            return p
        }
        let disc = pixel(17), mesh = pixel(47)
        #expect(Int(disc[1]) > 100, "the soft disc shows: \(disc)")
        #expect(Int(mesh[0]) + Int(mesh[1]) + Int(mesh[2]) < 30, "the mesh particle is not drawn: \(mesh)")
    }
}

@Suite("A particle over its life")
struct ParticleOverLifeTests {

    @Test("Size, opacity and colour follow their keys in straight lines, held past the ends")
    func curves() {
        var recipe = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 10, size: 2, gravity: 0, drag: 0,
                                    color: SIMD3(1, 0.5, 0.25), opacity: 0.5)
        recipe.sizeOverLife = [SIMD2(0, 0.25), SIMD2(0.5, 1), SIMD2(1, 0.5)]
        recipe.opacityOverLife = [SIMD2(0.1, 1), SIMD2(1, 0)]
        recipe.colourOverLife = [SIMD4(0, 1, 1, 1), SIMD4(1, 0, 0, 1)]
        #expect(ParticleRecipe.curve(recipe.sizeOverLife, at: 0.25) == 0.625)
        #expect(ParticleRecipe.curve(recipe.opacityOverLife, at: 0) == 1, "held before the first key")
        #expect(ParticleRecipe.curve([SIMD2<Float>](), at: 0.3) == 1, "no keys: unchanged")
        var system = ParticleSystem(recipes: [recipe], capacity: 1)
        system.burst(0, at: .zero, seed: 4)
        let lifetime = system.live[0].lifetime
        while system.live.first.map({ $0.progress < 0.5 }) ?? false { system.step(deltaTime: lifetime / 1000) }
        let p = system.live[0], look = system.appearance(of: p)
        #expect(abs(look.size - p.size * ParticleRecipe.curve(recipe.sizeOverLife, at: p.progress)) < 1e-5)
        let opacity = 0.5 * ParticleRecipe.curve(recipe.opacityOverLife, at: p.progress)
        #expect(abs(look.coverage - opacity) < 1e-5)
        let tint = ParticleRecipe.curve(recipe.colourOverLife, at: p.progress)
        #expect(simd_length(look.color - recipe.color * tint * opacity) < 1e-5, "premultiplied, tinted")
    }

    @Test("Unlit and the curves survive being saved; a file without them has none")
    func saved() throws {
        var recipe = ParticleRecipe(count: 1, speed: 0, spread: 0, lifetime: 1, size: 1, color: .one, unlit: true,
                                    sizeOverLife: [SIMD2(0, 0), SIMD2(1, 1)], opacityOverLife: [SIMD2(0.5, 0.4)],
                                    colourOverLife: [SIMD4(0, 0.1, 1, 0.2)])
        recipe.softness = 1
        #expect(try JSONDecoder().decode(ParticleRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
        let old = try JSONDecoder().decode(ParticleRecipe.self, from: Data(#"{"color":[1,1,1]}"#.utf8))
        #expect(!old.unlit && old.sizeOverLife.isEmpty && old.opacityOverLife.isEmpty && old.colourOverLife.isEmpty)
    }
}
