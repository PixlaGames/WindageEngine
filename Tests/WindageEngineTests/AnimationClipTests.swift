//
//  AnimationClipTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct JointTransformTests {

    @Test("A transform survives the round trip through a matrix")
    func matrixRoundTrip() {
        let original = JointTransform(translation: SIMD3(3, -1, 2),
                                      rotation: simd_quatf(angle: 0.7, axis: normalize(SIMD3<Float>(1, 2, 3))),
                                      scale: SIMD3(2, 0.5, 1.5))
        let recovered = JointTransform(matrix: original.matrix)
        #expect(simd_distance(recovered.translation, original.translation) < 1e-5)
        #expect(simd_distance(recovered.scale, original.scale) < 1e-5)
        // A quaternion and its negation are the same rotation, so compare what they do.
        let point = SIMD3<Float>(1, 2, 3)
        #expect(simd_distance(recovered.rotation.act(point), original.rotation.act(point)) < 1e-4)
    }

    /// A mirrored rig has a negative determinant. Normalising its columns without noticing turns the
    /// flip into a rotation — a left hand where a right one belongs, on a character that otherwise
    /// looks fine.
    @Test("A mirrored transform keeps its flip")
    func mirrorIsNotSwallowed() {
        var mirrored = matrix_identity_float4x4
        mirrored.columns.0 = SIMD4(-1, 0, 0, 0)
        let recovered = JointTransform(matrix: mirrored)
        #expect(recovered.scale.x < 0)
        let rebuilt = recovered.matrix
        #expect(abs(rebuilt.columns.0.x - -1) < 1e-5)
        #expect(simd_determinant(rebuilt) < 0)
    }

    @Test("Blending takes the shortest arc")
    func blendTakesShortestArc() {
        // 350° apart the short way is 10°; the long way is 350° and swings a head right round.
        let a = simd_quatf(angle: Float.radians(fromDegrees: -5), axis: SIMD3(0, 1, 0))
        let b = simd_quatf(angle: Float.radians(fromDegrees: 5), axis: SIMD3(0, 1, 0))
        let mid = JointTransform(rotation: a).blended(toward: JointTransform(rotation: b), weight: 0.5)
        let forward = mid.rotation.act(SIMD3<Float>(0, 0, -1))
        #expect(abs(forward.x) < 1e-4, "the blend swung the long way round")
        #expect(forward.z < 0)
    }

    @Test("Blending moves translation and scale linearly")
    func blendIsLinearElsewhere() {
        let a = JointTransform(translation: SIMD3(0, 0, 0), scale: SIMD3(repeating: 1))
        let b = JointTransform(translation: SIMD3(4, 0, 0), scale: SIMD3(repeating: 3))
        let quarter = a.blended(toward: b, weight: 0.25)
        #expect(abs(quarter.translation.x - 1) < 1e-5)
        #expect(abs(quarter.scale.x - 1.5) < 1e-5)
    }
}

@MainActor
struct JointTrackTests {

    private let track = try! JointTrack(times: [0, 1, 2, 3],
                                        values: [0, 10, 20, 30].flatMap { [Float($0), Float($0) + 100] },
                                        jointCount: 2)

    @Test("A time between keys reports both and the fraction")
    func spanBetweenKeys() {
        let span = track.span(at: 1.25)
        #expect(span.lower == 1)
        #expect(span.upper == 2)
        #expect(abs(span.fraction - 0.25) < 1e-6)
    }

    @Test("Before the first key and after the last, the span is a single key")
    func spanClampsAtTheEnds() {
        let before = track.span(at: -5)
        #expect(before.lower == 0 && before.upper == 0 && before.fraction == 0)
        let after = track.span(at: 99)
        #expect(after.lower == 3 && after.upper == 3 && after.fraction == 0)
    }

    /// The binary search has to land on the right segment for every key, not just the ones a
    /// hand-written case happens to try.
    @Test("The search finds the right segment at any time in a long track")
    func searchIsCorrectThroughout() throws {
        let times = (0..<500).map { Float($0) * 0.033 }
        let long = try JointTrack(times: times, values: times, jointCount: 1)
        for step in 0..<2000 {
            let t = Float(step) * 0.008
            let span = long.span(at: t)
            guard span.lower != span.upper else { continue }
            #expect(times[span.lower] <= t && t < times[span.upper])
        }
    }

    /// **A channel with one key is a channel that does not change**, and that is how a clip whose
    /// joints never translate is authored — one key rather than a copy of the rest pose at every
    /// frame. The sample's own figure is written that way, so its three channels have entirely
    /// different key times; a track that assumed one shared timeline would be wrong on it.
    @Test("A single-key track samples to that key at any time")
    func singleKeyTrackIsConstant() throws {
        let constant = try JointTrack(times: [0], values: [Float(7)], jointCount: 1)
        for time in [Float(-10), 0, 0.5, 1000] {
            let span = constant.span(at: time)
            #expect(constant[span.lower, 0] == 7)
            #expect(span.fraction == 0)
        }
    }

    @Test("Time-major layout puts a moment's joints together")
    func layoutIsTimeMajor() {
        #expect(track[2, 0] == 20)
        #expect(track[2, 1] == 120)
    }

    /// **Malformed data is refused where it is made**, not found as an index out of range in the
    /// middle of posing a character on some later frame.
    @Test("A track of the wrong shape is refused when it is made")
    func malformedTracksAreRefused() {
        #expect(throws: AnimationClipError.valueCountMismatch(keys: 2, joints: 2, values: 3)) {
            try JointTrack(times: [0, 1], values: [Float(0), 1, 2], jointCount: 2)
        }
        #expect(throws: AnimationClipError.negativeJointCount(-1)) {
            try JointTrack<Float>(times: [], values: [], jointCount: -1)
        }
        #expect(throws: AnimationClipError.timesOutOfOrder(key: 2)) {
            try JointTrack(times: [0, 1, 0.5], values: [Float(0), 1, 2], jointCount: 1)
        }
        #expect(throws: AnimationClipError.nonFiniteTime(key: 1)) {
            try JointTrack(times: [0, .nan], values: [Float(0), 1], jointCount: 1)
        }
        // Two keys at one time are a step, and are allowed.
        #expect((try? JointTrack(times: [0, 1, 1], values: [Float(0), 1, 2], jointCount: 1)) != nil)
    }
}

@MainActor
struct AnimationClipTests {

    /// One joint, rotating a quarter turn about Z over two seconds and back.
    static func swing(jointPaths: [String] = ["root"]) throws -> AnimationClip {
        let count = jointPaths.count
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        return try AnimationClip(
            name: "swing",
            jointPaths: jointPaths,
            translation: .empty(jointCount: count),
            rotation: try JointTrack(times: [0, 1, 2],
                                 values: Array(repeating: identity, count: count)
                                       + Array(repeating: quarter, count: count)
                                       + Array(repeating: identity, count: count),
                                 jointCount: count),
            scale: .empty(jointCount: count))
    }

    @Test("A clip whose channels are for a different number of joints is refused")
    func mismatchedChannelsAreRefused() throws {
        let twoJoints = try JointTrack(times: [0], values: [SIMD3<Float>.zero, .zero], jointCount: 2)
        #expect(throws: AnimationClipError.trackJointCountMismatch(channel: "translation", track: 2, clip: 1)) {
            try AnimationClip(name: "bad", jointPaths: ["root"], translation: twoJoints,
                              rotation: .empty(jointCount: 1), scale: .empty(jointCount: 1))
        }
        // A channel with no keys is never sampled, so its joint count does not matter.
        #expect((try? AnimationClip(name: "fine", jointPaths: ["root"], translation: .empty(jointCount: 0),
                                    rotation: .empty(jointCount: 1), scale: .empty(jointCount: 7))) != nil)
    }

    @Test("Duration is the latest key any channel reaches")
    func durationIsTheLatestKey() throws {
        #expect(try Self.swing().duration == 2)
    }

    /// A clip with rotation keys and nothing else is what a rigger normally authors. If the missing
    /// channels zeroed instead of falling back, every joint would collapse onto its parent.
    @Test("Channels the clip does not carry fall back to rest")
    func absentChannelsUseRest() throws {
        let rest = JointTransform(translation: SIMD3(0, 1.5, 0), scale: SIMD3(repeating: 2))
        let sampled = try Self.swing().sample(joint: 0, at: 0.5, rest: rest)
        #expect(sampled.translation == rest.translation)
        #expect(sampled.scale == rest.scale)
        #expect(sampled.rotation.angle > 0.1, "the channel the clip does carry was ignored")
    }

    @Test("A looping clip wraps and a one-shot clamps")
    func timeWrapsOrClamps() throws {
        let clip = try Self.swing()
        #expect(abs(clip.wrappedTime(2.5, looping: true) - 0.5) < 1e-5)
        #expect(abs(clip.wrappedTime(-0.5, looping: true) - 1.5) < 1e-5)
        #expect(clip.wrappedTime(2.5, looping: false) == 2)
        #expect(clip.wrappedTime(-0.5, looping: false) == 0)
    }

    @Test("Sampling interpolates between keys")
    func samplingInterpolates() throws {
        let halfway = try Self.swing().sample(joint: 0, at: 0.5, rest: .identity)
        #expect(abs(halfway.rotation.angle - .pi / 4) < 1e-4)
    }
}

@MainActor
struct AnimationBindingTests {

    @Test("Joints are matched by path, not by index")
    func matchedByPath() throws {
        let skeleton = try Skeleton(
            jointPaths: ["root", "root/spine", "root/leg"],
            restTransforms: Array(repeating: matrix_identity_float4x4, count: 3),
            bindTransforms: Array(repeating: matrix_identity_float4x4, count: 3))
        // The clip lists the same joints in a different order and omits one.
        let clip = try AnimationClipTests.swing(jointPaths: ["root/spine", "root"])
        let binding = AnimationBinding(clip: clip, skeleton: skeleton)
        #expect(binding.clipJointIndices == [1, 0, nil])
        #expect(binding.unboundJoints == ["root/leg"])
        #expect(!binding.isEmpty)
    }

    /// An empty binding is what "the character is a statue" looks like from the inside, and it is
    /// otherwise indistinguishable from a clip that holds still.
    @Test("A clip for a different rig binds to nothing")
    func unrelatedClipIsEmpty() throws {
        let skeleton = try Skeleton(jointPaths: ["hips"],
                                    restTransforms: [matrix_identity_float4x4],
                                    bindTransforms: [matrix_identity_float4x4])
        let binding = AnimationBinding(clip: try AnimationClipTests.swing(), skeleton: skeleton)
        #expect(binding.isEmpty)
        #expect(binding.unboundJoints == ["hips"])
    }
}
