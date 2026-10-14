//
//  NormalMatrixTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Guards the transform that keeps normals perpendicular to their surface.
///
/// Every transform in the placeholder scene is a translation, where the naive approach and the
/// correct one agree — so this is the kind of thing that looks like ceremony, gets "simplified"
/// later, and breaks shading the first time something is scaled unevenly. These tests exist to make
/// that failure loud instead.
struct NormalMatrixTests {

    private func rotated(_ v: SIMD3<Float>, by m: matrix_float3x3) -> SIMD3<Float> {
        simd_normalize(m * v)
    }

    @Test("Identity in, identity out")
    func identityIsUnchanged() {
        let result = normalMatrix(from: matrix_identity_float4x4)
        for column in 0..<3 {
            #expect(simd_length(result[column] - matrix_identity_float3x3[column]) < 1e-6)
        }
    }

    @Test("Translation does not affect normals")
    func translationIsIgnored() {
        let result = normalMatrix(from: simd_float4x4(translation: SIMD3(5, -3, 12)))
        let normal = SIMD3<Float>(0, 1, 0)
        #expect(simd_length(rotated(normal, by: result) - normal) < 1e-6)
    }

    /// For a rotation the inverse transpose is the rotation itself, so normals simply rotate.
    @Test("Rotation carries normals with it")
    func rotationRotatesNormals() {
        let rotation = simd_float4x4(rotationAngle: .pi / 2, axis: SIMD3(0, 0, 1))
        let result = normalMatrix(from: rotation)
        // Rotating +Y by 90° about +Z gives -X.
        let transformed = rotated(SIMD3(0, 1, 0), by: result)
        #expect(simd_length(transformed - SIMD3<Float>(-1, 0, 0)) < 1e-5)
    }

    /// The case the whole thing exists for. Under non-uniform scale the naive matrix shears a
    /// normal off its surface; the inverse transpose keeps it perpendicular.
    @Test("Non-uniform scale keeps normals perpendicular to the surface")
    func nonUniformScaleKeepsNormalsPerpendicular() {
        var scale = matrix_identity_float4x4
        scale.columns.0.x = 2.0
        scale.columns.1.y = 0.5

        // A surface direction and its normal, both at 45° so the scale actually bites.
        let tangent = simd_normalize(SIMD3<Float>(1, -1, 0))
        let normal = simd_normalize(SIMD3<Float>(1, 1, 0))

        let scaledTangent = simd_normalize((scale * SIMD4<Float>(tangent, 0)).xyz)
        let correctNormal = rotated(normal, by: normalMatrix(from: scale))

        #expect(abs(simd_dot(scaledTangent, correctNormal)) < 1e-5,
                "The normal must stay perpendicular to the transformed surface")

        // And demonstrate that the naive approach genuinely fails here, so this test is not
        // quietly passing for both.
        let naive = matrix_float3x3(columns: (
            SIMD3(scale.columns.0.x, scale.columns.0.y, scale.columns.0.z),
            SIMD3(scale.columns.1.x, scale.columns.1.y, scale.columns.1.z),
            SIMD3(scale.columns.2.x, scale.columns.2.y, scale.columns.2.z)))
        let naiveNormal = rotated(normal, by: naive)
        #expect(abs(simd_dot(scaledTangent, naiveNormal)) > 0.1,
                "If this passes, the test is not exercising the difference")
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
