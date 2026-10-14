//
//  Frustum.swift
//  WindageEngine
//

import simd

/// The planes of a view-projection, and whether a box is worth drawing.
///
/// **Five planes, not six.** See `init` — the engine's infinite far plane has no far plane to
/// extract, which is the first thing this probe turned up.
///
/// **Extracted 2026-09-08, once two different games wanted it.** It was written for dense, close,
/// occluding geometry — trenches, where most of a map is behind a wall of earth — under a note
/// saying an open plain does not need culling, because nearly everything on one is in front of the
/// player.
///
/// **That is only true while an open scene is also a sparse one.** A 65° field of view is under a
/// fifth of the circle, so in an 854-object scene most of it sits behind the player's shoulders
/// whether or not anything occludes it. Working, tested code from two consumers, which is what the
/// extraction rule asks for.
///
/// ### The asymmetry that decides every detail here
///
/// **A false positive costs a draw call. A false negative deletes something the player can see.**
/// Those are not comparable, so everything below leans toward keeping: the test is a conservative
/// box-against-plane check, and an object straddling a plane is kept.
///
/// ### Reversed-Z, because this codebase has one depth convention
///
/// The planes come out of the matrix by Gribb–Hartmann, which is derived for a clip space where the
/// near plane maps to *w* and the far to *-w*. Under reversed-Z near maps to **1** and far to **0**,
/// so the near and far rows are the other way round — extract them the textbook way and the near
/// plane culls everything close to the camera, which in a trench is everything that matters.
public nonisolated struct Frustum: Sendable, Equatable {

    /// Each plane as `(normal, distance)`, pointing **inward**: a point is inside when
    /// `dot(normal, point) + distance >= 0` for all five.
    public private(set) var planes: [SIMD4<Float>] = []

    /// Builds the frustum from a world-to-clip matrix.
    public init(viewProjection m: simd_float4x4) {
        // Rows of the matrix, since simd stores columns.
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)

        // Left, right, bottom, top are convention-independent.
        var extracted = [r3 + r0, r3 - r0, r3 + r1, r3 - r1]

        // **Reversed-Z: near is z = w, far is z = 0.** The usual `r3 + r2` / `r3 - r2` pair is for a
        // 0…w depth range and gets these backwards.
        extracted.append(r3 - r2)   // near
        extracted.append(r2)        // far

        // **A degenerate plane is dropped, and finding one here was the point of the probe.**
        // The engine's projection has an *infinite* far plane, so its far row is `(0, 0, 0, near)` —
        // a zero normal, because there is no far plane to extract. That is not a bug to work around;
        // it means a Windage Engine frustum has **five** planes, and code that assumes six is code
        // written for a different projection.
        planes = extracted.compactMap { plane in
            let length = simd_length(SIMD3(plane.x, plane.y, plane.z))
            guard length > 1e-6 else { return nil }
            return plane / length
        }
    }

    /// Whether any part of the box could be visible — **may**, because the answer is conservative: a
    /// box near a corner of the frustum, outside it but not wholly beyond any one plane, is kept.
    ///
    /// The standard conservative test: for each plane, take the box corner furthest along the
    /// plane's normal — the *positive vertex* — and reject only if even that corner is outside. That
    /// keeps anything straddling a plane, which is the side of the asymmetry to be wrong on.
    public func mayIntersect(_ box: BoundingBox) -> Bool {
        for plane in planes {
            let normal = SIMD3(plane.x, plane.y, plane.z)
            let positive = SIMD3(normal.x >= 0 ? box.maximum.x : box.minimum.x,
                                 normal.y >= 0 ? box.maximum.y : box.minimum.y,
                                 normal.z >= 0 ? box.maximum.z : box.minimum.z)
            if simd_dot(normal, positive) + plane.w < 0 { return false }
        }
        return true
    }
}
