//
//  BoundingBox.swift
//  WindageEngine
//

import simd

/// An axis-aligned box, and the ray test that goes with it.
///
/// **Deliberately the crudest useful shape.** Triangle-accurate hit testing needs an acceleration
/// structure, and a box is wrong in the corners — but it answers "did the round reach that thing"
/// for scenery-sized objects, which is what ranging and impact need first. The seam to replace it
/// later is this one type.
public nonisolated struct BoundingBox: Sendable, Equatable {

    public var minimum: SIMD3<Float>
    public var maximum: SIMD3<Float>

    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
    public var size: SIMD3<Float> { maximum - minimum }

    /// Whether a point is inside, edges included.
    ///
    /// **Inclusive on purpose.** A point exactly on a face is a coincidence that happens constantly
    /// with hand-authored levels, where everything sits on round numbers — and "on the wall" reading
    /// as "outside the wall" is how a player ends up standing in one.
    public func contains(_ point: SIMD3<Float>) -> Bool {
        point.x >= minimum.x && point.x <= maximum.x
            && point.y >= minimum.y && point.y <= maximum.y
            && point.z >= minimum.z && point.z <= maximum.z
    }

    /// The box containing this one after a transform.
    ///
    /// **Re-derived from the eight corners, not by transforming two points.** Transforming only the
    /// min and max gives the right answer for a translation and a wrong one for any rotation — the
    /// resulting "box" can be inside-out or far too small, and the failure is a shot that passes
    /// through a target rather than an obvious visual glitch.
    public func transformed(by matrix: simd_float4x4) -> BoundingBox {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for index in 0..<8 {
            let corner = SIMD3<Float>(
                index & 1 == 0 ? minimum.x : maximum.x,
                index & 2 == 0 ? minimum.y : maximum.y,
                index & 4 == 0 ? minimum.z : maximum.z)
            let world = matrix * SIMD4<Float>(corner, 1)
            low = simd_min(low, SIMD3(world.x, world.y, world.z))
            high = simd_max(high, SIMD3(world.x, world.y, world.z))
        }
        return BoundingBox(minimum: low, maximum: high)
    }

    /// Distance along the ray to the nearest entry point, or nil if it misses.
    ///
    /// The slab method: clip the ray against each pair of parallel faces and keep the overlap. The
    /// division by zero for a ray exactly parallel to an axis is intentional and correct — IEEE
    /// infinities make the comparisons fall out the right way, where guarding against it with a
    /// branch is where implementations usually go wrong.
    ///
    /// - Parameter direction: the distance comes back in multiples of its length, so pass a unit vector to
    ///   get one in the box's own units.
    public func hitDistance(ofRayFrom origin: SIMD3<Float>, direction: SIMD3<Float>,
                            maxDistance: Float = .greatestFiniteMagnitude) -> Float? {
        let inverse = 1 / direction
        let t0 = (minimum - origin) * inverse
        let t1 = (maximum - origin) * inverse

        let near = simd_min(t0, t1)
        let far = simd_max(t0, t1)

        let entry = max(max(near.x, near.y), near.z)
        let exit = min(min(far.x, far.y), far.z)

        guard exit >= max(entry, 0), entry <= maxDistance else { return nil }
        // A ray starting inside the box hits at zero, not at a negative distance behind itself.
        return max(entry, 0)
    }

    /// Distance from `start` to where a segment running to `end` first touches the box, or nil if it
    /// does not — 0 when `start` is inside.
    public func hitDistance(ofSegmentFrom start: SIMD3<Float>, to end: SIMD3<Float>) -> Float? {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else {
            let inside = all(start .>= minimum) && all(start .<= maximum)
            return inside ? 0 : nil
        }
        return hitDistance(ofRayFrom: start, direction: delta / length, maxDistance: length)
    }

    /// The point of the box nearest to somewhere else, which is the box itself if it contains it.
    ///
    /// **What a light's reach should be measured against.** A long wall whose *center* is out of a
    /// lamp's range still has an end inside it, and testing the center is how one end of a corridor
    /// goes dark while the lamp is plainly shining on it.
    public func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(point, minimum, maximum)
    }

    /// The same box with a margin on every side.
    ///
    /// **For the cases where a measured box is known to be an underestimate**, which is every skinned
    /// mesh: a loader measures the bind pose, and an arm raised at runtime leaves it. A culling test
    /// against the measured box then deletes the character's shadow at exactly the moment it moves.
    ///
    /// A negative margin shrinks, and is allowed to invert the box — a caller asking for that is
    /// asking for an empty volume, and quietly clamping it would hide the mistake.
    public func expanded(by margin: Float) -> BoundingBox {
        BoundingBox(minimum: minimum - SIMD3(repeating: margin),
                    maximum: maximum + SIMD3(repeating: margin))
    }
}
