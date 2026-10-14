//
//  ParticleSystem.swift
//  WindageEngine
//

import simd

/// What one kind of particle is: how many a burst throws, how they move, how long they last and
/// what they look like while they do.
///
/// **A value a game defines, not a list the engine owns.** The code this came from had its kinds
/// as an enum — dirt, dust, muzzle flash — which is exactly right inside one game and exactly wrong
/// in an engine, because the next game's kinds are embers, sparks and spray. What was genuinely
/// shared was the *shape* of a kind, and that is this.
///
/// **Its limits hold however it is set**: ``count`` is never negative and ``lifetime`` never below a
/// millisecond — a lifetime of zero divided by zero in every particle's ``ParticleSystem/Particle/progress``.
public nonisolated struct ParticleRecipe: Sendable, Equatable {

    /// How many one burst throws. Never negative.
    public var count: Int {
        get { storedCount }
        set { storedCount = max(0, newValue) }
    }
    /// Meters per second along the burst's axis, before the per-particle variation.
    public var speed: Float
    /// Meters per second across it — how wide the cone opens.
    public var spread: Float
    /// Seconds, before the per-particle variation. At least a millisecond.
    public var lifetime: Float {
        get { storedLifetime }
        set { storedLifetime = max(newValue, 1e-3) }
    }
    /// Edge length in meters at birth.
    public var size: Float
    /// How much the size grows over a lifetime: 0 stays the same, 1 doubles. Smoke spreads as it
    /// thins; a spark does not.
    public var growth: Float = 0

    /// Meters per second squared, **signed and per recipe**. Dirt falls; an ember rises on the heat
    /// it came from; a flash does neither, because it is light rather than matter.
    public var gravity: Float = -6.5
    /// Fraction of velocity shed per second — what stops a particle flying on a parabola for ever.
    public var drag: Float = 2.4

    /// Color, **linear and unbounded**. Above 1 is how a spark reads as hot rather than as orange
    /// paint: the scene is HDR and the tone map rolls it towards white.
    public var color: SIMD3<Float>
    /// Opacity at birth.
    public var opacity: Float = 1
    /// How opacity falls over a lifetime: `(1 − t)^fade`. 1 is linear; 2 holds on and then goes,
    /// which is how dust thins.
    public var fade: Float = 1

    /// **Whether this is light or matter**, which decides how it blends.
    ///
    /// Matter — dust, smoke, dirt — covers what is behind it. Light — a spark, an ember, a flash —
    /// adds to it and covers nothing, so a dozen sparks in front of each other get brighter where a
    /// dozen dust motes get more opaque. Both go through **one pipeline**: the color is
    /// premultiplied either way, and light simply writes zero coverage, which turns the "over"
    /// blend into an add. Two pipelines would mean two draws and a sort between them.
    public var glows: Bool = false

    private var storedCount: Int
    private var storedLifetime: Float

    public init(count: Int, speed: Float, spread: Float, lifetime: Float, size: Float,
                growth: Float = 0, gravity: Float = -6.5, drag: Float = 2.4,
                color: SIMD3<Float>, opacity: Float = 1, fade: Float = 1, glows: Bool = false) {
        self.storedCount = max(0, count)
        self.speed = speed
        self.spread = spread
        self.storedLifetime = max(lifetime, 1e-3)
        self.size = size
        self.growth = growth
        self.gravity = gravity
        self.drag = drag
        self.color = color
        self.opacity = opacity
        self.fade = fade
        self.glows = glows
    }
}

/// Dust, sparks and embers: the things that say something just happened.
///
/// ### Extracted, and the recipe is what changed
///
/// **The simulation came from a working game**, with its rules intact: it advances on the fixed step
/// like everything else that matters, so a burst plays the same way twice and the whole thing tests
/// without a GPU; the pool is fixed; and when it is full the *oldest* particle is recycled, never the
/// newest — a system that drops the newest silently discards the burst that just happened, which is
/// always the one the player is looking at.
///
/// What did not come across unchanged is the list of kinds, which is now ``ParticleRecipe``, and the
/// spread's source of randomness — an integer hash, below.
///
/// ### Deterministic
///
/// **There is no `random()` here.** Spread comes from a hash of the particle's index and the burst's
/// seed, so the same bursts in the same order produce the same particles. Pass a seed that is part
/// of the simulation — an event's index, a step count — never a clock.
public nonisolated struct ParticleSystem: Sendable {

    /// One particle, as the system last stepped it. **Read-only outside the engine**: the system owns
    /// the pool, and a copy changed by a game changes nothing it draws.
    public struct Particle: Sendable {
        public internal(set) var position: SIMD3<Float>
        public internal(set) var velocity: SIMD3<Float>
        public internal(set) var age: Float
        public let lifetime: Float
        public let size: Float
        /// Which recipe it came from, by index into the system's ``recipes``. **An index rather than
        /// a copy**, so a pool of a thousand is not a thousand copies of the same color and curve.
        public let recipe: Int
        /// When it was born, in bursts thrown — what "oldest" means when the pool is full.
        let birth: Int

        /// 0 at birth, 1 at death.
        public var progress: Float { min(1, age / lifetime) }
        public var isAlive: Bool { age < lifetime }
    }

    /// Every kind this system can throw. A burst names one by index.
    public let recipes: [ParticleRecipe]

    /// How many can be alive at once.
    public let capacity: Int

    public private(set) var particles: [Particle] = []
    private var births = 0

    public init(recipes: [ParticleRecipe], capacity: Int = 1024) {
        self.recipes = recipes
        self.capacity = max(1, capacity)
        particles.reserveCapacity(self.capacity)
    }

    public var liveCount: Int { particles.reduce(0) { $1.isAlive ? $0 + 1 : $0 } }

    /// Everything alive, for a renderer. Allocates; a renderer that cares iterates ``particles``.
    public var live: [Particle] { particles.filter(\.isAlive) }

    /// Advances every live particle by one step.
    public mutating func step(deltaTime: Float) {
        for index in particles.indices where particles[index].isAlive {
            let recipe = recipes[particles[index].recipe]
            particles[index].age += deltaTime
            particles[index].velocity.y += recipe.gravity * deltaTime
            particles[index].velocity *= max(0, 1 - recipe.drag * deltaTime)
            particles[index].position += particles[index].velocity * deltaTime
        }
    }

    /// Throws a burst.
    ///
    /// - Parameters:
    ///   - direction: the axis it is thrown along — a surface's normal, a direction of travel, up.
    ///   - seed: makes it repeatable. **Part of the simulation, never a clock.**
    ///   - count: fewer than the recipe's, for an emitter that trickles rather than bursts. **Never
    ///     more**: a trickle asking for more than a burst is a mistake, and inflating it would let a
    ///     continuous emitter starve the pool it shares with everything else.
    public mutating func burst(_ recipe: Int,
                               at origin: SIMD3<Float>,
                               direction: SIMD3<Float> = SIMD3(0, 1, 0),
                               seed: Int,
                               count: Int? = nil) {
        guard recipes.indices.contains(recipe) else { return }
        let r = recipes[recipe]
        let axis = simd_length_squared(direction) > 0 ? simd_normalize(direction) : SIMD3(0, 1, 0)
        for i in 0..<min(count ?? r.count, r.count) {
            let a = ParticleSystem.hash(seed, i * 3 + 0)
            let b = ParticleSystem.hash(seed, i * 3 + 1)
            let c = ParticleSystem.hash(seed, i * 3 + 2)

            // A cone about the axis: spread across it, biased along it.
            let spread = SIMD3(a - 0.5, b - 0.5, c - 0.5) * 2 * r.spread
            let velocity = axis * r.speed * (0.45 + a * 0.75) + spread

            add(Particle(position: origin,
                         velocity: velocity,
                         age: 0,
                         lifetime: r.lifetime * (0.6 + b * 0.8),
                         size: r.size * (0.7 + c * 0.6),
                         recipe: recipe,
                         birth: births))
        }
        births += 1
    }

    private mutating func add(_ particle: Particle) {
        if particles.count < capacity {
            particles.append(particle)
            return
        }
        // Full: a dead slot if there is one, otherwise **the oldest**, never the newest.
        var victim = 0
        for index in particles.indices {
            if !particles[index].isAlive { victim = index; break }
            if particles[index].birth < particles[victim].birth { victim = index }
        }
        particles[victim] = particle
    }

    /// How a particle looks at its current age: its color **premultiplied** by opacity, and its
    /// coverage — zero for anything that glows. See ``ParticleRecipe/glows``.
    public func appearance(of particle: Particle) -> (color: SIMD3<Float>, coverage: Float, size: Float) {
        let r = recipes[particle.recipe]
        let t = particle.progress
        let opacity = r.opacity * pow(max(0, 1 - t), r.fade)
        return (r.color * opacity, r.glows ? 0 : opacity, particle.size * (1 + r.growth * t))
    }

    /// A deterministic 0…1 from a seed and an index.
    ///
    /// ### Integer, and that is a fix
    ///
    /// **The code this came from used `fract(sin(x) × 43758.5453)`**, the well-known shader one-liner.
    /// On a GPU at high precision it is fine. In 32-bit floats on the CPU it is not: the product is
    /// tens of thousands, so the fraction keeps only the few mantissa bits left over — and measured,
    /// **300,000 draws produced 8,923 distinct values**. Every "random" spread was snapped to a grid
    /// about thirteen bits fine. It looked plausible, which is why nothing had said so.
    ///
    /// This is an integer mixer (Wellons' *lowbias32*), exact on every platform, with 24 bits kept
    /// for the float: the same 300,000 draws give 297,320 distinct values, which is what a perfect
    /// 24-bit output would do.
    static func hash(_ seed: Int, _ index: Int) -> Float {
        let mixed = mix(mix(UInt32(truncatingIfNeeded: seed)) ^ (UInt32(truncatingIfNeeded: index) &* 0x9E37_79B9))
        return Float(mixed >> 8) * (1 / 16_777_216)
    }

    private static func mix(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x &*= 0x7FEB_352D
        x ^= x >> 15
        x &*= 0x846C_A68B
        x ^= x >> 16
        return x
    }
}

/// Particles at a steady rate rather than in a burst.
///
/// ### A rate in particles per second, not "every so many steps"
///
/// **The code this came from emitted a trickle every eighth step**, which ties the rate to the
/// step: change the fixed timestep and every continuous effect in the game changes density with it.
/// This keeps the fractional particle owed from one step to the next, so twelve a second is twelve a
/// second at 60 Hz, 120 Hz or whatever the simulation runs at.
public nonisolated struct ParticleEmitter: Sendable {
    /// Particles per second. Never negative, however it is set.
    public var rate: Float {
        get { storedRate }
        set { storedRate = max(0, newValue) }
    }
    private var storedRate: Float
    public var recipe: Int
    private var owed: Float = 0
    private var bursts = 0
    /// Keeps two emitters from throwing identical particles: the seed is this plus a count.
    public let seedBase: Int

    public init(recipe: Int, rate: Float, seedBase: Int) {
        self.recipe = recipe
        self.storedRate = max(0, rate)
        self.seedBase = seedBase
    }

    /// Emits whatever is owed for this step into `system`.
    public mutating func emit(into system: inout ParticleSystem,
                              at origin: SIMD3<Float>,
                              direction: SIMD3<Float> = SIMD3(0, 1, 0),
                              deltaTime: Float) {
        owed += rate * max(0, deltaTime)
        let whole = Int(owed)
        guard whole > 0 else { return }
        owed -= Float(whole)
        // One particle per burst call, each with its own seed — a burst of `whole` from one seed
        // would throw the same first particle every time `whole` happened to be 1.
        for _ in 0..<whole {
            system.burst(recipe, at: origin, direction: direction,
                         seed: seedBase &+ bursts &* 7919, count: 1)
            bursts += 1
        }
    }
}
