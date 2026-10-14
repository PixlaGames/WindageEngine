//
//  Skeleton.swift
//  WindageEngine
//

import simd

public nonisolated enum SkeletonError: Error, CustomStringConvertible, Sendable, Equatable {
    case emptySkeleton
    case transformCountMismatch(joints: Int, rest: Int, bind: Int)
    case missingParent(joint: String, parent: String)
    case parentAfterChild(joint: String, parent: String)
    case singularBindTransform(joint: String)

    public var description: String {
        switch self {
        case .emptySkeleton:
            "skeleton has no joints"
        case .transformCountMismatch(let joints, let rest, let bind):
            "skeleton has \(joints) joints but \(rest) rest and \(bind) bind transforms"
        case .missingParent(let joint, let parent):
            "joint \(joint) names parent \(parent), which is not in the skeleton"
        case .parentAfterChild(let joint, let parent):
            "joint \(joint) appears before its parent \(parent); joints must be in parent-first order"
        case .singularBindTransform(let joint):
            "joint \(joint) has a bind transform that cannot be inverted"
        }
    }
}

/// A rig: named joints, who each joint hangs off, and where the mesh was bound to them.
///
/// **Structure only — no pose, no time, no mesh.** One of these is loaded once and shared by every
/// character wearing it; what changes per character per frame is a ``SkeletonPose``.
///
/// ### Parentage is carried in the names, not alongside them
///
/// A joint is named by its **path** — `"root"`, `"root/spine"`, `"root/spine/arm_l"` — which is how
/// USD stores a skeleton and how Model I/O hands one over. So the hierarchy is derived here rather
/// than supplied, and the derivation is strict: a joint whose parent path is absent, or appears
/// after it in the list, is an error rather than a silently reparented joint. A rig that quietly
/// loses a parent does not fail; it draws a character with a limb in the wrong place, and nothing
/// says which limb or why.
///
/// ### The two transform arrays are in different spaces, and nothing in the format says so
///
/// This is the single easiest thing to get wrong, and it was found by measuring rather than reading:
/// a rig authored with its root joint at (5, 0, 0) and a child one meter above it comes back with
///
/// - `restTransforms[child]` = translate(0, 1, 0) — **joint-local**, relative to its parent, and
/// - `bindTransforms[child]` = translate(5, 1, 0) — **skeleton-space**, already accumulated.
///
/// They coincide in any rig whose root sits at the origin, which is most hand-written test rigs and
/// no real character. Treat them alike and a character either collapses toward the origin or flies
/// apart, depending on which way round the mistake went.
///
/// An animation clip's translations are joint-local, matching the rest transforms — see
/// ``AnimationClip``.
public nonisolated struct Skeleton: Sendable {

    /// Joint paths, in parent-first order.
    public let jointPaths: [String]

    /// For each joint, the index of its parent, or `nil` for a root.
    ///
    /// A skeleton may have more than one root; USD does not forbid it and neither does this.
    public let parentIndices: [Int?]

    /// The rest pose, **joint-local**: each joint relative to its parent.
    ///
    /// This is what a joint falls back to when a clip has no channel for it, which is how a clip
    /// that animates an upper body leaves the legs alone.
    public let restTransforms: [simd_float4x4]

    /// For each joint, the inverse of its **skeleton-space** bind transform.
    ///
    /// Stored inverted because that is the only form skinning ever uses: the skinning matrix for a
    /// joint is its posed model-space transform times this, and the pair is what takes a vertex from
    /// the space it was modeled in to the space it is posed in.
    public let inverseBindTransforms: [simd_float4x4]

    public var jointCount: Int { jointPaths.count }

    /// - Parameters:
    ///   - restTransforms: joint-local.
    ///   - bindTransforms: **skeleton-space**, not joint-local. Inverted once, here.
    ///   - geometryBindTransform: takes a vertex from the space the mesh was modeled in into the
    ///     space the bind transforms are measured in. Applied *before* skinning, so it multiplies in
    ///     on the right of each inverse bind matrix and the shader never learns it exists.
    public init(jointPaths: [String],
                restTransforms: [simd_float4x4],
                bindTransforms: [simd_float4x4],
                geometryBindTransform: simd_float4x4 = matrix_identity_float4x4) throws {
        guard !jointPaths.isEmpty else { throw SkeletonError.emptySkeleton }
        guard jointPaths.count == restTransforms.count, jointPaths.count == bindTransforms.count else {
            throw SkeletonError.transformCountMismatch(joints: jointPaths.count,
                                                       rest: restTransforms.count,
                                                       bind: bindTransforms.count)
        }

        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(jointPaths.count)
        for (index, path) in jointPaths.enumerated() { indexByPath[path] = index }

        var parents: [Int?] = []
        parents.reserveCapacity(jointPaths.count)
        for (index, path) in jointPaths.enumerated() {
            guard let slash = path.lastIndex(of: "/") else {
                parents.append(nil)
                continue
            }
            let parentPath = String(path[path.startIndex..<slash])
            guard let parent = indexByPath[parentPath] else {
                throw SkeletonError.missingParent(joint: path, parent: parentPath)
            }
            // Parent-first order is what lets a pose accumulate model-space transforms in one
            // forward pass instead of recursing. USD guarantees it; this checks rather than trusts,
            // because the failure it prevents is a limb attached to a joint that has not moved yet
            // — visible, wrong, and attributable to nothing.
            guard parent < index else {
                throw SkeletonError.parentAfterChild(joint: path, parent: parentPath)
            }
            parents.append(parent)
        }

        var inverses: [simd_float4x4] = []
        inverses.reserveCapacity(bindTransforms.count)
        for (index, bind) in bindTransforms.enumerated() {
            // `simd_inverse` of a singular matrix returns NaN rather than failing, and a NaN
            // skinning matrix makes every vertex it touches vanish — the mesh is simply not drawn,
            // with nothing logged. Catch it where the name of the joint is still known.
            guard abs(simd_determinant(bind)) > 1e-12 else {
                throw SkeletonError.singularBindTransform(joint: jointPaths[index])
            }
            inverses.append(simd_inverse(bind) * geometryBindTransform)
        }

        self.jointPaths = jointPaths
        self.parentIndices = parents
        self.restTransforms = restTransforms
        self.inverseBindTransforms = inverses
    }

    /// The index of a joint by its full path, or `nil` if the rig has no such joint.
    ///
    /// Linear, and deliberately so: this is for wiring something to a named joint at load time — a
    /// weapon to a hand, a camera to a head — not for anything per-frame. Look the index up once and
    /// keep it.
    public func index(ofJoint path: String) -> Int? {
        jointPaths.firstIndex(of: path)
    }
}
