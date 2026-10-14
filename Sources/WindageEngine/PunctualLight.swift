//
//  PunctualLight.swift
//  WindageEngine
//

import simd

/// A light at a point, radiating in every direction.
///
/// **The first light in this engine that is not the sun.** A directional sun and an environment map
/// light an outdoor scene correctly and have no answer at all for an interior: the sun does not reach
/// inside, and a sky-colored ambient lights a cellar as though the sky were overhead.
public nonisolated struct PunctualLight: Sendable, Equatable, Codable {

    public var position: SIMD3<Float>

    /// Color times brightness, unbounded — **radiant intensity, not a color.** A lamp is far
    /// brighter than white paper, which is what the HDR target and ``ToneMapping`` are for.
    public var color: SIMD3<Float>

    /// Meters at which this light has fallen to nothing.
    ///
    /// **Finite on purpose.** An inverse-square falloff never actually reaches zero, so without a
    /// cutoff every lamp in a building is technically relevant to every fragment and no selection
    /// rule can ever discard one.
    public var range: Float

    /// The cone this light is confined to, or `nil` for one that radiates in every direction.
    ///
    /// **A point light is a spot with no cone, and the shader does not branch on it.** See
    /// ``Cone/angleScale`` — a light with no cone produces an angular attenuation of exactly 1
    /// everywhere, from the same two multiplies, so one code path serves both.
    public var cone: Cone?

    /// A cone of light: where it points, and how sharply it ends.
    ///
    /// **Two angles rather than one**, because a single cutoff gives a hard-edged circle that reads
    /// as a stencil rather than as a lamp. Full brightness within the inner angle, nothing beyond the
    /// outer, and a smooth fall between.
    ///
    /// **Its limits hold however it is set**, not only in `init`: a direction is normalized (a zero one
    /// points straight down), the outer angle is held to `1e-4…π`, and the inner to `0…outer`. Narrowing
    /// the outer angle past the inner one narrows the inner with it.
    public nonisolated struct Cone: Sendable, Equatable {
        /// Where the light points, normalized.
        public var direction: SIMD3<Float> {
            get { storedDirection }
            set { storedDirection = Cone.normalized(newValue) }
        }
        /// Half-angle of the fully-lit core, in radians. Held to `0…outerAngle`.
        public var innerAngle: Float {
            get { storedInnerAngle }
            set { storedInnerAngle = simd_clamp(newValue, 0, storedOuterAngle) }
        }
        /// Half-angle at which the light has fallen to nothing, in radians. Held to `1e-4…π`.
        public var outerAngle: Float {
            get { storedOuterAngle }
            set {
                storedOuterAngle = simd_clamp(newValue, 1e-4, .pi)
                storedInnerAngle = min(storedInnerAngle, storedOuterAngle)
            }
        }

        private var storedDirection: SIMD3<Float>
        private var storedInnerAngle: Float
        private var storedOuterAngle: Float

        public init(direction: SIMD3<Float>, innerAngle: Float, outerAngle: Float) {
            storedDirection = Cone.normalized(direction)
            // Clamped so the inner never exceeds the outer: reversed, the scale below goes negative
            // and the cone lights everything *except* where it points.
            storedOuterAngle = simd_clamp(outerAngle, 1e-4, .pi)
            storedInnerAngle = simd_clamp(innerAngle, 0, storedOuterAngle)
        }

        private static func normalized(_ direction: SIMD3<Float>) -> SIMD3<Float> {
            simd_length(direction) > 1e-6 ? simd_normalize(direction) : SIMD3(0, -1, 0)
        }

        var cosOuter: Float { cos(outerAngle) }
        var cosInner: Float { cos(innerAngle) }

        /// Precomputed so the shader does two multiplies instead of two cosines and a divide.
        ///
        /// The angular attenuation is `saturate(cosAngle * angleScale + angleOffset)`, squared. **A
        /// light with no cone uses a scale of 0 and an offset of 1**, which is that expression
        /// evaluating to 1 everywhere — which is why a point light needs no branch of its own.
        public var angleScale: Float { 1 / max(cosInner - cosOuter, 1e-4) }
        public var angleOffset: Float { -cosOuter * angleScale }
    }

    public init(position: SIMD3<Float>,
                color: SIMD3<Float>,
                range: Float,
                cone: Cone? = nil) {
        self.position = position
        self.color = color
        self.range = range
        self.cone = cone
    }

    /// How much of the cone reaches a point: 1 inside the inner angle, 0 beyond the outer, smooth
    /// between. Always 1 for a light with no cone.
    public func angularAttenuation(at point: SIMD3<Float>) -> Float {
        guard let cone else { return 1 }
        let offset = point - position
        let length = simd_length(offset)
        guard length > 1e-6 else { return 1 }
        let cosAngle = simd_dot(offset / length, cone.direction)
        let falloff = simd_clamp(cosAngle * cone.angleScale + cone.angleOffset, 0, 1)
        // Squared, so the edge eases in rather than arriving at a constant rate — a linear falloff
        // still shows the outer circle as a change of gradient.
        return falloff * falloff
    }

    // MARK: - Codable
    //
    // **Colour as a triple and brightness as its own number**, because that is how a person reasons
    // about a lamp: what colour is it, and how bright. Writing `[28, 26, 22]` in a level file means
    // holding a colour and an intensity in your head at once, and adjusting one changes the other.

    private enum CodingKeys: String, CodingKey {
        case position, color, intensity, range, direction, innerAngle, outerAngle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func triple(_ key: CodingKeys, _ or: SIMD3<Float>) throws -> SIMD3<Float> {
            guard let values = try container.decodeIfPresent([Float].self, forKey: key) else { return or }
            guard values.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "needs three components, found \(values.count)")
            }
            return SIMD3(values[0], values[1], values[2])
        }
        let intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? 1

        // **A cone only if a direction is given.** Angles in degrees, like the sky's, because these
        // are numbers a person types — "a 25° cone" is something you can picture and 0.436 is not.
        var cone: Cone?
        if let direction = try container.decodeIfPresent([Float].self, forKey: .direction) {
            guard direction.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .direction, in: container,
                    debugDescription: "a direction needs three components, found \(direction.count)")
            }
            let outer = try container.decodeIfPresent(Float.self, forKey: .outerAngle) ?? 35
            let inner = try container.decodeIfPresent(Float.self, forKey: .innerAngle) ?? outer * 0.6
            cone = Cone(direction: SIMD3(direction[0], direction[1], direction[2]),
                        innerAngle: Float.radians(fromDegrees: inner),
                        outerAngle: Float.radians(fromDegrees: outer))
        }

        self.init(position: try triple(.position, .zero),
                  color: try triple(.color, SIMD3(repeating: 1)) * intensity,
                  range: try container.decodeIfPresent(Float.self, forKey: .range) ?? 8,
                  cone: cone)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([position.x, position.y, position.z], forKey: .position)

        // Split back out so a saved level reads the way a written one does: the brightest channel
        // carries the intensity and the colour is normalised against it.
        let intensity = max(color.max(), 1e-6)
        let normalised = color / intensity
        try container.encode([normalised.x, normalised.y, normalised.z], forKey: .color)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(range, forKey: .range)

        if let cone {
            try container.encode([cone.direction.x, cone.direction.y, cone.direction.z],
                                 forKey: .direction)
            try container.encode(Float.degrees(fromRadians: cone.innerAngle), forKey: .innerAngle)
            try container.encode(Float.degrees(fromRadians: cone.outerAngle), forKey: .outerAngle)
        }
    }

    /// How much of this light survives to a point: physical inverse-square, windowed to zero at the
    /// range.
    ///
    /// **Inverse square because that is what light does**, and the window because the range has to be
    /// a real edge. The window is squared so it approaches zero smoothly — a light that still
    /// contributes at its cutoff draws a visible sphere on the floor where it ends.
    ///
    /// Near the light this grows without bound, which is correct and is why the denominator has a
    /// floor: a fragment exactly at a lamp's position is a division by zero, and the pixel it
    /// produces is not "very bright", it is `NaN` and therefore black.
    public func attenuation(at point: SIMD3<Float>) -> Float {
        let offset = point - position
        let distanceSquared = max(simd_length_squared(offset), 1e-4)
        guard range > 0 else { return 0 }
        let ratio = distanceSquared / (range * range)
        let window = simd_clamp(1 - ratio * ratio, 0, 1)
        return window * window / distanceSquared * angularAttenuation(at: point)
    }

    /// Distance falloff alone, with the cone ignored.
    ///
    /// **What a per-draw test should rank by**, because a cone's contribution to a whole mesh is not
    /// a single number — see ``reaches(_:)``.
    public func radialAttenuation(at point: SIMD3<Float>) -> Float {
        let offset = point - position
        let distanceSquared = max(simd_length_squared(offset), 1e-4)
        guard range > 0 else { return 0 }
        let ratio = distanceSquared / (range * range)
        let window = simd_clamp(1 - ratio * ratio, 0, 1)
        return window * window / distanceSquared
    }

    /// What this light actually contributes at a point, as a single number.
    ///
    /// ### Why this is not distance, and not attenuation either
    ///
    /// A budget means choosing which lights to keep, and **the obvious choice — the nearest few — has
    /// an obvious bug**: *nearest* changes as the player walks, so a light drops out of the set and a
    /// surface goes dark in one frame. The fix is not a bigger budget; it is choosing by how much a
    /// light is *doing*, so one leaves the set at the point where it had nearly stopped mattering.
    ///
    /// **And attenuation alone is not enough either, which the probe this came from had wrong.** It
    /// ranked lights by falloff and ignored their brightness — so a candle at one meter outranked a
    /// floodlight at ten, and the floodlight was the one dropped. Weighting by luminance costs a dot
    /// product and makes the ordering mean what it claims.
    public func influence(at point: SIMD3<Float>) -> Float {
        attenuation(at: point) * PunctualLight.luminance(color)
    }

    /// Rec. 709 luminance: how bright a color looks, rather than how large its numbers are.
    ///
    /// Green carries most of it and blue almost none, which is why a blue lamp of the same numeric
    /// magnitude as a green one is the one to drop first.
    public static func luminance(_ color: SIMD3<Float>) -> Float {
        simd_dot(color, SIMD3(0.2126, 0.7152, 0.0722))
    }

    /// Whether this light reaches any part of a box.
    ///
    /// **Tested against the nearest point of the box, not its center.** A long wall whose center is
    /// out of range still has an end inside it, and lighting a whole draw by its center is how one
    /// end of a corridor goes dark.
    ///
    /// ### A cone cannot be tested at one point, and the error has a direction
    ///
    /// The nearest point of a box gives the *best distance*, and for a point light that settles it.
    /// For a spot it does not: the nearest corner of a wall can be outside the cone while the far end
    /// of the same wall is lit. Testing that one point would drop the light and the lit end would go
    /// dark.
    ///
    /// **A false positive costs one iteration of a shader loop. A false negative deletes light the
    /// player can see.** Those are not comparable, which is the same asymmetry ``Frustum`` is built
    /// around — so the cone is tested against the box's bounding **sphere**, which is conservative:
    /// it can say yes when the answer was no, and never the other way.
    public func reaches(_ bounds: BoundingBox) -> Bool {
        guard radialAttenuation(at: bounds.closestPoint(to: position)) > 0 else { return false }
        guard let cone else { return true }

        // The standard cone-sphere test: how far the sphere's centre lies outside the cone's surface,
        // measured perpendicular to it, against the radius.
        let center = (bounds.minimum + bounds.maximum) / 2
        let radius = simd_length(bounds.maximum - bounds.minimum) / 2
        let toCenter = center - position
        let alongAxis = simd_dot(toCenter, cone.direction)

        // Behind the lamp, or past the end of its reach.
        if alongAxis < -radius || alongAxis > range + radius { return false }

        let perpendicular = max(simd_length_squared(toCenter) - alongAxis * alongAxis, 0)
        let sinOuter = sin(cone.outerAngle)
        let distanceOutsideCone = cone.cosOuter * sqrt(perpendicular) - alongAxis * sinOuter
        return distanceOutsideCone <= radius
    }
}

/// Which lights reach a point, when there is more than one and it is not the sun.
///
/// **Extracted from a probe built to ask this question**, and stripped of the game that asked it. A
/// fragment shader cannot loop over every lamp in a building, so a game needs a budget for how many
/// may affect one draw and a rule for choosing which.
public nonisolated struct LightSet: Sendable, Equatable {

    /// How many lights may affect one draw.
    ///
    /// **A shader constant in the end**, which is why it travels with the selection rule rather than
    /// being passed around separately: the two have to agree or the shader reads past its array.
    ///
    /// Four is what the finding below was measured against. A game may raise it — and should know
    /// that raising it moves the number at which the problem happens rather than solving it.
    public let budget: Int

    /// Influence below which a light can be dropped without the player seeing it go.
    ///
    /// In the same units as ``PunctualLight/influence(at:)`` — a contribution, so it is comparable to
    /// the sun's irradiance, which in this engine is a few units.
    public let negligibleInfluence: Float

    public var lights: [PunctualLight]

    public init(lights: [PunctualLight] = [], budget: Int = 4, negligibleInfluence: Float = 0.02) {
        self.lights = lights
        self.budget = max(0, budget)
        self.negligibleInfluence = negligibleInfluence
    }

    /// The lights that reach a point, strongest first, at most ``budget`` of them.
    public func affecting(_ point: SIMD3<Float>) -> [PunctualLight] {
        strongest { $0.influence(at: point) }
    }

    /// The lights that reach any part of a box, ranked by their best contribution to it.
    ///
    /// **What a per-draw selection actually wants.** Lights are chosen once per object, not per
    /// fragment, so the question is which lights matter to *this mesh* — and a light matters if it
    /// reaches the nearest part of it.
    public func affecting(_ bounds: BoundingBox) -> [PunctualLight] {
        lights
            .filter { $0.reaches(bounds) }
            // **Ranked by distance alone**, deliberately: a spot's angular term at the box's nearest
            // point can be zero while the far end of the box is brightly lit, and ranking by it would
            // sort a light that matters to the bottom of the list and out of the budget.
            .map { (light: $0,
                    influence: $0.radialAttenuation(at: bounds.closestPoint(to: $0.position))
                             * PunctualLight.luminance($0.color)) }
            .sorted { $0.influence > $1.influence }
            .prefix(budget)
            .map(\.light)
    }

    private func strongest(by influence: (PunctualLight) -> Float) -> [PunctualLight] {
        lights
            .map { (light: $0, influence: influence($0)) }
            .filter { $0.influence > 0 }
            .sorted { $0.influence > $1.influence }
            .prefix(budget)
            .map(\.light)
    }

    /// Whether more lights than the budget are meaningfully lit at this point.
    ///
    /// ### The probe's real finding, and it is a constraint on levels rather than a bug in code
    ///
    /// **A hard budget cannot promise a smooth hand-over in an arbitrary arrangement.** If five lights
    /// all contribute at a point, one is dropped, and how visible that is depends entirely on how the
    /// level was built. Ordering by influence does not save it, and a bigger budget only moves the
    /// number at which it happens.
    ///
    /// So the promise is conditional, and this checks the condition: **where no more than ``budget``
    /// lights are above ``negligibleInfluence``, nothing the player can see is ever dropped.** A level that
    /// violates it has a lighting fault built into its geometry — and one that is findable before it
    /// ships rather than after somebody reports a flicker in one corridor.
    public func isOverSubscribed(at point: SIMD3<Float>) -> Bool {
        lights.count { $0.influence(at: point) > negligibleInfluence } > budget
    }

    /// Every point of a level worth checking, and whether any of them is over-subscribed.
    ///
    /// A convenience for exactly the check above, run over the places a player can stand.
    public func overSubscribedPoints(among points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        points.filter { isOverSubscribed(at: $0) }
    }
}
