import simd

/// **A sky set by the time of day**: one number, and the sun's direction, its light, the sky's colours and the eye's
/// adjustment to the dark all follow from it — ``lighting``. Quick to judge a scene at dawn, noon and dusk, and one number
/// to store. ``SkyPass`` draws it.
///
/// An equinox day, the same everywhere: the sun rises in the east (+x) at six, passes south (+z) at noon and sets in the
/// west (−x) at eighteen. By night the light is the moon's, opposite the sun and well above the horizon.
///
/// **Radiance, for the HDR scene target and ``ToneMapping``** — a high sun is about 3, which is what a surface lit as
/// `sun × n·l / π` wants. ``Lighting/exposureStops`` opens the exposure as the light falls, so night reads dark rather than
/// black.
public nonisolated struct DaySky: Sendable, Equatable {
    /// Hours since midnight, 0…24.
    public var timeOfDay: Float
    /// **The sun set by hand** instead of by the hour — for matching a scene's lighting to something else. `nil` is the
    /// normal case. The sky's colours still follow the sun's height, so a low sun set by hand still gets a dusk sky.
    public var sun: Sun?

    public init(timeOfDay: Float = 15, sun: Sun? = nil) {
        self.timeOfDay = timeOfDay
        self.sun = sun
    }

    /// A sun placed by hand.
    public struct Sun: Sendable, Equatable {
        /// Compass bearing toward the sun, degrees: 0 north (−z), 90 east (+x), 180 south (+z), 270 west.
        public var heading: Float
        /// Height above the horizon, degrees: 0 on it, 90 straight overhead.
        public var height: Float
        /// Its colour, **linear**.
        public var colour: SIMD3<Float>
        /// How bright: the hour's noon sun is about 3.
        public var brightness: Float

        public init(heading: Float, height: Float, colour: SIMD3<Float>, brightness: Float) {
            self.heading = heading
            self.height = height
            self.colour = colour
            self.brightness = brightness
        }

        /// Unit vector toward the sun.
        public var direction: SIMD3<Float> {
            let h = heading * .pi / 180, e = height * .pi / 180
            return simd_normalize(SIMD3(sin(h) * cos(e), sin(e), -cos(h) * cos(e)))
        }
    }

    /// Sunrise and sunset, in hours.
    public static let sunrise: Float = 6
    public static let sunset: Float = 18
    /// How high the sun climbs at noon, radians. Not straight overhead: a noon sun with no shadow direction makes every
    /// scene look flat.
    public static let noonElevation: Float = 62 * .pi / 180

    /// Everything a renderer needs to light a scene at this time, linear.
    public struct Lighting: Sendable, Equatable {
        /// Unit vector toward the light: the sun by day, the moon by night.
        public var direction: SIMD3<Float>
        /// The light's radiance.
        public var colour: SIMD3<Float>
        /// The sky straight up; also the ambient light from above.
        public var zenith: SIMD3<Float>
        /// The sky at the horizon — what distance fades into.
        public var horizon: SIMD3<Float>
        /// The light bounced up from the ground.
        public var ground: SIMD3<Float>
        /// The sun's height above the horizon, radians; below zero at night.
        public var elevation: Float

        /// **A little of the eye's adjustment to the dark**, for ``ToneMapping/exposureStops``: night is shown darker,
        /// not black, so a scene can be judged at any hour — the exposure opens as the light falls, by at most three stops.
        public var exposureStops: Float {
            let brightest = max(simd_reduce_max(colour), 0.001)
            return min(max(log2(3.2 / brightest) * 0.55, 0), 3)
        }
    }

    /// The sun's direction at a time, and its height in radians.
    public static func sunDirection(at hours: Float) -> (direction: SIMD3<Float>, elevation: Float) {
        // 0 at sunrise, π at sunset; the night half continues below the horizon.
        let angle = (hours - sunrise) / (sunset - sunrise) * .pi
        let elevation = sin(angle) * noonElevation
        let flat = cos(elevation)
        let direction = SIMD3(cos(angle) * flat, sin(elevation), sin(angle) * flat)
        return (simd_normalize(direction), elevation)
    }

    public var lighting: Lighting {
        if let sun {
            let key = Self.blend(Self.keys, at: sun.height)
            return Lighting(direction: sun.direction, colour: sun.colour * sun.brightness,
                            zenith: key.zenith, horizon: key.horizon, ground: key.ground,
                            elevation: sun.height * .pi / 180)
        }
        let hours = Self.wrap(timeOfDay)
        let (direction, elevation) = Self.sunDirection(at: hours)
        let degrees = elevation * 180 / .pi
        let key = Self.blend(Self.keys, at: degrees)
        let moon = simd_normalize(SIMD3(-direction.x, max(-direction.y, 0.35), -direction.z))
        let daylight = Self.smoothstep(-4, 4, degrees)
        let light = simd_normalize(direction * daylight + moon * (1 - daylight))
        return Lighting(direction: elevation > 0 ? direction : light,
                        colour: key.sun, zenith: key.zenith, horizon: key.horizon, ground: key.ground,
                        elevation: elevation)
    }

    // MARK: Keyframes

    /// Against the sun's height in degrees: night, the horizon (dawn and dusk), low sun, high sun.
    static let keys: [(Float, Key)] = [
        (-18, .night), (-4, .twilight), (2, .horizon), (12, .low), (40, .high),
    ]

    /// One look of the sky, in linear radiance.
    struct Key: Equatable {
        var sun: SIMD3<Float>, zenith: SIMD3<Float>, horizon: SIMD3<Float>, ground: SIMD3<Float>

        static let night = Key(sun: SIMD3(0.10, 0.13, 0.22), zenith: SIMD3(0.012, 0.016, 0.035),
                               horizon: SIMD3(0.02, 0.025, 0.045), ground: SIMD3(0.01, 0.01, 0.012))
        static let twilight = Key(sun: SIMD3(0.35, 0.22, 0.25), zenith: SIMD3(0.06, 0.08, 0.16),
                                  horizon: SIMD3(0.30, 0.16, 0.12), ground: SIMD3(0.03, 0.025, 0.025))
        static let horizon = Key(sun: SIMD3(2.2, 0.95, 0.42), zenith: SIMD3(0.18, 0.24, 0.40),
                                 horizon: SIMD3(0.85, 0.48, 0.28), ground: SIMD3(0.08, 0.06, 0.045))
        static let low = Key(sun: SIMD3(3.0, 2.2, 1.4), zenith: SIMD3(0.28, 0.40, 0.62),
                             horizon: SIMD3(0.66, 0.64, 0.62), ground: SIMD3(0.14, 0.12, 0.10))
        static let high = Key(sun: SIMD3(3.2, 3.0, 2.7), zenith: SIMD3(0.32, 0.45, 0.66),
                              horizon: SIMD3(0.62, 0.68, 0.74), ground: SIMD3(0.16, 0.15, 0.13))

        func mixed(with other: Key, _ t: Float) -> Key {
            Key(sun: simd_mix(sun, other.sun, SIMD3(repeating: t)),
                zenith: simd_mix(zenith, other.zenith, SIMD3(repeating: t)),
                horizon: simd_mix(horizon, other.horizon, SIMD3(repeating: t)),
                ground: simd_mix(ground, other.ground, SIMD3(repeating: t)))
        }
    }

    static func blend(_ keys: [(Float, Key)], at x: Float) -> Key {
        if x <= keys[0].0 { return keys[0].1 }
        for (a, b) in zip(keys, keys.dropFirst()) where x <= b.0 {
            let t = (x - a.0) / (b.0 - a.0)
            return a.1.mixed(with: b.1, t * t * (3 - 2 * t))
        }
        return keys[keys.count - 1].1
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Into 0…24.
    static func wrap(_ hours: Float) -> Float {
        let h = hours.truncatingRemainder(dividingBy: 24)
        return h < 0 ? h + 24 : h
    }
}
