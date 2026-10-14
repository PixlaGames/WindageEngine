//
//  SkeletonPoseTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct SkeletonPoseTests {

    /// Linear blend skinning, done here exactly as the vertex shader does it, so this test measures
    /// the matrices rather than restating them.
    private func skin(_ position: SIMD3<Float>,
                      _ pose: SkeletonPose,
                      _ influences: [(joint: Int, weight: Float)]) -> SIMD3<Float> {
        var result = SIMD4<Float>.zero
        for influence in influences {
            result += pose.skinningMatrices[influence.joint]
                    * SIMD4(position, 1) * influence.weight
        }
        return SIMD3(result.x, result.y, result.z)
    }

    /// **The test that fails if the two transform spaces get confused.** With the rig at rest, every
    /// skinning matrix must be the identity — the mesh is already in its bind pose, so skinning must
    /// not move it. Feed the joint-local rest transforms in as bind transforms instead and the child
    /// lands 5 m from where it was modelled, which is what that mistake looks like on screen.
    @Test("At rest, skinning moves nothing")
    func restPoseIsIdentity() throws {
        let pose = SkeletonPose(skeleton: try SkeletonTests.offsetRig())
        for matrix in pose.skinningMatrices {
            #expect(simd_almost_equal_elements(matrix, matrix_identity_float4x4, 1e-5))
        }
        let tip = SIMD3<Float>(5, 2, 0)
        #expect(simd_distance(skin(tip, pose, [(1, 1)]), tip) < 1e-5)
    }

    @Test("Model-space transforms accumulate down the chain")
    func modelTransformsAccumulate() throws {
        let pose = SkeletonPose(skeleton: try SkeletonTests.offsetRig())
        #expect(simd_distance(pose.modelTransform(ofJoint: 0).columns.3, SIMD4(5, 0, 0, 1)) < 1e-5)
        #expect(simd_distance(pose.modelTransform(ofJoint: 1).columns.3, SIMD4(5, 1, 0, 1)) < 1e-5)
    }

    /// Worked by hand: the joint sits at (5, 1, 0), so a vertex at (5, 2, 0) — one metre above it —
    /// swings a quarter turn about Z to (4, 1, 0).
    @Test("A posed joint carries the vertices bound to it")
    func skinningFollowsTheJoint() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        var locals = pose.localTransforms
        locals[1].rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        pose.set(to: locals)

        let skinned = skin(SIMD3(5, 2, 0), pose, [(1, 1)])
        #expect(simd_distance(skinned, SIMD3(4, 1, 0)) < 1e-4)
    }

    /// The whole point of a hierarchy: moving a parent moves everything under it, and the child's
    /// own transform is unchanged.
    @Test("Rotating a parent carries the child")
    func parentCarriesChild() throws {
        let skeleton = try Skeleton(
            jointPaths: ["root", "root/mid"],
            restTransforms: [matrix_identity_float4x4, simd_float4x4(translation: SIMD3(0, 1, 0))],
            bindTransforms: [matrix_identity_float4x4, simd_float4x4(translation: SIMD3(0, 1, 0))])
        var pose = SkeletonPose(skeleton: skeleton)
        var locals = pose.localTransforms
        locals[0].rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        pose.set(to: locals)

        // The child was one metre up; a quarter turn about Z puts it one metre along -X.
        #expect(simd_distance(pose.modelTransform(ofJoint: 1).columns.3, SIMD4(-1, 0, 0, 1)) < 1e-4)
    }

    /// A vertex split between two joints lands between the two places they would each have put it.
    @Test("Weights blend a vertex between joints")
    func weightsBlend() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        var locals = pose.localTransforms
        locals[1].rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        pose.set(to: locals)

        let tip = SIMD3<Float>(5, 2, 0)
        let held = skin(tip, pose, [(0, 1)])              // root did not move
        let swung = skin(tip, pose, [(1, 1)])
        let half = skin(tip, pose, [(0, 0.5), (1, 0.5)])
        #expect(simd_distance(half, (held + swung) / 2) < 1e-4)
    }

    @Test("A clip poses the rig it names")
    func clipPosesTheRig() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        let clip = try AnimationClipTests.swing(jointPaths: ["root/mid"])
        var playhead = AnimationPlayhead(clip: clip, skeleton: skeleton)
        playhead.advance(by: 1)                            // the quarter-turn key
        pose.set(to: playhead)

        #expect(simd_distance(skin(SIMD3(5, 2, 0), pose, [(1, 1)]), SIMD3(4, 1, 0)) < 1e-4)
        // The joint the clip says nothing about stayed at rest rather than collapsing to the origin.
        #expect(simd_distance(pose.modelTransform(ofJoint: 0).columns.3, SIMD4(5, 0, 0, 1)) < 1e-5)
    }

    @Test("A cross-fade lands between the two clips")
    func crossFadeIsBetween() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        let clip = try AnimationClipTests.swing(jointPaths: ["root/mid"])

        let still = AnimationPlayhead(clip: clip, skeleton: skeleton)      // t = 0, no rotation
        var swung = AnimationPlayhead(clip: clip, skeleton: skeleton)
        swung.advance(by: 1)                                               // t = 1, quarter turn

        pose.set(to: still, blendedWith: swung, weight: 0.5)
        #expect(abs(pose.localTransforms[1].rotation.angle - .pi / 4) < 1e-4)

        pose.set(to: still, blendedWith: swung, weight: 0)
        #expect(pose.localTransforms[1].rotation.angle < 1e-4)
        pose.set(to: still, blendedWith: swung, weight: 1)
        #expect(abs(pose.localTransforms[1].rotation.angle - .pi / 2) < 1e-4)
        _ = still
    }

    @Test("A one-shot finishes and a loop does not")
    func playheadReportsFinishing() throws {
        let skeleton = try SkeletonTests.offsetRig()
        let clip = try AnimationClipTests.swing()
        var once = AnimationPlayhead(clip: clip, skeleton: skeleton, looping: false)
        var forever = AnimationPlayhead(clip: clip, skeleton: skeleton, looping: true)
        once.advance(by: 5)
        forever.advance(by: 5)
        #expect(once.isFinished)
        #expect(once.sampleTime == clip.duration)
        #expect(!forever.isFinished)
        #expect(abs(forever.sampleTime - 1) < 1e-5)
    }
}

/// **A playhead made for another rig stops at once, saying so.** It used to read its joint mapping
/// past the end on whatever frame first posed with it.
///
/// Built inline: an exit test's body runs in a child process, off the main actor the test helpers
/// are on.
@Test func aPlayheadForAnotherRigIsRefused() async {
    await #expect(processExitsWith: .failure) {
        let rig = try Skeleton(jointPaths: ["root", "root/mid"],
                               restTransforms: [matrix_identity_float4x4, matrix_identity_float4x4],
                               bindTransforms: [matrix_identity_float4x4, matrix_identity_float4x4])
        let other = try Skeleton(jointPaths: ["hips"], restTransforms: [matrix_identity_float4x4],
                                 bindTransforms: [matrix_identity_float4x4])
        let clip = try AnimationClip(name: "still", jointPaths: ["hips"], translation: .empty(jointCount: 1),
                                     rotation: .empty(jointCount: 1), scale: .empty(jointCount: 1))
        var pose = SkeletonPose(skeleton: rig)
        pose.set(to: AnimationPlayhead(clip: clip, skeleton: other))
    }
    await #expect(processExitsWith: .failure) {
        let rig = try Skeleton(jointPaths: ["root", "root/mid"],
                               restTransforms: [matrix_identity_float4x4, matrix_identity_float4x4],
                               bindTransforms: [matrix_identity_float4x4, matrix_identity_float4x4])
        let other = try Skeleton(jointPaths: ["hips"], restTransforms: [matrix_identity_float4x4],
                                 bindTransforms: [matrix_identity_float4x4])
        let clip = try AnimationClip(name: "still", jointPaths: ["root"], translation: .empty(jointCount: 1),
                                     rotation: .empty(jointCount: 1), scale: .empty(jointCount: 1))
        var pose = SkeletonPose(skeleton: rig)
        pose.set(to: AnimationPlayhead(clip: clip, skeleton: rig),
                 blendedWith: AnimationPlayhead(clip: clip, skeleton: other), weight: 0.5)
    }
}

/// The check is on the joints, not the instance: a skeleton loaded twice poses the same.
@MainActor
@Test func aPlayheadForAnIdenticalRigPoses() throws {
    let skeleton = try SkeletonTests.offsetRig()
    let twin = try SkeletonTests.offsetRig()
    var pose = SkeletonPose(skeleton: skeleton)
    pose.set(to: AnimationPlayhead(clip: try AnimationClipTests.swing(jointPaths: ["root/mid"]), skeleton: twin))
    #expect(pose.jointCount == 2)
}
