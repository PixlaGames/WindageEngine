//
//  ProceduralSky.swift
//  WindageEngine
//

import simd

/// A sky as a function of direction: radiance arriving from anywhere you point.
///
/// **A stand-in for a captured environment, not a replacement for one.** A real scene reflects a
/// photographed HDR panorama with buildings and clouds in it. This is a gradient, a horizon and a sun
/// disc — enough for metal to read as metal and for a reflection to be legible, and enough that a
/// game with no environment asset still gets correct image-based lighting rather than none.
///
/// **Radiance, not color.** The sun is thousands of times brighter than the sky around it, and these
/// numbers say so; that is what the HDR target and ``ToneMapping`` exist for. Values here are linear
/// and unbounded.
public nonisolated struct ProceduralSky: Sendable, Equatable, Codable {

    /// Straight up.
    public var zenith: SIMD3<Float>

    /// At the horizon. Brighter and less saturated than the zenith in a real sky, because there is
    /// more atmosphere in the way.
    public var horizon: SIMD3<Float>

    /// Below the horizon — what the ground bounces back up. **Not black**: a surface facing down is
    /// lit by the ground, and a black lower hemisphere is the single most common reason an
    /// image-based lit object looks like it is floating in a void.
    public var ground: SIMD3<Float>

    /// Towards the sun, normalized — **however it is set**: a direction given at any length is
    /// normalized, and a zero one points straight up.
    public var sunDirection: SIMD3<Float> {
        get { storedSunDirection }
        set { storedSunDirection = ProceduralSky.normalized(newValue) }
    }
    private var storedSunDirection: SIMD3<Float>

    /// The sun's own radiance — how bright the disc *is*, looked at.
    ///
    /// **Very large on purpose, and not the same quantity as the light a surface receives.** Radiance
    /// is per unit solid angle, and the sun subtends almost none of the sky; multiply by how much it
    /// does subtend and you get ``sunIrradiance``, which is what a directional light in a shader
    /// actually wants. Use this one as a light intensity and the scene is roughly a hundred times too
    /// bright — the two differ by the solid angle, and the solid angle of a small disc is a very
    /// small number.
    public var sunRadiance: SIMD3<Float>

    /// Angular radius of the sun's disc, in radians. The real one is about 0.00465; a wider disc
    /// gives a softer reflection and is usually what a stylized game wants.
    public var sunAngularRadius: Float

    /// The sun's elevation above the horizon, in degrees.
    ///
    /// **Angles, not a vector, because a person writes this.** A level file saying `pitch 34, yaw 295`
    /// is something you can picture and adjust; the same thing as `(-0.75, 0.56, 0.35)` is three
    /// numbers that must stay normalized and that nobody can read.
    public var sunPitchDegrees: Float {
        get { Float.degrees(fromRadians: asin(simd_clamp(sunDirection.y, -1, 1))) }
        set { setSun(pitchDegrees: newValue, yawDegrees: sunYawDegrees) }
    }

    /// The compass direction of the sun, in degrees, measured the same way a level's yaws are.
    public var sunYawDegrees: Float {
        get { Float.degrees(fromRadians: atan2(sunDirection.x, sunDirection.z)) }
        set { setSun(pitchDegrees: sunPitchDegrees, yawDegrees: newValue) }
    }

    private mutating func setSun(pitchDegrees: Float, yawDegrees: Float) {
        // Already unit length: stored as it comes, not normalized a second time.
        storedSunDirection = ProceduralSky.direction(pitchDegrees: pitchDegrees, yawDegrees: yawDegrees)
    }

    private static func normalized(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        simd_length_squared(direction) > 0 ? normalize(direction) : SIMD3(0, 1, 0)
    }

    /// The convention two angles turn into, shared by whatever reads a level and whatever lights it.
    ///
    /// **It used to live in a game's source**, which was fine while one game read the sun out of a
    /// level file. The moment the sky itself is *in* the file, the two have to agree, and the place
    /// they can only agree is here.
    public static func direction(pitchDegrees: Float, yawDegrees: Float) -> SIMD3<Float> {
        let pitch = Float.radians(fromDegrees: pitchDegrees)
        let yaw = Float.radians(fromDegrees: yawDegrees)
        return simd_normalize(SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)))
    }

    public init(zenith: SIMD3<Float> = SIMD3(0.28, 0.45, 0.85),
                horizon: SIMD3<Float> = SIMD3(0.62, 0.72, 0.88),
                ground: SIMD3<Float> = SIMD3(0.22, 0.21, 0.18),
                sunDirection: SIMD3<Float> = normalize(SIMD3(0.4, 0.7, 0.6)),
                sunRadiance: SIMD3<Float> = SIMD3(330, 310, 270),
                sunAngularRadius: Float = 0.05) {
        self.zenith = zenith
        self.horizon = horizon
        self.ground = ground
        self.storedSunDirection = ProceduralSky.normalized(sunDirection)
        self.sunRadiance = sunRadiance
        self.sunAngularRadius = sunAngularRadius
    }

    /// The same, with the sun given as the two angles a level file writes.
    public init(zenith: SIMD3<Float> = SIMD3(0.28, 0.45, 0.85),
                horizon: SIMD3<Float> = SIMD3(0.62, 0.72, 0.88),
                ground: SIMD3<Float> = SIMD3(0.22, 0.21, 0.18),
                sunPitchDegrees: Float,
                sunYawDegrees: Float,
                sunRadiance: SIMD3<Float> = SIMD3(330, 310, 270),
                sunAngularRadius: Float = 0.05) {
        self.init(zenith: zenith, horizon: horizon, ground: ground,
                  sunDirection: ProceduralSky.direction(pitchDegrees: sunPitchDegrees,
                                                        yawDegrees: sunYawDegrees),
                  sunRadiance: sunRadiance, sunAngularRadius: sunAngularRadius)
    }

    // MARK: - Codable
    //
    // **Written as angles and colour triples, and every key optional.** A level file is edited by
    // hand as often as by a tool, so a sky that only says `sunPitch` and takes the rest as read is a
    // legal and useful thing to write. Requiring all seven fields would make the simplest edit the
    // longest one.

    private enum CodingKeys: String, CodingKey {
        case zenith, horizon, ground, sunPitch, sunYaw, sunRadiance, sunAngularRadius
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ProceduralSky()
        func color(_ key: CodingKeys, _ or: SIMD3<Float>) throws -> SIMD3<Float> {
            guard let values = try container.decodeIfPresent([Float].self, forKey: key) else { return or }
            guard values.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "a colour needs three components, found \(values.count)")
            }
            return SIMD3(values[0], values[1], values[2])
        }
        self.init(
            zenith: try color(.zenith, fallback.zenith),
            horizon: try color(.horizon, fallback.horizon),
            ground: try color(.ground, fallback.ground),
            sunPitchDegrees: try container.decodeIfPresent(Float.self, forKey: .sunPitch)
                ?? fallback.sunPitchDegrees,
            sunYawDegrees: try container.decodeIfPresent(Float.self, forKey: .sunYaw)
                ?? fallback.sunYawDegrees,
            sunRadiance: try color(.sunRadiance, fallback.sunRadiance),
            sunAngularRadius: try container.decodeIfPresent(Float.self, forKey: .sunAngularRadius)
                ?? fallback.sunAngularRadius)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([zenith.x, zenith.y, zenith.z], forKey: .zenith)
        try container.encode([horizon.x, horizon.y, horizon.z], forKey: .horizon)
        try container.encode([ground.x, ground.y, ground.z], forKey: .ground)
        try container.encode(sunPitchDegrees, forKey: .sunPitch)
        try container.encode(sunYawDegrees, forKey: .sunYaw)
        try container.encode([sunRadiance.x, sunRadiance.y, sunRadiance.z], forKey: .sunRadiance)
        try container.encode(sunAngularRadius, forKey: .sunAngularRadius)
    }

    /// The light a surface facing the sun receives: ``sunRadiance`` times the solid angle the disc
    /// subtends.
    ///
    /// **This is what a directional light's intensity should be**, and deriving it rather than
    /// storing it separately is what keeps the sun you *see* and the sun that *lights* the scene from
    /// being two numbers that disagree. It also makes a physically true thing fall out for free: a
    /// wider sun is both softer and stronger, because it is more sky.
    public var sunIrradiance: SIMD3<Float> {
        sunRadiance * (2 * .pi * (1 - cos(sunAngularRadius)))
    }

    /// The radiance a white speck scatters toward the eye under this sky, for lighting dust and smoke —
    /// what ``ParticleRenderer/draw(_:into:frameSlot:viewProjection:cameraRight:cameraUp:matterLight:)``
    /// multiplies matter by. A property of the sky, so it lives with the sky.
    ///
    /// ### Why matter needs this and light does not
    ///
    /// **A particle's color is one of two different quantities, and treating them as one is the
    /// bug this exists for.** For a spark the color *is* its radiance: it makes light. For dust it is
    /// an **albedo** — how much of the light arriving it sends on — and drawn as if it were radiance,
    /// a gray dust puff is a gray *lamp*. The first landing in the sample threw exactly that: a
    /// 0.5-gray cloud on ground in shadow, reading as a white glow several times brighter than the
    /// floor it came off.
    ///
    /// ### Isotropic, and unshadowed
    ///
    /// A speck that scatters equally in every direction sends the eye the *average* of what arrives
    /// from all of them: the sky's mean radiance over the sphere, plus the sun's irradiance spread
    /// over 4π. That is this. **It does not know about shadow** — dust in the shade of a wall is lit
    /// as if it were in the open — which is the price of computing it once for the whole level; the
    /// sky term alone would be right in shade and far too dark in sun.
    public var matterLight: SIMD3<Float> {
        // A Fibonacci sphere: even coverage with no clustering at the poles.
        let samples = 256
        let golden = Float.pi * (3 - Float(5).squareRoot())
        // The sun is added analytically below. **A sample that landed on its disc would add its
        // radiance once more** — tens of thousands of times the sky's — so the disc is stepped round.
        let sunCone = cos(max(sunAngularRadius * 3, Float.radians(fromDegrees: 2)))
        var sum = SIMD3<Float>.zero
        var counted = 0
        for i in 0..<samples {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(samples)
            let ring = (1 - y * y).squareRoot()
            let direction = SIMD3(cos(golden * Float(i)) * ring, y, sin(golden * Float(i)) * ring)
            guard simd_dot(direction, sunDirection) < sunCone else { continue }
            sum += radiance(inDirection: direction)
            counted += 1
        }
        return sum / Float(max(counted, 1)) + sunIrradiance / (4 * .pi)
    }

    /// Radiance arriving from `direction`, which need not be normalized.
    public func radiance(inDirection direction: SIMD3<Float>) -> SIMD3<Float> {
        let d = simd_length(direction) > 1e-6 ? simd_normalize(direction) : SIMD3(0, 1, 0)

        // Above the horizon, a gradient; below it, the ground fading in over a few degrees so a
        // reflection does not have a hard line across it.
        let sky: SIMD3<Float>
        if d.y >= 0 {
            // Raised to a power so most of the change happens near the horizon, which is where a real
            // sky's does.
            let t = pow(d.y, 0.45)
            sky = simd_mix(horizon, zenith, SIMD3(repeating: t))
        } else {
            let t = simd_clamp(-d.y / 0.08, 0, 1)
            sky = simd_mix(horizon, ground, SIMD3(repeating: t))
        }

        // The sun's disc, with a soft edge. **Not a hard circle**: prefiltering samples this function
        // a few dozen times per texel, and a hard edge at that sample count is a ring of speckle
        // rather than a sun.
        let cosAngle = simd_dot(d, sunDirection)
        let cosOuter = cos(sunAngularRadius)
        let cosInner = cos(sunAngularRadius * 0.55)
        guard cosAngle > cosOuter else { return sky }
        let edge = simd_smoothstep(cosOuter, cosInner, cosAngle)
        return sky + sunRadiance * edge
    }
}

/// `smoothstep`, which simd spells only for scalars in some SDKs.
nonisolated func simd_smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = simd_clamp((x - edge0) / max(edge1 - edge0, 1e-6), 0, 1)
    return t * t * (3 - 2 * t)
}
