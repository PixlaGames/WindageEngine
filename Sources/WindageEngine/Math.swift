//
//  Math.swift
//  WindageEngine
//

import simd

// `nonisolated` throughout, because this is pure arithmetic: the engine defaults every declaration to
// @MainActor, which would otherwise make a projection unusable from a test, a worker thread, or a
// render thread — none of which is a UI context.
//
// Transform helpers, as initializers and members on the simd types — the Swift spelling of what Apple's
// Metal template wrote as C functions (`matrix4x4_translation`, `radians_from_degrees`…).

public extension simd_float4x4 {

    /// A rotation of `angle` radians about `axis`, right-handed: positive turns counter-clockwise when
    /// looking down the axis toward the origin. `axis` need not be unit length.
    nonisolated init(rotationAngle angle: Float, axis: SIMD3<Float>) {
        let unitAxis = normalize(axis)
        let ct = cosf(angle)
        let st = sinf(angle)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        self.init(columns: (SIMD4<Float>(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                            SIMD4<Float>(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                            SIMD4<Float>(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                            SIMD4<Float>(                  0,                   0,                   0, 1)))
    }

    /// A translation by `offset`.
    nonisolated init(translation offset: SIMD3<Float>) {
        self.init(columns: (SIMD4<Float>(1, 0, 0, 0),
                            SIMD4<Float>(0, 1, 0, 0),
                            SIMD4<Float>(0, 0, 1, 0),
                            SIMD4<Float>(offset, 1)))
    }

    /// Right-handed perspective projection using **reversed-Z with an infinite far plane** — the
    /// engine's one projection.
    ///
    /// Maps the near plane to depth 1 and infinite distance to depth 0 — the opposite of the
    /// conventional near-0/far-1. Depth is stored as floating point, and floats hold far more precision
    /// near zero, so the conventional mapping spends almost all of it in the first few meters and leaves
    /// the far field to z-fight. A game about reading a target at 800 m wants the precision where the
    /// distance is.
    ///
    /// Three things have to agree or nothing renders at all:
    ///   - this projection,
    ///   - `depthCompareFunction = .greater` (nearer is now a larger value),
    ///   - a depth clear value of 0.
    ///
    /// `FrameRenderer` supplies the other two, so a game that uses it gets a consistent set rather than
    /// three constants it has to remember to match.
    ///
    /// The far plane is gone rather than merely large: depth approaches 0 asymptotically, so there is
    /// no view distance to tune and nothing to clip against at range.
    ///
    /// ### Confining it to a slice of the depth buffer: a weapon in the player's hands
    ///
    /// A first-person viewmodel is not part of the world and cannot be projected like it. Two things go
    /// wrong if you try.
    ///
    /// **It is too big.** At a 65° field of view a real rifle held 30 cm from the eye genuinely fills a
    /// quarter of the screen. Every shooter solves this with a *narrower* field of view for the weapon
    /// than for the world — around 55° against 65° here — which is a projection, not a size. Shrinking
    /// the model instead is the shortcut, and it makes the weapon geometrically a lie: anything measured
    /// off it afterwards (a muzzle position, a bipod's contact, a bolt's travel) is computed in a space
    /// that only happens to look right.
    ///
    /// **It intersects the world.** A rifle 90 cm long, held by a player who can stand 45 cm from a
    /// wall, pokes through the wall. That is physically true and looks broken. Reserving the front of
    /// the depth buffer for the viewmodel puts it in front of everything without an extra pass and
    /// without breaking its *own* occlusion — a bolt behind a receiver still hides behind it, because
    /// the slice is monotonic.
    ///
    /// - Parameters:
    ///   - fovY: the vertical field of view, in radians.
    ///   - aspectRatio: width over height.
    ///   - nearZ: the near plane's distance, in meters.
    ///   - depthRange: where in the buffer this projection lands. `0...1`, the default, is the whole
    ///     buffer. `0.9...1` is the front tenth: with a 0.1 m near plane, world geometry only reaches
    ///     depth 0.9 at **11 cm** from the eye, which is nearer than a player can get to anything.
    ///
    /// > Reversed-Z, so **larger is nearer** — `depthRange.upperBound` is the near end. Reading it the
    /// > other way puts the weapon behind the world, which renders as the weapon simply not being there.
    nonisolated init(perspectiveFovY fovY: Float, aspectRatio: Float, nearZ: Float,
                     depthRange: ClosedRange<Float> = 0...1) {
        let ys = 1 / tanf(fovY * 0.5)
        let xs = ys / aspectRatio
        let low = depthRange.lowerBound
        let span = depthRange.upperBound - low
        // Derived rather than tuned: the unmapped form gives depth = nearZ / distance, and this wants
        // `low + span * nearZ / distance`. Multiplying out against clip.w = -z gives these two terms.
        // `0 - low` rather than `-low`, so the whole-buffer matrix holds +0 there, bit for bit the one
        // the engine has always drawn with.
        self.init(columns: (SIMD4<Float>(xs,  0,           0,  0),
                            SIMD4<Float>( 0, ys,           0,  0),
                            SIMD4<Float>( 0,  0,     0 - low, -1),
                            SIMD4<Float>( 0,  0, span * nearZ,  0)))
    }

    /// The same transform with its scale removed, leaving rotation and position.
    ///
    /// ### Why a hierarchy needs this and a rig does not
    ///
    /// **A child inherits its parent's scale, which is right for a limb and wrong for a held object.** A
    /// rig exported from a package that works in centimeters carries a hundredfold scale down to the
    /// wrist, and it belongs there — the arm is a hundred units long in that space. Hang a lantern off
    /// the same matrix and the lantern is drawn at one percent of its size, in a place that is otherwise
    /// correct, which reads as the wrong mesh rather than as the wrong space.
    ///
    /// The alternative — an attachment flag that says "do not inherit scale" — puts a policy inside the
    /// hierarchy that only some callers want. This is the same thing at the call site, where the caller
    /// can see what it is attaching to.
    ///
    /// **A mirrored basis stays mirrored.** Each axis is normalized, and nothing here tries to decide
    /// that a negative determinant was a mistake; a shear is flattened onto its own axes, which is the
    /// only thing it can mean once the scale is gone.
    nonisolated var withoutScale: simd_float4x4 {
        func unit(_ column: SIMD4<Float>) -> SIMD4<Float> {
            let axis = SIMD3(column.x, column.y, column.z)
            let length = simd_length(axis)
            // A zero axis has no direction to preserve, and normalising it would make every component of
            // the matrix NaN — which draws nothing at all, from anywhere.
            guard length > 1e-6 else { return column }
            return SIMD4(axis / length, 0)
        }
        return simd_float4x4(columns: (unit(columns.0), unit(columns.1), unit(columns.2), columns.3))
    }
}

public extension Float {

    /// `degrees` as radians.
    nonisolated static func radians(fromDegrees degrees: Float) -> Float {
        (degrees / 180) * .pi
    }

    /// `radians` as degrees. **Needed the moment angles are something a file stores** rather than
    /// something a game computes once — a level writes degrees, and whatever reads it has to be able to
    /// write them out again unchanged.
    nonisolated static func degrees(fromRadians radians: Float) -> Float {
        (radians / .pi) * 180
    }

    /// `angle`, in radians, wrapped to `(-π, π]`.
    ///
    /// **What keeps a yaw from growing**: a session spinning steadily for an hour would otherwise
    /// reach tens of thousands of radians, where a 32-bit float can no longer resolve a tenth of a
    /// degree and aim gets visibly coarse. ``Camera/yaw`` is kept wrapped by it.
    nonisolated static func wrappedAngle(_ angle: Float) -> Float {
        var wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if wrapped > .pi { wrapped -= 2 * .pi }
        if wrapped <= -.pi { wrapped += 2 * .pi }
        return wrapped
    }

    /// The signed shortest turn, in radians, from one angle to another — within `(-π, π]`.
    ///
    /// Without it, interpolating across the ±π seam spins the long way round: turning from 179° to
    /// -179° is 2° of movement, but a naive blend travels 358° of it in one frame.
    nonisolated static func shortestAngle(from start: Float, to end: Float) -> Float {
        wrappedAngle(end - start)
    }
}

/// The transform that keeps a normal perpendicular to its surface: the inverse transpose of the
/// upper-left 3×3.
///
/// For rotation and uniform scale this equals the matrix itself, so it looks like ceremony in any
/// scene built from translations. It stops being ceremony the first time anything is scaled
/// unevenly: the plain matrix shears normals off the surface, and the shading goes subtly wrong in a
/// way that is hard to attribute afterwards.
public nonisolated func normalMatrix(from modelView: simd_float4x4) -> simd_float3x3 {
    let upperLeft = simd_float3x3(columns: (
        SIMD3(modelView.columns.0.x, modelView.columns.0.y, modelView.columns.0.z),
        SIMD3(modelView.columns.1.x, modelView.columns.1.y, modelView.columns.1.z),
        SIMD3(modelView.columns.2.x, modelView.columns.2.y, modelView.columns.2.z)
    ))
    return simd_transpose(simd_inverse(upperLeft))
}
