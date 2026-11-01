//
//  WorldBoundary.swift
//  WindageEngine
//

import Foundation
import simd

/// **The edge of a world**: a shell round the whole map that nothing in it leaves — a dome, or walls with a ceiling —
/// and, under its floor, a net that catches anything that falls out.
///
/// ### Why every world has one
///
/// A map with water, cliffs or fire round it still has an edge, and a bug — a gap between two pieces, a hole in the
/// ground, a push in the wrong place at the wrong speed — finds it. A player who gets past it falls for ever, or walks
/// out across nothing. **The shell stops the walk; the net stops the fall**, and the fall is the commoner of the two:
/// most players who leave a world leave it downwards, through the floor, where no wall can stand.
///
/// ### Its shape
///
/// A **footprint** on the ground — a rectangle with rounded corners, which is a circle when it is square and fully
/// rounded — and a **profile** over it:
///
/// - ``Profile/dome``: the walls rise straight from the floor to ``spring`` — the ground, when fitted — then curve over
///   into a roof. Over a round footprint the curve is a quarter ellipse; over a longer one the sides curve in by the
///   same amount at the same height, so a long map gets a long dome rather than a round one with its ends cut off.
///   **Curving from the ground, not the floor**: the net is twenty meters under the ground, and a dome curving from
///   there already leans in meters by head height on a small map.
/// - ``Profile/walls``: straight up to ``height``, with a flat ceiling.
///
/// ``base`` is its floor, below the lowest ground: what goes under it has fallen out of the world, and is caught
/// (``isBelowFloor(_:)``). ``CharacterController`` does the catching for a body that walks; a game catches anything
/// else of its own.
///
/// **A value, as `Volume` is**: what a world is, with no GPU in it. ``BoundaryRenderer`` draws one.
public nonisolated struct WorldBoundary: Sendable, Equatable, Codable {

    /// How the walls rise from the footprint.
    public enum Profile: String, Sendable, Codable, CaseIterable {
        /// Walls curving over into a roof.
        case dome
        /// Straight walls and a flat ceiling.
        case walls
    }

    public var profile: Profile
    /// The footprint's middle, across the ground (x, z).
    public var center: SIMD2<Float>
    /// Half the footprint's size along x and z, meters.
    public var halfSize: SIMD2<Float>
    /// How round the footprint's corners are, 0 (square) to 1 (as round as the shorter side allows — a circle when the
    /// footprint is square).
    public var roundness: Float
    /// The floor's height: anything below it has fallen out of the world.
    public var base: Float
    /// How high the top is over ``base``, meters — a dome's crown, the walls' ceiling.
    public var height: Float
    /// How high over ``base`` a dome's walls begin to curve in, meters; below it they are straight. Walls ignore it.
    public var spring: Float
    /// How it looks, when it is seen at all.
    public var look: Look

    public init(profile: Profile = .dome, center: SIMD2<Float> = .zero, halfSize: SIMD2<Float> = SIMD2(100, 100),
                roundness: Float = 1, base: Float = -20, height: Float = 120, spring: Float = 0, look: Look = Look()) {
        self.profile = profile
        self.center = center
        self.halfSize = simd_max(halfSize, SIMD2(repeating: 0.5))
        self.roundness = simd_clamp(roundness, 0, 1)
        self.base = base
        self.height = max(height, 1)
        self.spring = simd_clamp(spring, 0, self.height - 1)
        self.look = look
    }

    /// **One that fits a world's extent**: its footprint `inset` inside the ground's edge, so the last meters of a
    /// ground that ends are never reached; its floor `fallMargin` below the lowest point; its top clearing the highest
    /// by `headroom` — and a dome curving from the lowest ground, rising at least as far as it is wide across its
    /// shorter side, so it reads as a dome.
    public static func fitted(minimum: SIMD3<Float>, maximum: SIMD3<Float>, profile: Profile = .dome,
                              roundness: Float = 0.3, inset: Float = 1, fallMargin: Float = 20, headroom: Float = 20,
                              look: Look = Look()) -> WorldBoundary {
        let half = simd_max((SIMD2(maximum.x, maximum.z) - SIMD2(minimum.x, minimum.z)) / 2 - inset, SIMD2(repeating: 0.5))
        let base = minimum.y - fallMargin
        var height = maximum.y + headroom - base
        if profile == .dome { height = max(height, fallMargin + simd_reduce_min(half)) }
        return WorldBoundary(profile: profile, center: (SIMD2(maximum.x, maximum.z) + SIMD2(minimum.x, minimum.z)) / 2,
                             halfSize: half, roundness: roundness, base: base, height: height,
                             spring: profile == .dome ? fallMargin : 0, look: look)
    }

    /// **Read with every key optional**: a saved boundary missing one added since keeps everything it did say, and an
    /// out-of-range number is clamped as ``init(profile:center:halfSize:roundness:base:height:spring:look:)`` clamps it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorldBoundary()
        self.init(profile: (try? c.decodeIfPresent(Profile.self, forKey: .profile)) ?? d.profile,
                  center: (try? c.decodeIfPresent(SIMD2<Float>.self, forKey: .center)) ?? d.center,
                  halfSize: (try? c.decodeIfPresent(SIMD2<Float>.self, forKey: .halfSize)) ?? d.halfSize,
                  roundness: (try? c.decodeIfPresent(Float.self, forKey: .roundness)) ?? d.roundness,
                  base: (try? c.decodeIfPresent(Float.self, forKey: .base)) ?? d.base,
                  height: (try? c.decodeIfPresent(Float.self, forKey: .height)) ?? d.height,
                  spring: (try? c.decodeIfPresent(Float.self, forKey: .spring)) ?? d.spring,
                  look: (try? c.decodeIfPresent(Look.self, forKey: .look)) ?? d.look)
    }

    /// The top's height in the world.
    public var top: Float { base + height }

    /// The footprint's corner radius, meters.
    public var cornerRadius: Float { roundness * simd_reduce_min(halfSize) }

    /// **How far in from the footprint's edge the walls stand at height `y`.** Nothing for walls; for a dome, nothing
    /// up to ``spring``, then the quarter-ellipse of its shorter half-size over the rest of its height — so over a round
    /// footprint, an ellipsoid exactly.
    public func inset(atHeight y: Float) -> Float {
        guard profile == .dome else { return 0 }
        let t = simd_clamp((y - base - spring) / (height - spring), 0, 1)
        return simd_reduce_min(halfSize) * (1 - (1 - t * t).squareRoot())
    }

    /// The footprint at height `y`, `margin` further in: its half-size and corner radius. **The inward offset of a
    /// rounded rectangle is a rounded rectangle**, its corners sharpening once the offset passes their radius.
    func footprint(atHeight y: Float, margin: Float) -> (half: SIMD2<Float>, corner: Float) {
        let k = inset(atHeight: y) + margin
        let half = simd_max(halfSize - k, .zero)
        return (half, min(max(cornerRadius - k, 0), simd_reduce_min(half)))
    }

    /// How far `point` (x, z) is outside the footprint at height `y`, `margin` in — negative inside.
    func distanceOutside(_ point: SIMD2<Float>, atHeight y: Float, margin: Float = 0) -> Float {
        let (half, corner) = footprint(atHeight: y, margin: margin)
        let q = abs(point - center) - (half - corner)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - corner
    }

    /// Whether `point` is inside the shell, `margin` from its walls and ceiling. The floor is not a wall: what is
    /// below it is ``isBelowFloor(_:)``, and is caught rather than kept out.
    public func contains(_ point: SIMD3<Float>, margin: Float = 0) -> Bool {
        point.y <= top - margin && distanceOutside(SIMD2(point.x, point.z), atHeight: point.y, margin: margin) <= 0
    }

    /// Whether `point` has fallen through the floor.
    public func isBelowFloor(_ point: SIMD3<Float>) -> Bool { point.y < base }

    /// **A body kept inside**: feet at `feet`, `radius` round and `height` tall, moved the least distance that puts it
    /// inside — down from the ceiling, and across to the nearest point the walls allow, so a body walking into them
    /// slides along them. **Measured at its head**, where a dome's walls are nearest. A body already inside comes back
    /// unchanged, to the bit.
    public func contain(feet: SIMD3<Float>, radius: Float, height bodyHeight: Float) -> SIMD3<Float> {
        var feet = feet
        if feet.y + bodyHeight > top { feet.y = top - bodyHeight }
        let across = keepInside(SIMD2(feet.x, feet.z), atHeight: feet.y + bodyHeight, margin: radius)
        return SIMD3(across.x, feet.y, across.y)
    }

    /// A point — a camera, a thrown thing — kept `margin` inside.
    public func contain(_ point: SIMD3<Float>, margin: Float = 0) -> SIMD3<Float> {
        let y = min(point.y, top - margin)
        let across = keepInside(SIMD2(point.x, point.z), atHeight: y, margin: margin)
        return SIMD3(across.x, y, across.y)
    }

    /// The nearest point to `point` (x, z) in the footprint at height `y`, `margin` in.
    func keepInside(_ point: SIMD2<Float>, atHeight y: Float, margin: Float) -> SIMD2<Float> {
        guard distanceOutside(point, atHeight: y, margin: margin) > 0 else { return point }
        let (half, corner) = footprint(atHeight: y, margin: margin)
        let offset = point - center
        let a = abs(offset), core = half - corner
        // The rounded rectangle is its core rectangle grown by the corner radius: the nearest point is the core's
        // nearest point, then out toward the point by that radius.
        let onCore = simd_min(a, core)
        let away = a - onCore
        let length = simd_length(away)
        let nearest = length > 1e-6 ? onCore + away / length * corner : simd_min(a, half)
        let sign = SIMD2<Float>(offset.x < 0 ? -1 : 1, offset.y < 0 ? -1 : 1)
        return center + nearest * sign
    }

    /// **How far along a line from `origin` the shell is met**, up to `limit` — a camera pulled in ahead of it, a shot
    /// that strikes it — or nil if the line stays inside. A line that starts outside meets it at once.
    ///
    /// Marched in steps no longer than ``exitStep``, then halved to a centimeter: a dome's walls over a long footprint
    /// have no tidy closed form, and a few hundred checks of a rounded rectangle cost less than a frame's worth of
    /// anything else.
    public func exit(from origin: SIMD3<Float>, direction: SIMD3<Float>, limit: Float) -> Float? {
        guard limit > 0, simd_length_squared(direction) > 0 else { return nil }
        let d = simd_normalize(direction)
        guard contains(origin) else { return 0 }
        let steps = max(1, Int((limit / Self.exitStep).rounded(.up)))
        var inside: Float = 0
        for i in 1...steps {
            let t = min(Float(i) * Self.exitStep, limit)
            if !contains(origin + d * t) {
                var outside = t
                while outside - inside > 0.01 {
                    let middle = (inside + outside) / 2
                    if contains(origin + d * middle) { inside = middle } else { outside = middle }
                }
                return inside
            }
            inside = t
        }
        return nil
    }

    /// The longest step ``exit(from:direction:limit:)`` takes before looking again: thinner than any wall a line could
    /// cross between two looks, since the shell is one surface and a line inside meets it once.
    public static let exitStep: Float = 2

    /// The perimeter of the footprint at the floor, meters — what a pattern on the walls is laid along.
    public var perimeter: Float {
        let r = cornerRadius
        return 4 * (halfSize.x - r) + 4 * (halfSize.y - r) + 2 * .pi * r
    }
}

// MARK: - How it looks

extension WorldBoundary {

    /// **How a boundary is drawn**, if at all — a game's choice per world. The defaults are a quiet lattice that shows
    /// only where somebody comes near it: a world's edge is something to find, not something to stare at.
    public nonisolated struct Look: Sendable, Equatable, Codable {

        /// The pattern on its surface.
        public enum Style: String, Sendable, Codable, CaseIterable {
            /// A hexagonal lattice, shimmering, rings where it is met.
            case lattice
            /// A square grid.
            case grid
            /// **An energy field**: a lattice under a bright rim where it is seen edge-on, a current flowing through
            /// it, ripples where it is struck.
            case forceField
            /// A soft wall of haze, no lines — a world that ends in weather.
            case haze
        }

        /// When it shows.
        public enum Visibility: String, Sendable, Codable, CaseIterable {
            /// The whole shell, from anywhere inside it.
            case always
            /// Only within ``Look/nearDistance`` of the player, brightest where they meet it.
            case near
            /// Never drawn; it still stops everything.
            case hidden
        }

        public var style: Style
        public var visibility: Visibility
        /// Its color, linear.
        public var color: SIMD3<Float>
        /// How strongly it shows, 0…1.
        public var opacity: Float
        /// A pattern cell's size, meters.
        public var patternSize: Float
        /// How fast it moves — shimmer, current, haze — 0 still, 1 the default pace.
        public var motion: Float
        /// How near the player must come before a ``Visibility/near`` boundary shows, meters.
        public var nearDistance: Float

        public init(style: Style = .lattice, visibility: Visibility = .near,
                    color: SIMD3<Float> = SIMD3(0.35, 0.75, 1.0), opacity: Float = 0.6, patternSize: Float = 1.3,
                    motion: Float = 1, nearDistance: Float = 22) {
            self.style = style
            self.visibility = visibility
            self.color = simd_max(color, .zero)
            self.opacity = simd_clamp(opacity, 0, 1)
            self.patternSize = max(patternSize, 0.1)
            self.motion = max(motion, 0)
            self.nearDistance = max(nearDistance, 1)
        }

        /// Read with every key optional, as ``WorldBoundary`` is.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Look()
            self.init(style: (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style,
                      visibility: (try? c.decodeIfPresent(Visibility.self, forKey: .visibility)) ?? d.visibility,
                      color: (try? c.decodeIfPresent(SIMD3<Float>.self, forKey: .color)) ?? d.color,
                      opacity: (try? c.decodeIfPresent(Float.self, forKey: .opacity)) ?? d.opacity,
                      patternSize: (try? c.decodeIfPresent(Float.self, forKey: .patternSize)) ?? d.patternSize,
                      motion: (try? c.decodeIfPresent(Float.self, forKey: .motion)) ?? d.motion,
                      nearDistance: (try? c.decodeIfPresent(Float.self, forKey: .nearDistance)) ?? d.nearDistance)
        }

        /// An energy dome seen from anywhere: the look a game about force fields wants.
        public static let forceField = Look(style: .forceField, visibility: .always, color: SIMD3(0.2, 0.55, 1.0),
                                            opacity: 0.5, patternSize: 2.5, motion: 1, nearDistance: 40)
    }
}
