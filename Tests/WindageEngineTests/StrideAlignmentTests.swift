//
//  StrideAlignmentTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

struct StrideAlignmentTests {

    /// A hip and a foot, the foot a metre below it at rest.
    private func legRig() throws -> Skeleton {
        try Skeleton(jointPaths: ["hips", "hips/foot_l"],
                     restTransforms: [matrix_identity_float4x4,
                                      simd_float4x4(translation: SIMD3(0, -1, 0))],
                     bindTransforms: [matrix_identity_float4x4,
                                      simd_float4x4(translation: SIMD3(0, -1, 0))])
    }

    /// A stride: the foot traces a lopsided loop — forward along the ground, up and back — over `duration`, starting
    /// `lag` of the way through the loop, so two strides that differ only in `lag` are one motion begun at two moments.
    private func gait(_ name: String, duration: Float, lag: Float, size: Float = 0.4) throws -> AnimationClip {
        let keys = 48
        var times: [Float] = [], translations: [SIMD3<Float>] = [], rotations: [simd_quatf] = []
        for key in 0...keys {
            let t = Float(key) / Float(keys)
            let theta = 2 * Float.pi * (t - lag)
            times.append(t * duration)
            translations += [.zero, SIMD3(0, -1 + size * 0.5 * max(0, sin(theta)), size * cos(theta) + size * 0.3 * sin(2 * theta))]
            rotations += [simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)]
        }
        return try AnimationClip(name: name, jointPaths: ["hips", "hips/foot_l"],
                                 translation: JointTrack(times: times, values: translations, jointCount: 2),
                                 rotation: JointTrack(times: times, values: rotations, jointCount: 2),
                                 scale: .empty(jointCount: 2))
    }

    private func idle() throws -> AnimationClip {
        try AnimationClip(name: "Idle", jointPaths: ["hips"],
                          translation: JointTrack(times: [0, 2], values: [.zero, SIMD3(0, 0.01, 0)], jointCount: 1),
                          rotation: .empty(jointCount: 1), scale: .empty(jointCount: 1))
    }

    /// The run starts a quarter of a stride later than the walk: sampled a quarter further on, it is at the walk's
    /// moment. Anchored on the run, the longer stride, so the walk takes the other three quarters.
    @Test("A gait begun a quarter stride late is sampled a quarter stride on")
    func quarterStride() throws {
        let rig = try legRig()
        let walk = try gait("Walk", duration: 1.2, lag: 0, size: 0.3)
        let run = try gait("Run", duration: 0.7, lag: 0.25, size: 0.6)
        let aligned = StrideAlignment.align([walk, run, try idle()], on: rig, footJoint: "foot_l")

        #expect(aligned["Run"] == StrideAlignment(phaseOffset: 0, match: 0, isAligned: true))
        let walkAlignment = try #require(aligned["Walk"])
        #expect(walkAlignment.isAligned)
        #expect(walkAlignment.match < 0.05)
        #expect(abs(walkAlignment.phaseOffset - 0.75) < 1.0 / 64 + 1e-4)
        // **An idle has no stride to line up**, and is left on its own clock.
        #expect(aligned["Idle"] == nil)

        // And the check that matters: at every shared phase, the two feet are at the same point of the loop — the
        // same fraction of their own stride's length forward, to within the 1/64 the paths are compared at.
        var pose = SkeletonPose(skeleton: rig)
        func forward(_ clip: AnimationClip, at phase: Float, size: Float) -> Float {
            var playhead = AnimationPlayhead(clip: clip, skeleton: rig)
            playhead.time = phase.truncatingRemainder(dividingBy: 1) * clip.duration
            pose.set(to: playhead)
            return pose.modelTransform(ofJoint: 1).columns.3.z / size
        }
        for phase in stride(from: Float(0), to: 1, by: 0.125) {
            let running = forward(run, at: phase, size: 0.6)
            let walking = forward(walk, at: phase + walkAlignment.phaseOffset, size: 0.3)
            #expect(abs(running - walking) < 0.15, "at phase \(phase): \(running) and \(walking)")
        }
    }

    /// **A poor match is left unaligned rather than aligned badly**: a foot going round the other way is not the same
    /// motion begun later, and no shift makes it one.
    @Test("A motion that is not the same stride is left alone, and says how far off it was")
    func unrelatedMotion() throws {
        let rig = try legRig()
        let forward = try gait("Walk", duration: 1, lag: 0, size: 0.5)
        var times: [Float] = [], translations: [SIMD3<Float>] = [], rotations: [simd_quatf] = []
        for key in 0...32 {
            let t = Float(key) / 32
            times.append(t)
            // Straight up and down, never forward: a hop, not a stride.
            translations += [.zero, SIMD3(0, -1 + 0.2 * sin(2 * .pi * t), 0)]
            rotations += [simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)]
        }
        let hop = try AnimationClip(name: "Hop", jointPaths: ["hips", "hips/foot_l"],
                                    translation: JointTrack(times: times, values: translations, jointCount: 2),
                                    rotation: JointTrack(times: times, values: rotations, jointCount: 2),
                                    scale: .empty(jointCount: 2))
        let aligned = StrideAlignment.align([forward, hop], on: rig, footJoint: "foot_l")
        let hopping = try #require(aligned["Hop"])
        #expect(!hopping.isAligned)
        #expect(hopping.phaseOffset == 0)
        #expect(hopping.match >= 0.8)
    }

    @Test("A foot the rig does not have aligns nothing")
    func noFoot() throws {
        #expect(StrideAlignment.align([try gait("Walk", duration: 1, lag: 0)], on: try legRig(),
                                      footJoint: "foot_r").isEmpty)
    }
}
