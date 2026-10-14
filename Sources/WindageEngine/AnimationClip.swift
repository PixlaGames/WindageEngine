//
//  AnimationClip.swift
//  WindageEngine
//

import simd

/// One joint's placement relative to its parent, kept as translation, rotation and scale rather
/// than as a matrix.
///
/// **Separated because a matrix cannot be blended.** Averaging two rotation matrices does not give a
/// rotation — it gives a shear that shrinks the mesh toward the midpoint — so every engine that
/// cross-fades animations keeps rotation as a quaternion until the last moment. ``matrix`` is that
/// last moment.
public nonisolated struct JointTransform: Sendable, Equatable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public static let identity = JointTransform(translation: .zero,
                                                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                scale: .one)

    public init(translation: SIMD3<Float> = .zero,
                rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                scale: SIMD3<Float> = .one) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// Composed in the only order that means anything: scale, then rotate, then translate.
    public var matrix: simd_float4x4 {
        let r = simd_float4x4(rotation)
        return simd_float4x4(columns: (
            r.columns.0 * scale.x,
            r.columns.1 * scale.y,
            r.columns.2 * scale.z,
            SIMD4(translation.x, translation.y, translation.z, 1)
        ))
    }

    /// Reads a joint-local transform back out of a matrix.
    ///
    /// Used for the rest pose, which arrives as matrices and has to become blendable. Assumes no
    /// shear, which holds for anything a rig authoring tool produces.
    public init(matrix m: simd_float4x4) {
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var s = SIMD3(simd_length(c0), simd_length(c1), simd_length(c2))
        // A mirrored rig — one axis flipped — has a negative determinant, and normalising the
        // columns without noticing turns the flip into a rotation, which puts a left hand where a
        // right one belongs. Fold the flip into the x scale, which is where every rig format puts it.
        if simd_determinant(m) < 0 { s.x = -s.x }
        let basis = simd_float3x3(columns: (
            s.x != 0 ? c0 / s.x : SIMD3(1, 0, 0),
            s.y != 0 ? c1 / s.y : SIMD3(0, 1, 0),
            s.z != 0 ? c2 / s.z : SIMD3(0, 0, 1)
        ))
        self.translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        self.rotation = simd_quatf(basis)
        self.scale = s
    }

    /// Blends toward another transform: `weight` of 0 is `self`, 1 is `other`.
    ///
    /// Rotation takes the **shortest** arc, which is what a cross-fade wants — the long way round is
    /// a character's head spinning to arrive at the same place.
    public func blended(toward other: JointTransform, weight: Float) -> JointTransform {
        JointTransform(translation: simd_mix(translation, other.translation, SIMD3(repeating: weight)),
                       rotation: simd_slerp(rotation, other.rotation, weight),
                       scale: simd_mix(scale, other.scale, SIMD3(repeating: weight)))
    }
}

/// Why a ``JointTrack`` or an ``AnimationClip`` could not be made from the data it was given.
///
/// **Checked when the clip is built, not when it is sampled.** Every one of these used to be accepted
/// and then trap as an index out of range on some later frame, in the middle of posing a character,
/// with nothing to say which clip or why.
public nonisolated enum AnimationClipError: Error, CustomStringConvertible, Sendable, Equatable {
    /// A track's values are not one per joint per key.
    case valueCountMismatch(keys: Int, joints: Int, values: Int)
    /// A track claims fewer than zero joints.
    case negativeJointCount(Int)
    /// A key time is NaN or infinite.
    case nonFiniteTime(key: Int)
    /// Key times go backwards; sampling finds its keys by binary search, which needs them in order.
    case timesOutOfOrder(key: Int)
    /// A channel's track is for a different number of joints than the clip names.
    case trackJointCountMismatch(channel: String, track: Int, clip: Int)

    public var description: String {
        switch self {
        case .valueCountMismatch(let keys, let joints, let values):
            "\(keys) keys of \(joints) joints need \(keys * joints) values, given \(values)"
        case .negativeJointCount(let count):
            "a track cannot have \(count) joints"
        case .nonFiniteTime(let key):
            "key \(key) has a time that is not a finite number"
        case .timesOutOfOrder(let key):
            "key \(key) comes earlier than the key before it; key times must not decrease"
        case .trackJointCountMismatch(let channel, let track, let clip):
            "the \(channel) track is for \(track) joints, and the clip names \(clip)"
        }
    }
}

/// Keyframes for one channel across every joint the clip touches.
///
/// **Time-major**: all of a moment's joints sit together, because sampling reads one moment and
/// every joint in it. Laid out joint-major, a single sample would stride across the whole array.
public nonisolated struct JointTrack<Value: Sendable>: Sendable {
    public let times: [Float]
    /// `times.count * jointCount` values, a whole moment at a time.
    public let values: [Value]
    public let jointCount: Int

    public var isEmpty: Bool { times.isEmpty || jointCount == 0 }

    /// - Throws: ``AnimationClipError`` unless there is one value per joint per key, the joint count is
    ///   not negative, and the key times are finite and never decrease.
    public init(times: [Float], values: [Value], jointCount: Int) throws {
        guard jointCount >= 0 else { throw AnimationClipError.negativeJointCount(jointCount) }
        guard values.count == times.count * jointCount else {
            throw AnimationClipError.valueCountMismatch(keys: times.count, joints: jointCount,
                                                        values: values.count)
        }
        for (key, time) in times.enumerated() {
            guard time.isFinite else { throw AnimationClipError.nonFiniteTime(key: key) }
            if key > 0, time < times[key - 1] { throw AnimationClipError.timesOutOfOrder(key: key) }
        }
        self.times = times
        self.values = values
        self.jointCount = jointCount
    }

    /// A track with no keys, for a channel a clip does not carry.
    public static func empty(jointCount: Int) -> JointTrack {
        // Cannot throw: no keys means no values to count and no times to order.
        try! JointTrack(times: [], values: [], jointCount: max(0, jointCount))
    }

    public subscript(key: Int, joint: Int) -> Value { values[key * jointCount + joint] }

    /// Which two keys bracket a time, and how far between them it lies.
    ///
    /// Binary search rather than a scan: a two-minute clip at 30 Hz is 3,600 keys, and this runs
    /// once per channel per character per frame.
    func span(at time: Float) -> (lower: Int, upper: Int, fraction: Float) {
        if times.count == 1 { return (0, 0, 0) }
        if time <= times[0] { return (0, 0, 0) }
        if time >= times[times.count - 1] {
            let last = times.count - 1
            return (last, last, 0)
        }
        var low = 0, high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        return (low, high, span > 0 ? (time - times[low]) / span : 0)
    }
}

/// A named stretch of animation: what each joint does, and for how long.
///
/// **A clip names its joints and does not assume they are a rig's.** Its joints are matched to a
/// ``Skeleton``'s by path through an ``AnimationBinding``, so a clip authored for an upper body
/// leaves the legs at rest instead of driving joint 4 of a rig it was never made for. The two lists
/// agreeing is the common case and the cheap one; it is not a requirement.
///
/// ### Translations are joint-local
///
/// Matching ``Skeleton/restTransforms`` and *not* matching its bind transforms — see the note there,
/// which is where that distinction is measured out.
public nonisolated struct AnimationClip: Sendable {
    public let name: String
    public let jointPaths: [String]
    public let translation: JointTrack<SIMD3<Float>>
    public let rotation: JointTrack<simd_quatf>
    public let scale: JointTrack<SIMD3<Float>>

    /// How long the clip runs, in seconds: the latest time any of its channels reaches.
    public let duration: Float

    public var jointCount: Int { jointPaths.count }

    /// - Throws: ``AnimationClipError/trackJointCountMismatch(channel:track:clip:)`` when a channel
    ///   that has keys is for a different number of joints than `jointPaths` names. A channel with no
    ///   keys is not checked: it is not sampled.
    public init(name: String,
                jointPaths: [String],
                translation: JointTrack<SIMD3<Float>>,
                rotation: JointTrack<simd_quatf>,
                scale: JointTrack<SIMD3<Float>>) throws {
        let checks: [(String, Int, Bool)] = [("translation", translation.jointCount, translation.times.isEmpty),
                                             ("rotation", rotation.jointCount, rotation.times.isEmpty),
                                             ("scale", scale.jointCount, scale.times.isEmpty)]
        for (channel, count, hasNoKeys) in checks where !hasNoKeys && count != jointPaths.count {
            throw AnimationClipError.trackJointCountMismatch(channel: channel, track: count,
                                                             clip: jointPaths.count)
        }
        self.init(validatedName: name, jointPaths: jointPaths,
                  translation: translation, rotation: rotation, scale: scale)
    }

    /// The memberwise part, for data already checked — ``renamed(to:)`` has nothing to re-check.
    private init(validatedName name: String,
                 jointPaths: [String],
                 translation: JointTrack<SIMD3<Float>>,
                 rotation: JointTrack<simd_quatf>,
                 scale: JointTrack<SIMD3<Float>>) {
        self.name = name
        self.jointPaths = jointPaths
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.duration = max(translation.times.last ?? 0,
                            rotation.times.last ?? 0,
                            scale.times.last ?? 0)
    }

    /// The same clip under a different name.
    ///
    /// **For the names an exporter produces.** A clip arrives called
    /// `root_A_MOD_BL_Walk_F_Femn_Animation_Base_Layer`; a game asks for `walk`.
    public func renamed(to name: String) -> AnimationClip {
        AnimationClip(validatedName: name, jointPaths: jointPaths,
                      translation: translation, rotation: rotation, scale: scale)
    }

    /// Wraps or clamps a time into the clip's own range.
    ///
    /// **A looping clip wraps rather than clamping**, and its first and last keys are expected to
    /// hold the same pose — that is how a loop authored in any rigging tool is laid out. Wrapping
    /// past the end therefore interpolates from the second-to-last key to the last one and arrives
    /// exactly where it started.
    public func wrappedTime(_ time: Float, looping: Bool) -> Float {
        guard duration > 0 else { return 0 }
        if !looping { return min(max(time, 0), duration) }
        let wrapped = time.truncatingRemainder(dividingBy: duration)
        return wrapped < 0 ? wrapped + duration : wrapped
    }

    /// The clip's own joint `index` at a moment, falling back to `rest` for any channel the clip
    /// does not carry.
    ///
    /// A clip with rotation keys and nothing else is normal — it is most of what a rigger authors —
    /// and it must not zero the translations it never mentioned.
    public func sample(joint index: Int, at time: Float, rest: JointTransform) -> JointTransform {
        var result = rest
        if !translation.isEmpty {
            let s = translation.span(at: time)
            result.translation = simd_mix(translation[s.lower, index],
                                          translation[s.upper, index],
                                          SIMD3(repeating: s.fraction))
        }
        if !rotation.isEmpty {
            let s = rotation.span(at: time)
            result.rotation = simd_slerp(rotation[s.lower, index], rotation[s.upper, index], s.fraction)
        }
        if !scale.isEmpty {
            let s = scale.span(at: time)
            result.scale = simd_mix(scale[s.lower, index], scale[s.upper, index], SIMD3(repeating: s.fraction))
        }
        return result
    }
}

/// Which of a rig's joints each of a clip's joints drives, worked out once.
///
/// **This exists so that matching joints by name never happens per frame.** Matching by name is the
/// correct thing to do — index order is not a contract between a rig and a clip authored separately
/// — but doing it 100 joints × 60 times a second is a string comparison budget nobody meant to
/// spend.
///
/// **Made by the engine, read by a game.** An ``AnimationPlayhead`` builds one; ``unboundJoints`` and
/// ``isEmpty`` are what a game asks of it. The mapping itself is the engine's business.
public nonisolated struct AnimationBinding: Sendable {
    /// For each of the skeleton's joints, the clip joint driving it, or `nil` to leave it at rest.
    let clipJointIndices: [Int?]

    /// The joint paths of the skeleton this was built for — what ``SkeletonPose`` checks a playhead
    /// against before posing with it.
    let skeletonJointPaths: [String]

    /// The rig's joints this clip says nothing about — they stay at their rest transform.
    ///
    /// **Worth logging once at load.** An empty binding is what "the character is a statue" looks
    /// like from the inside, and it is otherwise indistinguishable from a clip that happens to hold
    /// still.
    public let unboundJoints: [String]

    init(clip: AnimationClip, skeleton: Skeleton) {
        var clipIndexByPath: [String: Int] = [:]
        clipIndexByPath.reserveCapacity(clip.jointPaths.count)
        for (index, path) in clip.jointPaths.enumerated() { clipIndexByPath[path] = index }

        var mapping: [Int?] = []
        var unbound: [String] = []
        mapping.reserveCapacity(skeleton.jointCount)
        for path in skeleton.jointPaths {
            if let index = clipIndexByPath[path] {
                mapping.append(index)
            } else {
                mapping.append(nil)
                unbound.append(path)
            }
        }
        self.clipJointIndices = mapping
        self.skeletonJointPaths = skeleton.jointPaths
        self.unboundJoints = unbound
    }

    /// Whether the clip drives no joint of this rig at all — a clip and a rig that have nothing to
    /// do with each other.
    public var isEmpty: Bool { clipJointIndices.allSatisfy { $0 == nil } }

    /// Whether this was built for `skeleton`, or one with the same joints in the same order — which
    /// poses identically, since the mapping is by path.
    ///
    /// **Cheap in the common case**: the same skeleton shares its joint-path array's storage, and two
    /// equal arrays sharing storage compare without looking at a string.
    func isBound(to skeleton: Skeleton) -> Bool {
        skeletonJointPaths == skeleton.jointPaths
    }
}
