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
public nonisolated struct ParticleRecipe: Sendable, Equatable, Codable {

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
    /// How opacity falls over a lifetime: `(1 − t)^fade`. 1 is linear; **2 thins fast and then lingers faint**, which
    /// is how a puff of dust goes; 0 holds full opacity for the whole life — pair it with ``fadeOut``.
    ///
    /// > This said "2 holds on and then goes" until 2026-10-27, which is the opposite of what the curve does: at half
    /// > its life a fade of 2 is already at a quarter. Something that should stay solid and then go wants ``fadeOut``.
    public var fade: Float = 1

    /// **Whether this is light or matter**, which decides how it blends.
    ///
    /// Matter — dust, smoke, dirt — covers what is behind it. Light — a spark, an ember, a flash —
    /// adds to it and covers nothing, so a dozen sparks in front of each other get brighter where a
    /// dozen dust motes get more opaque. Both go through **one pipeline**: the color is
    /// premultiplied either way, and light simply writes zero coverage, which turns the "over"
    /// blend into an add. Two pipelines would mean two draws and a sort between them.
    public var glows: Bool = false

    // MARK: Living things and drifting things — butterflies, motes, petals (2026-10-27)

    /// **How hard it wanders**, meters per second squared: a smooth drift that never repeats the same way twice
    /// and is the same every run. 0 flies straight. A butterfly wanders; a spark does not.
    public var wander: Float = 0
    /// How fast the wander turns, in turns a second. Slow is a drift, fast is a flutter.
    public var wanderRate: Float = 0.3
    /// Meters per second it never goes faster than — what keeps a wanderer near where it was born.
    public var maxSpeed: Float = .infinity
    /// Meters: born anywhere within this of the burst's origin rather than at it — a swarm, not a fountain.
    public var spawnRadius: Float = 0
    /// Seconds it takes to appear, so nothing long-lived pops into being.
    public var fadeIn: Float = 0
    /// **Seconds it takes to go, at the end of its life** — solid until then. What a butterfly or a leaf wants:
    /// there, and then not, rather than ghostly for most of its life.
    public var fadeOut: Float = 0
    /// **Wingbeats a second**: its width closes and opens this often, which is a wing flapping when the sprite is
    /// a pair of wings seen from above. 0 holds still.
    public var flapRate: Float = 0
    /// The atlas cell it is drawn with — ``ParticleRenderer``'s texture — or nil for a soft disc.
    public var sprite: Int?

    // MARK: Shafts and streaks (2026-10-27)

    /// **Which way its height runs.**
    public enum Alignment: String, Sendable, Codable {
        /// Square to the view: a mote, a butterfly, a spark.
        case camera
        /// Along its own motion, longer the faster it goes (``stretch``): a gust of wind, a streak of rain.
        case velocity
        /// Along ``axis`` in the world, turned about it to face the view: a shaft of sunlight leaning from the sun.
        case axis
    }

    /// How tall it is against how wide: 1 square, 1.5 a shaft half as tall again as it is wide.
    public var aspect: Float = 1
    public var alignment: Alignment = .camera
    /// The world direction an ``Alignment/axis`` particle's height runs along — toward the sun, for a sunbeam. A game sets
    /// it when the light changes.
    public var axis: SIMD3<Float> = SIMD3(0, 1, 0)
    /// Seconds of its own motion added to a ``Alignment/velocity`` particle's length: at 10 m/s, 0.1 is another metre.
    public var stretch: Float = 0

    private var storedCount: Int
    private var storedLifetime: Float

    public init(count: Int, speed: Float, spread: Float, lifetime: Float, size: Float,
                growth: Float = 0, gravity: Float = -6.5, drag: Float = 2.4,
                color: SIMD3<Float>, opacity: Float = 1, fade: Float = 1, glows: Bool = false,
                wander: Float = 0, wanderRate: Float = 0.3, maxSpeed: Float = .infinity, spawnRadius: Float = 0,
                fadeIn: Float = 0, fadeOut: Float = 0, flapRate: Float = 0, sprite: Int? = nil,
                aspect: Float = 1, alignment: Alignment = .camera, axis: SIMD3<Float> = SIMD3(0, 1, 0),
                stretch: Float = 0) {
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
        self.wander = max(wander, 0)
        self.wanderRate = max(wanderRate, 0)
        self.maxSpeed = maxSpeed > 0 ? maxSpeed : .infinity
        self.spawnRadius = max(spawnRadius, 0)
        self.fadeIn = max(fadeIn, 0)
        self.fadeOut = max(fadeOut, 0)
        self.flapRate = max(flapRate, 0)
        self.sprite = sprite
        self.aspect = aspect > 0 && aspect.isFinite ? aspect : 1
        self.alignment = alignment
        self.axis = simd_length_squared(axis) > 0 ? simd_normalize(axis) : SIMD3(0, 1, 0)
        self.stretch = max(stretch, 0)
    }

    // MARK: Saved

    private enum CodingKeys: String, CodingKey {
        case count, speed, spread, lifetime, size, growth, gravity, drag, color, opacity, fade, glows
        case wander, wanderRate, maxSpeed, spawnRadius, fadeIn, fadeOut, flapRate, sprite
        case aspect, alignment, axis, stretch
    }

    /// **Saved as JSON, every field but a color optional** — a pack describes an effect in a file, and a file from
    /// before a field was added keeps meaning what it meant. A top speed of none is left out rather than written.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        self.init(count: value(.count, 1), speed: value(.speed, 0), spread: value(.spread, 0),
                  lifetime: value(.lifetime, 1), size: value(.size, 0.1), growth: value(.growth, 0),
                  gravity: value(.gravity, -6.5), drag: value(.drag, 2.4),
                  color: try c.decode(SIMD3<Float>.self, forKey: .color),
                  opacity: value(.opacity, 1), fade: value(.fade, 1), glows: value(.glows, false),
                  wander: value(.wander, 0), wanderRate: value(.wanderRate, 0.3),
                  maxSpeed: value(.maxSpeed, .infinity), spawnRadius: value(.spawnRadius, 0),
                  fadeIn: value(.fadeIn, 0), fadeOut: value(.fadeOut, 0), flapRate: value(.flapRate, 0),
                  sprite: (try? c.decodeIfPresent(Int.self, forKey: .sprite)) ?? nil,
                  aspect: value(.aspect, 1), alignment: value(.alignment, .camera), axis: value(.axis, SIMD3(0, 1, 0)),
                  stretch: value(.stretch, 0))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count); try c.encode(speed, forKey: .speed); try c.encode(spread, forKey: .spread)
        try c.encode(lifetime, forKey: .lifetime); try c.encode(size, forKey: .size); try c.encode(growth, forKey: .growth)
        try c.encode(gravity, forKey: .gravity); try c.encode(drag, forKey: .drag); try c.encode(color, forKey: .color)
        try c.encode(opacity, forKey: .opacity); try c.encode(fade, forKey: .fade); try c.encode(glows, forKey: .glows)
        try c.encode(wander, forKey: .wander); try c.encode(wanderRate, forKey: .wanderRate)
        if maxSpeed.isFinite { try c.encode(maxSpeed, forKey: .maxSpeed) }
        try c.encode(spawnRadius, forKey: .spawnRadius); try c.encode(fadeIn, forKey: .fadeIn); try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(flapRate, forKey: .flapRate); try c.encodeIfPresent(sprite, forKey: .sprite)
        try c.encode(aspect, forKey: .aspect); try c.encode(alignment, forKey: .alignment)
        try c.encode(axis, forKey: .axis); try c.encode(stretch, forKey: .stretch)
    }
}

nonisolated extension ParticleRecipe {
    /// **This recipe as shafts of a sky's light**: leaning along the sun (``Alignment/axis``) and tinted by its light,
    /// scaled so a high noon sun leaves the recipe's own colour about as it is — dimmer and warmer toward evening, and
    /// gone once the sun is down, because moonlight does not make shafts.
    ///
    /// For a recipe that ``glows``, so the light it gives is added over the scene; a recipe that covers would darken
    /// toward black instead of fading.
    public func shafts(of lighting: DaySky.Lighting) -> ParticleRecipe {
        var recipe = self
        recipe.alignment = .axis
        recipe.axis = lighting.direction
        recipe.color *= lighting.elevation > 0 ? lighting.colour / Self.noonLight : .zero
        return recipe
    }

    /// About how bright a clear noon sun's light is in ``DaySky/Lighting/colour``.
    static let noonLight: Float = 3.2
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
        /// 0…1, its own: where its wander and its wingbeat start, so a swarm does not move as one.
        let seed: Float

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
            if recipe.wander > 0 {
                particles[index].velocity += ParticleSystem.wander(of: particles[index], recipe) * deltaTime
            }
            particles[index].velocity *= max(0, 1 - recipe.drag * deltaTime)
            let speed = simd_length(particles[index].velocity)
            if speed > recipe.maxSpeed { particles[index].velocity *= recipe.maxSpeed / speed }
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

            // Born within the spawn radius: a direction from three more draws, a distance from a fourth, cube-rooted
            // so the sphere fills evenly rather than crowding its middle.
            var place = origin
            if r.spawnRadius > 0 {
                let d = SIMD3(ParticleSystem.hash(seed, i * 7 + 3), ParticleSystem.hash(seed, i * 7 + 4),
                              ParticleSystem.hash(seed, i * 7 + 5)) * 2 - 1
                let length = simd_length(d)
                if length > 1e-4 {
                    place += d / length * r.spawnRadius * pow(ParticleSystem.hash(seed, i * 7 + 6), 1 / 3)
                }
            }
            add(Particle(position: place,
                         velocity: velocity,
                         age: 0,
                         lifetime: r.lifetime * (0.6 + b * 0.8),
                         size: r.size * (0.7 + c * 0.6),
                         recipe: recipe,
                         birth: births,
                         seed: ParticleSystem.hash(seed, i * 7 + 2_000_003)))
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
        let appearing = r.fadeIn > 0 ? min(particle.age / r.fadeIn, 1) : 1
        let going = r.fadeOut > 0 ? min(max(particle.lifetime - particle.age, 0) / r.fadeOut, 1) : 1
        let opacity = r.opacity * pow(max(0, 1 - t), r.fade) * appearing * going
        return (r.color * opacity, r.glows ? 0 : opacity, particle.size * (1 + r.growth * t))
    }

    /// **The two half-edges of its quad in the world** — right and up from its centre — for its size now, its wingbeat,
    /// its aspect and its alignment, seen with the view's right and up. A renderer places the corners from these.
    public func extent(of particle: Particle, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>)
        -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let r = recipes[particle.recipe]
        let half = appearance(of: particle).size * 0.5
        let width = half * width(of: particle)
        var height = half * r.aspect
        var along: SIMD3<Float>
        switch r.alignment {
        case .camera:
            return (cameraRight * width, cameraUp * height)
        case .velocity:
            let speed = simd_length(particle.velocity)
            guard speed > 1e-4 else { return (cameraRight * width, cameraUp * height) }
            along = particle.velocity / speed
            height += speed * r.stretch * 0.5
        case .axis:
            along = r.axis
        }
        // Turned about its own length to face the view as nearly as it can: across is square to both the length and
        // the view's line of sight. Looked at end-on there is no such direction, and the view's right stands in.
        let sight = simd_cross(cameraUp, cameraRight)
        var across = simd_cross(along, sight)
        let length = simd_length(across)
        across = length > 1e-3 ? across / length : cameraRight
        return (across * width, along * height)
    }

    /// **How wide it is drawn against its size, 0…1** — a wingbeat for a recipe that flaps, else 1. The width closes
    /// to a quarter and opens again: a pair of wings seen from above, beating.
    public func width(of particle: Particle) -> Float {
        let r = recipes[particle.recipe]
        guard r.flapRate > 0 else { return 1 }
        let beat = abs(cos((particle.age * r.flapRate + particle.seed) * .pi))
        return 0.25 + 0.75 * beat
    }

    /// The acceleration a wanderer feels now: three slow waves at its own phases, a different mix on each axis and
    /// weaker up and down, so it drifts and dips rather than climbs. **Smooth and the same every run** — no random
    /// draw — like everything else here.
    private static func wander(of particle: Particle, _ recipe: ParticleRecipe) -> SIMD3<Float> {
        let t = particle.age * recipe.wanderRate * 2 * .pi
        let p = particle.seed * 2 * .pi
        return recipe.wander * SIMD3(sin(t + p * 3) + 0.5 * sin(t * 2.3 + p * 7),
                                     0.4 * sin(t * 1.7 + p * 5),
                                     cos(t * 1.3 + p * 11) + 0.5 * sin(t * 2.9 + p * 13)) / 1.5
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

    /// **Runs `seconds` of emitting and stepping at once**, so a swarm that has always been there is already flying
    /// when a scene appears — rather than a first butterfly being born in front of the player.
    public mutating func prewarm(_ system: inout ParticleSystem, at origin: SIMD3<Float>,
                                 direction: SIMD3<Float> = SIMD3(0, 1, 0), seconds: Float, step: Float = 1.0 / 30) {
        guard seconds > 0, step > 0 else { return }
        for _ in 0..<Int((seconds / step).rounded(.up)) {
            emit(into: &system, at: origin, direction: direction, deltaTime: step)
            system.step(deltaTime: step)
        }
    }

    /// **Prewarms every emitter feeding one system together** — one after another would age the first one's
    /// particles through every later one's prewarm too. `origins[i]` is where `emitters[i]` is.
    /// `directions[i]`, when given, is the way `emitters[i]` throws — the wind's heading for a gust.
    public static func prewarm(_ emitters: inout [ParticleEmitter], at origins: [SIMD3<Float>],
                               directions: [SIMD3<Float>]? = nil,
                               into system: inout ParticleSystem, seconds: Float, step: Float = 1.0 / 30) {
        guard seconds > 0, step > 0, emitters.count == origins.count,
              directions == nil || directions?.count == origins.count else { return }
        for _ in 0..<Int((seconds / step).rounded(.up)) {
            for index in emitters.indices {
                emitters[index].emit(into: &system, at: origins[index], direction: directions?[index] ?? SIMD3(0, 1, 0),
                                     deltaTime: step)
            }
            system.step(deltaTime: step)
        }
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
