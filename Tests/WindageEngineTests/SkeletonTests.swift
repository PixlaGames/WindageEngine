//
//  SkeletonTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct SkeletonTests {

    /// A root at (5, 0, 0) with a child a metre above it — the rig that separates the two transform
    /// spaces. In a rig rooted at the origin they coincide and every space mistake passes.
    static func offsetRig() throws -> Skeleton {
        try Skeleton(
            jointPaths: ["root", "root/mid"],
            restTransforms: [simd_float4x4(translation: SIMD3(5, 0, 0)),      // joint-local
                             simd_float4x4(translation: SIMD3(0, 1, 0))],
            bindTransforms: [simd_float4x4(translation: SIMD3(5, 0, 0)),      // skeleton-space
                             simd_float4x4(translation: SIMD3(5, 1, 0))])
    }

    @Test("Parentage comes out of the joint paths")
    func parentsFromPaths() throws {
        let skeleton = try Skeleton(
            jointPaths: ["root", "root/spine", "root/spine/arm", "root/leg"],
            restTransforms: Array(repeating: matrix_identity_float4x4, count: 4),
            bindTransforms: Array(repeating: matrix_identity_float4x4, count: 4))
        #expect(skeleton.parentIndices == [nil, 0, 1, 0])
        #expect(skeleton.index(ofJoint: "root/spine/arm") == 2)
        #expect(skeleton.index(ofJoint: "root/spine/hand") == nil)
    }

    /// More than one root is legal — USD does not forbid it, and an attachment rig often is one.
    @Test("A skeleton may have several roots")
    func severalRoots() throws {
        let skeleton = try Skeleton(
            jointPaths: ["a", "b", "b/c"],
            restTransforms: Array(repeating: matrix_identity_float4x4, count: 3),
            bindTransforms: Array(repeating: matrix_identity_float4x4, count: 3))
        #expect(skeleton.parentIndices == [nil, nil, 1])
    }

    @Test("A joint whose parent is missing is an error, not a silently reparented joint")
    func missingParentThrows() {
        #expect(throws: SkeletonError.self) {
            try Skeleton(jointPaths: ["root", "spine/arm"],
                         restTransforms: [matrix_identity_float4x4, matrix_identity_float4x4],
                         bindTransforms: [matrix_identity_float4x4, matrix_identity_float4x4])
        }
    }

    /// The check that lets ``SkeletonPose/refresh()`` be one forward pass. Without it a child listed
    /// before its parent reads a parent transform from the previous frame.
    @Test("Joints out of parent-first order are an error")
    func parentAfterChildThrows() {
        #expect(throws: SkeletonError.self) {
            try Skeleton(jointPaths: ["root/mid", "root"],
                         restTransforms: [matrix_identity_float4x4, matrix_identity_float4x4],
                         bindTransforms: [matrix_identity_float4x4, matrix_identity_float4x4])
        }
    }

    @Test("Mismatched transform counts are an error")
    func countMismatchThrows() {
        #expect(throws: SkeletonError.self) {
            try Skeleton(jointPaths: ["root", "root/mid"],
                         restTransforms: [matrix_identity_float4x4],
                         bindTransforms: [matrix_identity_float4x4, matrix_identity_float4x4])
        }
    }

    /// `simd_inverse` returns NaN for a singular matrix rather than failing, and a NaN skinning
    /// matrix makes the mesh vanish with nothing logged. Better to name the joint.
    @Test("A bind transform that cannot be inverted is caught by name")
    func singularBindThrows() {
        var flattened = matrix_identity_float4x4
        flattened.columns.1 = SIMD4(0, 0, 0, 0)
        #expect(throws: SkeletonError.self) {
            try Skeleton(jointPaths: ["root"], restTransforms: [matrix_identity_float4x4],
                         bindTransforms: [flattened])
        }
    }

    @Test("Bind transforms are stored inverted")
    func bindTransformsAreInverted() throws {
        let skeleton = try Self.offsetRig()
        let recovered = simd_inverse(skeleton.inverseBindTransforms[1])
        #expect(abs(recovered.columns.3.x - 5) < 1e-5)
        #expect(abs(recovered.columns.3.y - 1) < 1e-5)
    }
}
