//
//  FrustumTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct FrustumTests {

    /// The same projection the engine builds, so the convention under test is the real one.
    private var frustum: Frustum {
        let projection = simd_float4x4(
            perspectiveFovY: 65 * .pi / 180, aspectRatio: 1.6, nearZ: 0.1)
        return Frustum(viewProjection: projection)   // camera at the origin, looking down -Z
    }

    private func box(at center: SIMD3<Float>, size: Float = 1) -> BoundingBox {
        BoundingBox(minimum: center - SIMD3(repeating: size / 2),
                    maximum: center + SIMD3(repeating: size / 2))
    }

    @Test("Something straight ahead is visible")
    func aheadIsVisible() {
        #expect(frustum.mayIntersect(box(at: SIMD3(0, 0, -20))))
        #expect(frustum.mayIntersect(box(at: SIMD3(0, 0, -500))))
    }

    /// **The near plane is the one reversed-Z gets backwards.** Extracted the textbook way it culls
    /// everything close to the camera — which in a trench is everything that matters, and reads as
    /// geometry failing to load rather than as a culling bug.
    @Test("Reversed-Z near and far are the right way round")
    func nearPlaneIsNotInverted() {
        #expect(frustum.mayIntersect(box(at: SIMD3(0, 0, -1))), "a close object was culled by the near plane")
        #expect(frustum.mayIntersect(box(at: SIMD3(0, 0, -100000))), "an infinite far plane rejected something distant")
    }

    @Test("Something behind the camera is not")
    func behindIsCulled() {
        #expect(!frustum.mayIntersect(box(at: SIMD3(0, 0, 40))))
    }

    @Test("Something far off to the side is not")
    func offToTheSideIsCulled() {
        #expect(!frustum.mayIntersect(box(at: SIMD3(400, 0, -20))))
        #expect(!frustum.mayIntersect(box(at: SIMD3(0, 400, -20))))
    }

    /// **A false positive costs a draw; a false negative deletes something the player can see.**
    /// Those are not comparable, so a box straddling a plane is kept.
    @Test("A box straddling the edge is kept, not dropped")
    func straddlingIsKept() {
        // Wide enough to reach well outside the frustum, centred outside it, but still overlapping.
        let straddling = BoundingBox(minimum: SIMD3(-2000, -1, -21), maximum: SIMD3(-8, 1, -19))
        #expect(frustum.mayIntersect(straddling), "a box overlapping the view was culled")
    }

    /// **Five planes, not six — the first thing this probe found.**
    ///
    /// The engine's projection has an infinite far plane, so the far row extracts as a zero normal:
    /// there is no far plane. Anything written expecting six is written for a different projection,
    /// and would either carry a plane that always passes or divide by zero normalising it.
    ///
    /// They must also be unit-normalised, or the positive-vertex test compares distances in
    /// arbitrary units — which fails only for some box sizes, at some distances.
    @Test("Five normalised planes, because the far plane is at infinity")
    func planesAreNormalised() {
        let planes = frustum.planes
        #expect(planes.count == 5, "an infinite far plane yields five, not six")
        for plane in planes {
            let length = simd_length(SIMD3(plane.x, plane.y, plane.z))
            #expect(abs(length - 1) < 1e-4, "a plane normal has length \(length)")
        }
    }
}
