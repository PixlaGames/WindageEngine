//
//  ParticleSystemTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

private let step: Float = 1.0 / 120

/// Three recipes shaped like the ones the simulation was tuned against: something thrown hard that
/// falls, something slow that hangs, and light that neither falls nor lingers.
private let dirt = ParticleRecipe(count: 24, speed: 7.5, spread: 2.6, lifetime: 1.1, size: 0.7,
                                  color: SIMD3(0.34, 0.30, 0.25), opacity: 0.85, fade: 2)
private let dust = ParticleRecipe(count: 3, speed: 1.6, spread: 0.9, lifetime: 1.3, size: 0.4,
                                  growth: 1.6, color: SIMD3(0.52, 0.49, 0.44), opacity: 0.35)
private let flash = ParticleRecipe(count: 8, speed: 2.2, spread: 1.1, lifetime: 0.06, size: 0.22,
                                   gravity: 0, drag: 0, color: SIMD3(4, 2.9, 1.4), glows: true)

private func system(capacity: Int = 256) -> ParticleSystem {
    ParticleSystem(recipes: [dirt, dust, flash], capacity: capacity)
}

private func run(_ system: inout ParticleSystem, seconds: Float) {
    for _ in 0..<Int((seconds / step).rounded()) { system.step(deltaTime: step) }
}

@Suite("Particle system")
struct ParticleSystemTests {

    @Test("The same burst plays the same way twice")
    func burstsAreDeterministic() {
        var a = system(), b = system()
        a.burst(0, at: SIMD3(1, 0, -3), seed: 7)
        b.burst(0, at: SIMD3(1, 0, -3), seed: 7)
        run(&a, seconds: 0.4); run(&b, seconds: 0.4)
        #expect(a.liveCount == b.liveCount)
        for (p, q) in zip(a.live, b.live) { #expect(simd_distance(p.position, q.position) < 1e-6) }
    }

    @Test("Different seeds throw different bursts")
    func seedsDiffer() {
        var a = system(), b = system()
        a.burst(0, at: .zero, seed: 1)
        b.burst(0, at: .zero, seed: 2)
        run(&a, seconds: 0.3); run(&b, seconds: 0.3)
        let moved = zip(a.live, b.live).filter { simd_distance($0.position, $1.position) > 0.05 }
        #expect(moved.count > a.liveCount / 2)
    }

    /// **The defect that came with the extraction.** `fract(sin(x) × 43758)` in 32-bit floats keeps
    /// about thirteen bits: 300,000 draws gave 8,923 distinct values. A 24-bit output drawn 300,000
    /// times should repeat only by the birthday bound — about three thousand collisions.
    @Test("The spread hash is not quantised")
    func hashHasItsBits() {
        var seen = Set<Float>()
        for seed in 0..<100_000 { for index in 0..<3 { seen.insert(ParticleSystem.hash(seed, index)) } }
        #expect(seen.count > 290_000, "only \(seen.count) distinct values in 300,000 draws")
    }

    @Test("The hash stays in 0 to 1, and is even across it")
    func hashIsUniform() {
        var bins = [Int](repeating: 0, count: 10)
        for seed in 0..<20_000 {
            let h = ParticleSystem.hash(seed, 5)
            #expect(h >= 0 && h < 1)
            bins[min(9, Int(h * 10))] += 1
        }
        #expect(bins.allSatisfy { $0 > 1700 && $0 < 2300 }, "uneven: \(bins)")
    }

    /// Seeds that grow without bound are the normal case for a continuous emitter, which counts.
    @Test("A huge seed is as good as a small one")
    func largeSeedsStillSpread() {
        var small = Set<Float>(), large = Set<Float>()
        for seed in 0..<2000 {
            small.insert(ParticleSystem.hash(seed, 0))
            large.insert(ParticleSystem.hash(seed + 50_000_000, 0))
        }
        #expect(small.count == 2000 && large.count == 2000)
    }

    @Test("Something thrown up comes back down")
    func dirtFalls() {
        var s = system()
        s.burst(0, at: .zero, seed: 3)
        run(&s, seconds: 0.15)
        #expect((s.live.map(\.position.y).max() ?? 0) > 0.15)
        run(&s, seconds: 0.75)
        #expect((s.live.map(\.velocity.y).max() ?? 1) < 0, "nothing is coming back down")
    }

    /// **Gravity per recipe**: light neither falls nor drifts, and is gone almost at once.
    @Test("A recipe with no gravity does not fall")
    func flashIsLight() {
        var s = system()
        s.burst(2, at: SIMD3(0, 1.5, 0), direction: SIMD3(0, 0, -1), seed: 4)
        let start = s.live.map(\.position.y).max() ?? 0
        run(&s, seconds: 0.04)
        #expect((s.live.map(\.position.y).max() ?? 0) >= start - 0.01)
        run(&s, seconds: 0.2)
        #expect(s.liveCount == 0)
    }

    @Test("Everything expires")
    func nothingIsImmortal() {
        var s = system()
        for seed in 0..<6 { s.burst(0, at: .zero, seed: seed) }
        #expect(s.liveCount > 0)
        run(&s, seconds: 4)
        #expect(s.liveCount == 0)
    }

    /// **The newest burst is the one the player is looking at.**
    @Test("A full pool recycles the oldest, and the newest burst survives")
    func newestSurvives() {
        var s = system()
        for i in 0..<40 { s.burst(0, at: SIMD3(Float(i), 0, 0), seed: i) }
        #expect(s.particles.count <= s.capacity)
        #expect(s.live.filter { $0.position.x > 38 }.count == dirt.count,
                "the most recent burst lost particles to keep older ones")
        #expect(s.live.filter { $0.position.x < 1 }.isEmpty, "the oldest burst survived a full pool")
    }

    @Test("A burst follows the direction it is given")
    func followsItsAxis() {
        var up = system(), sideways = system()
        up.burst(0, at: .zero, direction: SIMD3(0, 1, 0), seed: 9)
        sideways.burst(0, at: .zero, direction: SIMD3(1, 0, 0), seed: 9)
        run(&up, seconds: 0.1); run(&sideways, seconds: 0.1)
        #expect(up.live.map(\.position.y).reduce(0, +) / Float(up.liveCount) > 0.1)
        #expect(sideways.live.map(\.position.x).reduce(0, +) / Float(sideways.liveCount) > 0.1)
    }

    @Test("A trickle can be fewer than a burst, never more")
    func countIsClamped() {
        var trickle = system(), greedy = system()
        trickle.burst(0, at: .zero, seed: 1, count: 3)
        greedy.burst(1, at: .zero, seed: 1, count: 500)
        #expect(trickle.liveCount == 3)
        #expect(greedy.liveCount == dust.count)
    }

    @Test("An unknown recipe throws nothing rather than crashing")
    func unknownRecipe() {
        var s = system()
        s.burst(9, at: .zero, seed: 1)
        #expect(s.liveCount == 0)
    }

    // MARK: - Appearance

    /// **Light covers nothing.** Its coverage is zero, which turns the premultiplied blend into an
    /// add — so light and matter share one pipeline.
    @Test("A glowing particle writes no coverage; matter does")
    func glowIsAdditive() {
        var s = system()
        s.burst(2, at: .zero, seed: 1)
        s.burst(1, at: .zero, seed: 2)
        let glow = s.live.first { $0.recipe == 2 }!
        let matter = s.live.first { $0.recipe == 1 }!
        #expect(s.appearance(of: glow).coverage == 0)
        #expect(s.appearance(of: glow).color.x > 1, "a spark should be brighter than white")
        #expect(s.appearance(of: matter).coverage > 0)
    }

    @Test("Opacity fades to nothing, and smoke spreads as it goes")
    func fadesAndGrows() {
        var s = system()
        s.burst(1, at: .zero, seed: 1)
        let born = s.appearance(of: s.live[0])
        run(&s, seconds: 0.5)
        let later = s.appearance(of: s.live[0])
        #expect(later.coverage < born.coverage)
        #expect(later.size > born.size)
    }

    /// **Premultiplied**: the colour already carries the opacity, so a faded particle is dimmer as
    /// well as more transparent, and the blend does not multiply it a second time.
    @Test("Colour is premultiplied by opacity")
    func premultiplied() {
        var s = system()
        s.burst(1, at: .zero, seed: 1)
        let look = s.appearance(of: s.live[0])
        #expect(simd_distance(look.color, dust.color * look.coverage) < 1e-6)
    }

    /// The renderer's instance is two `float4`s; the shader reads exactly that.
    @Test("The instance layout is what the shader reads")
    func instanceLayout() {
        #expect(MemoryLayout<ParticleRenderer.Instance>.size == 32)
        #expect(MemoryLayout<ParticleRenderer.Instance>.stride == 32)
        #expect(MemoryLayout<ParticleRenderer.Instance>.alignment == 16)
        #expect(MemoryLayout<ParticleRenderer.Frame>.size == 96)
    }
}

@Suite("Particle lighting")
struct ParticleLightingTests {

    /// **Dust is an albedo; it needs light.** Under a uniform sky of radiance L with no sun, an
    /// isotropic speck sends the eye exactly L — the average of what arrives.
    @Test("Under a uniform sky with no sun, dust is lit by exactly that sky")
    func uniformSky() {
        let grey = SIMD3<Float>(0.4, 0.5, 0.6)
        let sky = ProceduralSky(zenith: grey, horizon: grey, ground: grey,
                                sunRadiance: .zero, sunAngularRadius: 0.05)
        let light = sky.matterLight
        #expect(simd_distance(light, grey) < 1e-3, "\(light)")
    }

    /// The sun's share is its irradiance spread over the whole sphere, and only that — a sample
    /// landing on the disc would add the disc's radiance, tens of thousands of times the sky's.
    @Test("The sun adds its irradiance over 4π, and is not sampled twice")
    func sunShare() {
        let grey = SIMD3<Float>(repeating: 0.3)
        let dark = ProceduralSky(zenith: grey, horizon: grey, ground: grey,
                                 sunRadiance: .zero, sunAngularRadius: 0.05)
        let lit = ProceduralSky(zenith: grey, horizon: grey, ground: grey,
                                sunRadiance: SIMD3(repeating: 330), sunAngularRadius: 0.05)
        let difference = lit.matterLight - dark.matterLight
        let expected = lit.sunIrradiance / (4 * .pi)
        #expect(simd_distance(difference, expected) < 1e-3, "\(difference) against \(expected)")
    }

    /// Whichever way the sun points, no sample of the lattice may hit it.
    @Test("No sun direction lands on the lattice")
    func sunNeverSampled() {
        for pitch in stride(from: Float(5), through: 90, by: 5) {
            for yaw in stride(from: Float(0), to: 360, by: 15) {
                let sky = ProceduralSky(sunPitchDegrees: pitch, sunYawDegrees: yaw)
                let light = sky.matterLight
                #expect(light.max() < 5, "pitch \(pitch) yaw \(yaw) gave \(light)")
            }
        }
    }
}

@Suite("Particle emitter")
struct ParticleEmitterTests {

    /// **A rate, not "every so many steps".** The same second emits the same number of particles at
    /// any step size.
    @Test("The rate does not depend on the step")
    func rateIsPerSecond() {
        for hz in [30, 60, 120, 240] {
            var s = system(capacity: 4096)
            var emitter = ParticleEmitter(recipe: 1, rate: 12, seedBase: 0)
            let dt = 1 / Float(hz)
            var emitted = 0
            for _ in 0..<(hz * 2) {
                let before = s.particles.count
                emitter.emit(into: &s, at: .zero, deltaTime: dt)
                emitted += s.particles.count - before
            }
            #expect(abs(emitted - 24) <= 1, "\(hz) Hz emitted \(emitted) in two seconds at 12/s")
        }
    }

    @Test("Particles from a steady emitter are not all the same particle")
    func emitterVaries() {
        var s = system(capacity: 4096)
        var emitter = ParticleEmitter(recipe: 1, rate: 60, seedBase: 11)
        for _ in 0..<120 { emitter.emit(into: &s, at: .zero, deltaTime: step) }
        let speeds = Set(s.particles.map { simd_length($0.velocity) })
        #expect(speeds.count == s.particles.count, "some emitted particles were identical")
    }

    @Test("Two emitters with different seeds do not throw the same particles")
    func emittersDiffer() {
        var a = system(capacity: 4096), b = system(capacity: 4096)
        var ea = ParticleEmitter(recipe: 1, rate: 30, seedBase: 1)
        var eb = ParticleEmitter(recipe: 1, rate: 30, seedBase: 2)
        for _ in 0..<60 {
            ea.emit(into: &a, at: .zero, deltaTime: step)
            eb.emit(into: &b, at: .zero, deltaTime: step)
        }
        #expect(zip(a.particles, b.particles).allSatisfy { $0.velocity != $1.velocity })
    }

    /// A steady emitter must not starve the bursts it shares a pool with.
    @Test("Five steady emitters leave room for a burst")
    func emittersLeaveRoom() {
        var s = system(capacity: 256)
        var emitters = (0..<5).map { ParticleEmitter(recipe: 1, rate: 14, seedBase: $0 * 1000) }
        for _ in 0..<(120 * 5) {
            for i in emitters.indices { emitters[i].emit(into: &s, at: .zero, deltaTime: step) }
            s.step(deltaTime: step)
        }
        #expect(s.liveCount < s.capacity - dirt.count, "steady emitters left \(s.liveCount) of \(s.capacity)")
    }
}

/// **A recipe's and an emitter's limits hold however they are set.** A lifetime set to zero divided by
/// zero in every particle's progress; a negative count or rate threw nothing and owed forever.
@Suite("Particle limits")
struct ParticleLimitTests {

    @Test("A recipe's lifetime and count set past their limits are held to them")
    func recipeLimitsHoldOnSet() {
        var recipe = ParticleRecipe(count: 4, speed: 1, spread: 1, lifetime: 1, size: 0.1, color: .one)
        recipe.lifetime = 0
        #expect(recipe.lifetime == 1e-3)
        recipe.count = -3
        #expect(recipe.count == 0)
        recipe.lifetime = 2
        recipe.count = 7
        #expect(recipe == ParticleRecipe(count: 7, speed: 1, spread: 1, lifetime: 2, size: 0.1, color: .one))
    }

    @Test("A recipe whose lifetime was set to zero still steps to a finite progress")
    func zeroLifetimeIsFinite() {
        var recipe = ParticleRecipe(count: 1, speed: 1, spread: 0, lifetime: 1, size: 0.1, color: .one)
        recipe.lifetime = 0
        var system = ParticleSystem(recipes: [recipe], capacity: 8)
        system.burst(0, at: .zero, seed: 1)
        for particle in system.particles { #expect(particle.progress.isFinite) }
    }

    @Test("An emitter's rate set negative is held at zero")
    func emitterRateHoldsOnSet() {
        var emitter = ParticleEmitter(recipe: 0, rate: 5, seedBase: 1)
        emitter.rate = -10
        #expect(emitter.rate == 0)
    }
}
