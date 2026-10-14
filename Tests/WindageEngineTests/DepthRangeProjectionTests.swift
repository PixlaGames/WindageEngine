import Testing
import simd
@testable import WindageEngine

/// **Reversed-Z is the one convention where getting it wrong renders nothing at all**, so the
/// arithmetic is pinned rather than eyeballed.
struct DepthRangeProjectionTests {

    private let fov = Float.radians(fromDegrees: 65)
    private let near: Float = 0.1

    /// Depth of a point `distance` metres in front of the camera.
    private func depth(_ matrix: matrix_float4x4, at distance: Float) -> Float {
        let clip = matrix * SIMD4<Float>(0, 0, -distance, 1)   // −z is forward
        return clip.z / clip.w
    }

    @Test("The whole range is the world projection, exactly")
    func fullRangeMatchesTheOriginal() {
        let world = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6, nearZ: near)
        let ranged = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6,
                                                             nearZ: near, depthRange: 0...1)
        #expect(world == ranged)
    }

    /// Near is 1 and far approaches 0 — the reversed-Z convention this engine enforces everywhere.
    @Test("Reversed-Z: the near plane is 1 and distance falls toward 0")
    func reversedZ() {
        let m = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6, nearZ: near)
        #expect(abs(depth(m, at: near) - 1) < 1e-5)
        #expect(depth(m, at: 10) < depth(m, at: 1))
        #expect(depth(m, at: 10_000) > 0)
    }

    @Test("A slice stays inside its slice")
    func sliceIsRespected() {
        let m = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6,
                                                        nearZ: near, depthRange: 0.9...1)
        #expect(abs(depth(m, at: near) - 1) < 1e-5, "the near plane should sit at the top of the slice")
        for distance in [Float(0.2), 0.5, 1, 10, 1000] {
            let d = depth(m, at: distance)
            #expect(d >= 0.9 && d <= 1.0, "\(distance) m mapped to \(d), outside the slice")
        }
    }

    /// **The property the whole thing exists for**: nothing the world can draw beats the viewmodel.
    @Test("A viewmodel slice sits in front of anything the world can draw")
    func viewmodelWinsTheDepthTest() {
        let world = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6, nearZ: near)
        let weapon = simd_float4x4(perspectiveFovY: Float.radians(fromDegrees: 55),
                                                             aspectRatio: 1.6, nearZ: near,
                                                             depthRange: 0.9...1)
        // The closest a player can physically get to world geometry here is about 0.45 m.
        for distance in [Float(0.45), 1, 5, 100, 900] {
            #expect(depth(world, at: distance) < 0.9,
                    "world geometry at \(distance) m reaches the viewmodel's slice")
        }
        // And the weapon's own far end still beats it.
        #expect(depth(weapon, at: 2) > depth(world, at: 0.45))
    }

    /// Self-occlusion has to survive the squeeze, or a bolt draws through the receiver in front of it.
    @Test("Within the slice, nearer is still nearer")
    func selfOcclusionSurvives() {
        let m = simd_float4x4(perspectiveFovY: fov, aspectRatio: 1.6,
                                                        nearZ: near, depthRange: 0.9...1)
        #expect(depth(m, at: 0.3) > depth(m, at: 0.35))
        #expect(depth(m, at: 0.35) > depth(m, at: 0.9))
    }

    /// A narrower field of view makes things bigger on screen, which is the point of using one.
    @Test("A narrower field of view magnifies")
    func narrowerFovMagnifies() {
        let wide = simd_float4x4(perspectiveFovY: Float.radians(fromDegrees: 65),
                                                           aspectRatio: 1.6, nearZ: near)
        let narrow = simd_float4x4(perspectiveFovY: Float.radians(fromDegrees: 55),
                                                             aspectRatio: 1.6, nearZ: near)
        let point = SIMD4<Float>(0, 0.2, -1, 1)
        #expect(abs((narrow * point).y / (narrow * point).w) > abs((wide * point).y / (wide * point).w))
    }
}
