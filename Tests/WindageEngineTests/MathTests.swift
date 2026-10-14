//
//  MathTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// The transform helpers, under their Swift names. The projection has its own suites
/// (`ReversedZProjectionTests`, `DepthRangeProjectionTests`); these pin the rest.
struct MathTests {

    @Test("A translation moves a point and leaves a direction alone")
    func translation() {
        let m = simd_float4x4(translation: SIMD3(1, -2, 3))
        #expect(m * SIMD4<Float>(0, 0, 0, 1) == SIMD4(1, -2, 3, 1))
        #expect(m * SIMD4<Float>(1, 0, 0, 0) == SIMD4(1, 0, 0, 0))
    }

    /// Right-handed, the same convention as `simd_quatf(angle:axis:)` — a game mixing the two must not
    /// find them turning opposite ways.
    @Test("A rotation agrees with simd's own quaternion")
    func rotationMatchesQuaternion() {
        for (angle, axis) in [(Float.pi / 3, SIMD3<Float>(0, 1, 0)), (-0.7, SIMD3(1, 2, -3))] {
            let matrix = simd_float4x4(rotationAngle: angle, axis: axis)
            let quaternion = simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
            #expect(simd_almost_equal_elements(matrix, quaternion, 1e-5))
        }
    }

    @Test("Degrees and radians convert both ways")
    func angles() {
        #expect(abs(Float.radians(fromDegrees: 180) - .pi) < 1e-6)
        #expect(abs(Float.degrees(fromRadians: .pi / 2) - 90) < 1e-4)
        #expect(abs(Float.degrees(fromRadians: Float.radians(fromDegrees: 37.5)) - 37.5) < 1e-4)
    }

    /// The default range is the whole buffer, and the matrix it gives is the one the engine has always
    /// drawn with — `+0`, not `-0`, where the depth slice's lower bound goes.
    @Test("The whole-buffer projection is the plain one, to the bit")
    func wholeBufferProjection() {
        let m = simd_float4x4(perspectiveFovY: 1.1, aspectRatio: 1.6, nearZ: 0.1)
        #expect(m.columns.2.z.sign == .plus)
        #expect(m == simd_float4x4(perspectiveFovY: 1.1, aspectRatio: 1.6, nearZ: 0.1, depthRange: 0...1))
    }
}

@Suite("Angles")
struct AngleTests {
    @Test("An angle wraps to (-π, π], and the shortest turn crosses the seam")
    func wrapping() {
        #expect(Float.wrappedAngle(.pi) == .pi)
        #expect(abs(Float.wrappedAngle(-.pi) - .pi) < 1e-6)
        #expect(abs(Float.wrappedAngle(3 * .pi / 2) + .pi / 2) < 1e-6)
        #expect(abs(Float.wrappedAngle(0.25 + 20 * .pi) - 0.25) < 1e-4)
        let degree = Float.radians(fromDegrees: 1)
        #expect(abs(Float.shortestAngle(from: .pi - degree, to: -.pi + degree) - 2 * degree) < 1e-5)
    }
}
