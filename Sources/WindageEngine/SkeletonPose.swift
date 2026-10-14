//
//  SkeletonPose.swift
//  WindageEngine
//

import simd

/// Where a character is in a clip: the clip, its mapping onto a rig, and the time.
///
/// **The mapping is built once, here, and carried.** Working out which of a rig's joints a clip
/// drives is a name match; doing it per frame is the version of this that shows up in a profile.
public nonisolated struct AnimationPlayhead: Sendable {
    public let clip: AnimationClip
    public let binding: AnimationBinding
    public var isLooping: Bool

    /// Seconds since the clip started. Free to run past ``AnimationClip/duration`` — a looping clip
    /// wraps and a one-shot clamps, so nothing here has to keep it in range.
    public var time: Float

    public init(clip: AnimationClip, skeleton: Skeleton, looping: Bool = true, time: Float = 0) {
        self.clip = clip
        self.binding = AnimationBinding(clip: clip, skeleton: skeleton)
        self.isLooping = looping
        self.time = time
    }

    public mutating func advance(by seconds: Float) { time += seconds }

    /// True once a one-shot has played out. Always false while looping.
    public var isFinished: Bool { !isLooping && time >= clip.duration }

    /// The time actually sampled — wrapped or clamped into the clip.
    public var sampleTime: Float { clip.wrappedTime(time, looping: isLooping) }
}

/// A rig with a pose on it, and the matrices a vertex shader needs to wear it.
///
/// **One of these per character, kept between frames and written over.** The arrays are sized once
/// at construction, so posing a character allocates nothing.
///
/// ### The three arrays, and why all three are kept
///
/// | | space | what it is for |
/// |---|---|---|
/// | ``localTransforms`` | joint-local | what a clip writes, and the only space a blend is meaningful in |
/// | ``modelTransforms`` | model | attaching things — a weapon to a hand, a camera to a head |
/// | ``skinningMatrices`` | model, bind-relative | what the shader multiplies vertices by |
///
/// The third is the second times the inverse bind transform, and is the only one the GPU sees. The
/// second is kept because a rig whose hand you cannot find the position of is a rig nothing can be
/// attached to, and recovering it from the skinning matrix means multiplying the bind transform back
/// in — the same work, done later, by a caller who has to know to do it.
public nonisolated struct SkeletonPose: Sendable {

    public let skeleton: Skeleton

    /// Each joint relative to its parent.
    public private(set) var localTransforms: [JointTransform]

    /// Each joint in the character's own space, the parent chain accumulated.
    public private(set) var modelTransforms: [simd_float4x4]

    /// What the vertex shader wants: model-space, relative to where the mesh was bound.
    public private(set) var skinningMatrices: [simd_float4x4]

    public var jointCount: Int { skeleton.jointCount }

    /// Starts at the rig's rest pose, so a character that is never animated still stands up.
    public init(skeleton: Skeleton) {
        self.skeleton = skeleton
        self.localTransforms = skeleton.restTransforms.map(JointTransform.init(matrix:))
        self.modelTransforms = Array(repeating: matrix_identity_float4x4, count: skeleton.jointCount)
        self.skinningMatrices = Array(repeating: matrix_identity_float4x4, count: skeleton.jointCount)
        refresh()
    }

    /// Poses the rig from one clip.
    ///
    /// The playhead must have been made for this pose's skeleton — or one with the same joints in the
    /// same order. **A playhead made for another rig stops here, saying so**, rather than reading its
    /// mapping past the end on some later frame.
    public mutating func set(to playhead: AnimationPlayhead) {
        checkBinding(of: playhead, role: "playhead")
        let time = playhead.sampleTime
        for joint in 0..<skeleton.jointCount {
            let rest = JointTransform(matrix: skeleton.restTransforms[joint])
            guard let clipJoint = playhead.binding.clipJointIndices[joint] else {
                localTransforms[joint] = rest
                continue
            }
            localTransforms[joint] = playhead.clip.sample(joint: clipJoint, at: time, rest: rest)
        }
        refresh()
    }

    /// Poses the rig from two clips at once — a cross-fade.
    ///
    /// `weight` is how much of `other`: 0 is all `playhead`, 1 is all `other`. Run it from 0 to 1
    /// over a fifth of a second and a character changes gait without a snap; that is the whole
    /// mechanism, and it is why ``JointTransform`` keeps rotation as a quaternion.
    ///
    /// **Both clips are sampled at their own times.** They are unrelated clips of unrelated lengths;
    /// a walk and a run only line up if somebody authored them to, and that is a rigging decision
    /// this cannot make on their behalf.
    ///
    /// Both playheads must have been made for this pose's skeleton, as for the one-clip `set(to:)`.
    public mutating func set(to playhead: AnimationPlayhead,
                             blendedWith other: AnimationPlayhead,
                             weight: Float) {
        checkBinding(of: playhead, role: "playhead")
        checkBinding(of: other, role: "blended playhead")
        let clamped = min(max(weight, 0), 1)
        let timeA = playhead.sampleTime
        let timeB = other.sampleTime
        for joint in 0..<skeleton.jointCount {
            let rest = JointTransform(matrix: skeleton.restTransforms[joint])
            let a = playhead.binding.clipJointIndices[joint].map {
                playhead.clip.sample(joint: $0, at: timeA, rest: rest)
            } ?? rest
            let b = other.binding.clipJointIndices[joint].map {
                other.clip.sample(joint: $0, at: timeB, rest: rest)
            } ?? rest
            localTransforms[joint] = a.blended(toward: b, weight: clamped)
        }
        refresh()
    }

    /// Poses the rig directly, for anything that is not a clip — a procedural head turn, a ragdoll,
    /// a rig driven by a solver. One transform per joint, joint-local, in the skeleton's order.
    public mutating func set(to newValue: [JointTransform]) {
        precondition(newValue.count == skeleton.jointCount,
                     "pose has \(skeleton.jointCount) joints, given \(newValue.count)")
        localTransforms = newValue
        refresh()
    }

    private func checkBinding(of playhead: AnimationPlayhead, role: String) {
        precondition(playhead.binding.isBound(to: skeleton),
                     "\(role) for clip '\(playhead.clip.name)' was made for a skeleton of "
                     + "\(playhead.binding.skeletonJointPaths.count) joints that is not this pose's "
                     + "(\(skeleton.jointCount) joints); make the AnimationPlayhead with this pose's skeleton")
    }

    /// Rebuilds the model-space and skinning matrices from the local transforms.
    ///
    /// One forward pass, no recursion — which is what ``Skeleton``'s parent-first ordering rule buys,
    /// and why that rule is checked rather than assumed. Every `set` ends with it, so nothing outside
    /// needs to call it.
    mutating func refresh() {
        for joint in 0..<skeleton.jointCount {
            let local = localTransforms[joint].matrix
            if let parent = skeleton.parentIndices[joint] {
                modelTransforms[joint] = modelTransforms[parent] * local
            } else {
                modelTransforms[joint] = local
            }
            skinningMatrices[joint] = modelTransforms[joint] * skeleton.inverseBindTransforms[joint]
        }
    }

    /// Where a joint has ended up, in the character's own space.
    ///
    /// The thing to hang a weapon, a muzzle flash or a camera off. Multiply by the character's
    /// world transform to get somewhere in the world.
    public func modelTransform(ofJoint index: Int) -> simd_float4x4 { modelTransforms[index] }
}
