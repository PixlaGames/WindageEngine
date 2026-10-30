//
//  StrideAlignment.swift
//  WindageEngine
//

import simd

/// Where in its own cycle each gait reaches the same moment of the stride, so gaits blended at one phase blend one
/// stride.
///
/// ### Why a blend of gaits needs it
///
/// **Two gaits blended at the same fraction of their cycles are not blended at the same moment of the stride.** A
/// walk, a run and a sprint each start wherever their animator started them, so mixing them by a shared fraction can
/// average one clip's left foot forward against another's right — which draws as legs crossing and clipping through
/// each other, and the arms with them. Sampling each gait at `phase + phaseOffset` puts the same moment of the stride
/// at the same fraction in all of them, and the blend then averages two poses of one stride.
///
/// ### Matched on the whole foot path, not on one event
///
/// Extracted from a game's own hand-written version, which learned this the hard way: its first attempt looked for
/// the frame where the foot was furthest along whichever axis it travelled most, and picked that axis *per clip*. A
/// sprint lifts the foot higher than it carries it forward and a walk does the opposite, so "furthest along the
/// dominant axis" meant the top of the lift in one clip and the front of the stride in another. Correlating the whole
/// path — centred, scaled to unit size, every shift tried — asks no question about axes or signs.
///
/// **Anchored on the gait with the longest stride**, and **a poor match is left unaligned rather than aligned badly**:
/// if the best shift still leaves two paths far apart they are not the same motion, and a confident wrong answer is
/// worse than none. ``match`` says how good each one was, so a bad alignment can be logged rather than found by
/// watching the legs.
public nonisolated struct StrideAlignment: Sendable, Equatable {
    /// Added to a shared phase (0…1) before sampling this clip: `time = ((phase + phaseOffset) mod 1) × duration`.
    public let phaseOffset: Float
    /// How far the clip's foot path stayed from the anchor's at the best shift: 0 is a perfect match, and anything near
    /// 2 is an unrelated motion. Zero for the anchor itself.
    public let match: Float
    /// Whether ``phaseOffset`` was applied — false when the match was too poor to trust, and the offset is then 0.
    public let isAligned: Bool

    /// Lines `clips` up against each other by the path of `footJoint` — a joint path, or the last component of one
    /// (`foot_l`).
    ///
    /// - Parameters:
    ///   - samples: points along each cycle the paths are compared at.
    ///   - acceptBelow: the worst ``match`` still trusted. 0.8 is the game's number this came from.
    /// - Returns: one alignment per clip that has a stride, by clip name. A clip whose foot barely moves — an idle — or
    ///   that does not drive the foot has none, and should be left on its own clock. Empty when `footJoint` is not a
    ///   joint of `skeleton`.
    public static func align(_ clips: [AnimationClip], on skeleton: Skeleton, footJoint: String,
                             samples: Int = 64, acceptBelow: Float = 0.8) -> [String: StrideAlignment] {
        guard samples > 1,
              let foot = skeleton.jointPaths.firstIndex(where: { $0 == footJoint || $0.hasSuffix("/" + footJoint) })
        else { return [:] }

        var paths: [(name: String, path: [SIMD3<Float>], travel: Float)] = []
        var pose = SkeletonPose(skeleton: skeleton)
        for clip in clips where clip.duration > 0 {
            var playhead = AnimationPlayhead(clip: clip, skeleton: skeleton, looping: true)
            guard playhead.binding.clipJointIndices[foot] != nil else { continue }
            var path: [SIMD3<Float>] = []
            path.reserveCapacity(samples)
            for sample in 0..<samples {
                playhead.time = clip.duration * Float(sample) / Float(samples)
                pose.set(to: playhead)
                let column = pose.modelTransform(ofJoint: foot).columns.3
                path.append(SIMD3(column.x, column.y, column.z))
            }
            let mean = path.reduce(SIMD3<Float>.zero, +) / Float(samples)
            path = path.map { $0 - mean }
            // Scaled so a long stride and a short one compare on shape rather than on size.
            let scale = (path.reduce(Float(0)) { $0 + simd_length_squared($1) } / Float(samples)).squareRoot()
            // **A foot that barely moves has no stride** — an idle's sway. Relative to the rig's own size, so a rig in
            // centimetres and one in metres agree about what barely moving is.
            guard scale > 0.01 * rigSize(skeleton) else { continue }
            paths.append((clip.name, path.map { $0 / scale }, scale))
        }
        guard let anchor = paths.max(by: { $0.travel < $1.travel }) else { return [:] }

        var result: [String: StrideAlignment] = [anchor.name: StrideAlignment(phaseOffset: 0, match: 0, isAligned: true)]
        for entry in paths where entry.name != anchor.name {
            var bestShift = 0
            var bestError = Float.greatestFiniteMagnitude
            for shift in 0..<samples {
                var error: Float = 0
                for i in 0..<samples {
                    error += simd_length_squared(anchor.path[i] - entry.path[(i + shift) % samples])
                }
                if error < bestError { bestError = error; bestShift = shift }
            }
            // Both paths are unit-scaled, so the error compares across clips.
            let quality = bestError / Float(samples)
            let aligned = quality < acceptBelow
            result[entry.name] = StrideAlignment(phaseOffset: aligned ? Float(bestShift) / Float(samples) : 0,
                                                 match: quality, isAligned: aligned)
        }
        return result
    }

    /// How far the rig's rest pose reaches from its root — a metre or two for a person, in the rig's own units.
    private static func rigSize(_ skeleton: Skeleton) -> Float {
        let pose = SkeletonPose(skeleton: skeleton)
        var reach: Float = 0
        for joint in 0..<skeleton.jointCount {
            let p = pose.modelTransform(ofJoint: joint).columns.3
            reach = max(reach, simd_length(SIMD3(p.x, p.y, p.z)))
        }
        return max(reach, 1e-3)
    }
}
