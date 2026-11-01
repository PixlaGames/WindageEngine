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

    /// One clip, then three: the mix is the weighted average, and weights are relative.
    @Test("A mix of clips lands where their weights put it")
    func mixIsWeighted() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        let clip = try AnimationClipTests.swing(jointPaths: ["root/mid"])
        let still = AnimationPlayhead(clip: clip, skeleton: skeleton)
        var swung = AnimationPlayhead(clip: clip, skeleton: skeleton)
        swung.advance(by: 1)

        // Alone, it is the clip.
        pose.set(mixing: [(swung, 1)])
        #expect(abs(pose.localTransforms[1].rotation.angle - .pi / 2) < 1e-4)
        // Half and half agrees with the two-clip cross-fade.
        pose.set(mixing: [(still, 2), (swung, 2)])
        #expect(abs(pose.localTransforms[1].rotation.angle - .pi / 4) < 1e-3)
        // Three layers, two of them the same pose: three quarters of the way, the summed and normalised quaternion's
        // angle — which is not exactly 3/4 of the arc, and is within a degree of it.
        pose.set(mixing: [(still, 1), (swung, 1.5), (swung, 1.5)])
        #expect(abs(pose.localTransforms[1].rotation.angle - 3 * .pi / 8) < 0.02)
        // The joint no clip drives stays at rest.
        #expect(simd_distance(pose.modelTransform(ofJoint: 0).columns.3, SIMD4(5, 0, 0, 1)) < 1e-5)
        // Nothing weighted: at rest.
        pose.set(mixing: [(swung, 0)])
        #expect(pose.localTransforms[1].rotation.angle < 1e-4)
    }

    /// **`q` and `−q` are the same rotation**, and added unaligned they cancel to nothing — the limbs-collapsing
    /// fault. A mix of a pose and the same pose with its quaternion's sign flipped must be that pose.
    @Test("A mix aligns signs, and a sum that cancels takes the heaviest layer")
    func mixAlignsHemispheres() throws {
        let skeleton = try SkeletonTests.offsetRig()
        var pose = SkeletonPose(skeleton: skeleton)
        func held(_ q: simd_quatf) throws -> AnimationClip {
            try AnimationClip(name: "held", jointPaths: ["root/mid"], translation: .empty(jointCount: 1),
                              rotation: JointTrack(times: [0, 1], values: [q, q], jointCount: 1),
                              scale: .empty(jointCount: 1))
        }
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let plus = AnimationPlayhead(clip: try held(quarter), skeleton: skeleton)
        let minus = AnimationPlayhead(clip: try held(simd_quatf(vector: -quarter.vector)), skeleton: skeleton)
        pose.set(mixing: [(plus, 1), (minus, 1)])
        #expect(abs(pose.localTransforms[1].rotation.angle - .pi / 2) < 1e-4
                || abs(pose.localTransforms[1].rotation.angle - 3 * .pi / 2) < 1e-4)
        #expect(pose.skinningMatrices.allSatisfy { m in (0..<4).allSatisfy { m[$0].x.isFinite } })

        // **A sum that still cancels**: two half turns about X, opposite in sign and both square to a barely weighted
        // identity, so the alignment to it flips neither. Their sum is nothing; the heaviest layer is taken, not NaN.
        let identity = AnimationPlayhead(clip: try held(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), skeleton: skeleton)
        let over = AnimationPlayhead(clip: try held(simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)), skeleton: skeleton)
        let under = AnimationPlayhead(clip: try held(simd_quatf(ix: -1, iy: 0, iz: 0, r: 0)), skeleton: skeleton)
        pose.set(mixing: [(identity, 0.00001), (over, 1), (under, 0.99)])
        #expect(pose.skinningMatrices.allSatisfy { m in (0..<4).allSatisfy { m[$0].x.isFinite && m[$0].y.isFinite } })
        #expect(abs(abs(pose.localTransforms[1].rotation.vector.x) - 1) < 1e-4)
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

@Suite("Clips laid over part of a rig")
@MainActor
struct SkeletonOverlayTests {

    /// Hips, a spine with an arm under it, and a leg: `root`, `root/spine`, `root/spine/arm`, `root/leg`.
    private func rig() throws -> Skeleton {
        try Skeleton(jointPaths: ["root", "root/spine", "root/spine/arm", "root/leg"],
                     restTransforms: Array(repeating: matrix_identity_float4x4, count: 4),
                     bindTransforms: Array(repeating: matrix_identity_float4x4, count: 4))
    }

    /// Every joint the clip names held turned `angle` about Z.
    private func held(_ angle: Float, joints: [String]) throws -> AnimationClip {
        let q = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
        return try AnimationClip(name: "held \(angle)", jointPaths: joints, translation: .empty(jointCount: joints.count),
                                 rotation: JointTrack(times: [0, 1], values: Array(repeating: q, count: joints.count * 2),
                                                      jointCount: joints.count),
                                 scale: .empty(jointCount: joints.count))
    }

    @Test("A joint's mask takes it and everything under it, nothing else")
    func masks() throws {
        let skeleton = try rig()
        #expect(skeleton.mask(from: 1) == [0, 1, 1, 0])
        #expect(skeleton.mask(from: 1, weight: 0.5) == [0, 0.5, 0.5, 0])
        #expect(skeleton.mask(from: 3) == [0, 0, 0, 1])
        #expect(skeleton.mask(from: 9) == [0, 0, 0, 0])
    }

    @Test("Laid over the spine, a clip moves the spine and arm, and the legs keep their own clip")
    func overlay() throws {
        let skeleton = try rig()
        let all = ["root", "root/spine", "root/spine/arm", "root/leg"]
        let walk = AnimationPlayhead(clip: try held(0.4, joints: all), skeleton: skeleton)
        let aim = AnimationPlayhead(clip: try held(1.2, joints: all), skeleton: skeleton)
        var pose = SkeletonPose(skeleton: skeleton)
        pose.set(mixing: [(walk, 1)])
        pose.overlay([(aim, 1)], mask: skeleton.mask(from: 1))
        let angles = pose.localTransforms.map(\.rotation.angle)
        #expect(abs(angles[0] - 0.4) < 1e-4 && abs(angles[3] - 0.4) < 1e-4, "the hips and leg keep the walk: \(angles)")
        #expect(abs(angles[1] - 1.2) < 1e-4 && abs(angles[2] - 1.2) < 1e-4, "the spine and arm take the aim: \(angles)")
        // Joint-local: the arm rides the hips' turn too.
        let arm = pose.modelTransform(ofJoint: 2)
        #expect(abs(atan2(arm.columns.0.y, arm.columns.0.x) - (0.4 + 1.2 + 1.2)) < 1e-3)

        pose.set(mixing: [(walk, 1)])
        pose.overlay([(aim, 1)], mask: skeleton.mask(from: 1, weight: 0.5))
        #expect(abs(pose.localTransforms[1].rotation.angle - 0.8) < 1e-3, "half a mask lands half way")
        pose.overlay([(aim, 0)], mask: skeleton.mask(from: 1))
        #expect(abs(pose.localTransforms[1].rotation.angle - 0.8) < 1e-3, "no weight changes nothing")
    }

    /// **An aim held in model space**: a walk whose hips turn with the stride — a strafe's do — under an upper body that
    /// must point where the aim clip points, not where the hips do.
    @Test("Held in model space, the anchor turns as the clip turned it, whatever the hips do")
    func modelSpaceAnchor() throws {
        let skeleton = try rig()
        let all = ["root", "root/spine", "root/spine/arm", "root/leg"]
        let strafe = AnimationPlayhead(clip: try held(0.35, joints: all), skeleton: skeleton)   // hips turned 0.35
        let aim = AnimationPlayhead(clip: try held(0.1, joints: all), skeleton: skeleton)       // its own hips at 0.1
        var pose = SkeletonPose(skeleton: skeleton)
        pose.set(mixing: [(strafe, 1)])
        pose.overlay([(aim, 1)], mask: skeleton.mask(from: 1), modelRotationAt: 1)
        func yaw(_ joint: Int) -> Float { let m = pose.modelTransform(ofJoint: joint); return atan2(m.columns.0.y, m.columns.0.x) }
        #expect(abs(yaw(0) - 0.35) < 1e-4, "the hips keep the strafe")
        #expect(abs(yaw(1) - 0.2) < 1e-4, "the spine where the aim put it — its hips 0.1 and itself 0.1 — not 0.45: \(yaw(1))")
        #expect(abs(yaw(2) - 0.3) < 1e-4, "and the arm rides the spine")
        #expect(abs(yaw(3) - 0.7) < 1e-4, "the leg keeps the strafe's own")
        // Without the anchor, the spine rides the hips: 0.35 + 0.1.
        pose.set(mixing: [(strafe, 1)])
        pose.overlay([(aim, 1)], mask: skeleton.mask(from: 1))
        #expect(abs(yaw(1) - 0.45) < 1e-4)
        // Half a mask: half way between the gait's spine and the aim's, in the spine's own space.
        pose.set(mixing: [(strafe, 1)])
        pose.overlay([(aim, 1)], mask: skeleton.mask(from: 1, weight: 0.5), modelRotationAt: 1)
        #expect(abs(yaw(1) - (0.35 + (0.35 + (-0.15 - 0.35) * 0.5))) < 1e-3, "\(yaw(1))")
    }
}

