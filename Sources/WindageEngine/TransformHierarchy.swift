//
//  TransformHierarchy.swift
//  WindageEngine
//

import simd

/// What is wrong with a ``TransformHierarchy`` that could not be built, or with local transforms it
/// was given.
///
/// **Every fault here is a structural one, caught when the hierarchy is built or its transforms
/// replaced.** None of them can be detected later by looking: each produces a transform that is merely
/// wrong, or an index read past the end at sixty hertz.
public nonisolated enum TransformHierarchyError: Error, CustomStringConvertible, Sendable, Equatable {
    case countMismatch(attachments: Int, transforms: Int)
    case selfParent(node: Int)
    case parentAfterChild(node: Int, parent: Int)
    case unknownNode(node: Int, parent: Int)
    case unknownExternal(node: Int, external: Int, count: Int)

    public var description: String {
        switch self {
        case .countMismatch(let attachments, let transforms):
            "\(attachments) attachments against \(transforms) transforms"
        case .selfParent(let node):
            "node \(node) is attached to itself"
        case .parentAfterChild(let node, let parent):
            "node \(node) is attached to \(parent), which is resolved after it"
        case .unknownNode(let node, let parent):
            "node \(node) is attached to \(parent), which is not in this hierarchy"
        case .unknownExternal(let node, let external, let count):
            "node \(node) is attached to external \(external), and only \(count) were declared"
        }
    }
}

/// Things that hang off other things: a lamp on a hand, a turret on a hull, a sight on a rifle.
///
/// ### This is parenting, and it is deliberately not a scene graph
///
/// A scene graph is an object model — nodes that own children, own components, are looked up by name
/// and are the unit everything else in the engine is written against. That is a decision this engine
/// has not made and does not need to make. **What a game actually runs into
/// first is much smaller: one transform expressed relative to another**, resolved in the right order,
/// every frame.
///
/// So this owns no objects. It is a list of attachments and a list of matrices; what those matrices
/// belong to is the caller's business, and the same hierarchy can drive a drawable, a light and a
/// collision volume without knowing that any of them exist.
///
/// ### Half of it arrived with ``Skeleton``, and the missing half is the interesting one
///
/// A rig is already a hierarchy, resolved by ``SkeletonPose`` in one forward pass. What it cannot do
/// is reach *outside* itself — and the canonical case, a weapon in a hand, is exactly that: the
/// parent is a joint, inside a pose, that is itself positioned by an object's world transform.
///
/// ``Attachment/external(_:)`` is that case made first-class. A node attached externally takes its
/// parent's world transform from an array handed to ``refresh(attachedTo:)``, so the node's own local
/// transform stays what it should be — **the grip, authored once** — rather than being rewritten every
/// frame by a caller who has had to keep the grip somewhere else anyway.
///
/// ### Parent-first, checked rather than trusted
///
/// The same rule ``Skeleton`` enforces, for the same reason: a parent must come before its child, so
/// one forward pass resolves everything and nothing recurses. A hierarchy that violated it would
/// still produce a picture — with the child a frame behind the parent, which reads as a lag in the
/// animation rather than as a structural fault.
public nonisolated struct TransformHierarchy: Sendable {

    /// What a node hangs off.
    public enum Attachment: Sendable, Equatable {
        /// Nothing. Its local transform is its world transform.
        case world
        /// Another node of this hierarchy, which must appear **earlier** than this one.
        case node(Int)
        /// Something this hierarchy does not own — a joint of a posed character, a platform driven by
        /// another system. Indexes the array given to ``refresh(attachedTo:)``.
        case external(Int)
    }

    public let attachments: [Attachment]

    /// How many external transforms ``refresh(attachedTo:)`` will be given.
    ///
    /// **Declared up front so an out-of-range attachment is a load-time error.** Left to the call
    /// site it would be an index read at sixty hertz, and the cheapest thing to do with a bad one is
    /// substitute the identity — which puts the held object at the world origin, once, in a frame
    /// nobody was looking at.
    public let externalCount: Int

    /// Each node relative to whatever it hangs off.
    ///
    /// **Read-only, with checked setters** — ``setLocalTransform(_:ofNode:)`` and
    /// ``setLocalTransforms(_:)``. Assigned directly, an array one short would be accepted here and
    /// read past its end by the next ``refresh(attachedTo:)``, far from whoever made it.
    public private(set) var localTransforms: [simd_float4x4]

    /// Where each node has ended up. Valid after ``refresh(attachedTo:)``.
    public private(set) var worldTransforms: [simd_float4x4]

    public var count: Int { attachments.count }

    public init(attachments: [Attachment],
                localTransforms: [simd_float4x4]? = nil,
                externalCount: Int = 0) throws {
        let locals = localTransforms
            ?? [simd_float4x4](repeating: matrix_identity_float4x4, count: attachments.count)
        guard locals.count == attachments.count else {
            throw TransformHierarchyError.countMismatch(attachments: attachments.count, transforms: locals.count)
        }

        for (node, attachment) in attachments.enumerated() {
            switch attachment {
            case .world:
                continue
            case .node(let parent):
                guard parent != node else { throw TransformHierarchyError.selfParent(node: node) }
                guard parent >= 0, parent < attachments.count else {
                    throw TransformHierarchyError.unknownNode(node: node, parent: parent)
                }
                guard parent < node else { throw TransformHierarchyError.parentAfterChild(node: node, parent: parent) }
            case .external(let index):
                guard index >= 0, index < externalCount else {
                    throw TransformHierarchyError.unknownExternal(node: node, external: index, count: externalCount)
                }
            }
        }

        self.attachments = attachments
        self.externalCount = max(0, externalCount)
        self.localTransforms = locals
        self.worldTransforms = locals
    }

    /// Moves one node relative to whatever it hangs off. Takes effect at the next
    /// ``refresh(attachedTo:)``.
    public mutating func setLocalTransform(_ transform: simd_float4x4, ofNode node: Int) {
        precondition(localTransforms.indices.contains(node),
                     "node \(node) is not in a hierarchy of \(localTransforms.count)")
        localTransforms[node] = transform
    }

    /// Replaces every node's local transform at once. Takes effect at the next
    /// ``refresh(attachedTo:)``.
    ///
    /// - Throws: ``TransformHierarchyError/countMismatch(attachments:transforms:)`` when the array is
    ///   not one transform per node; the hierarchy is left as it was.
    public mutating func setLocalTransforms(_ transforms: [simd_float4x4]) throws {
        guard transforms.count == attachments.count else {
            throw TransformHierarchyError.countMismatch(attachments: attachments.count,
                                                        transforms: transforms.count)
        }
        localTransforms = transforms
    }

    /// Resolves every node's world transform, in one forward pass.
    ///
    /// - Parameter externals: the world transforms of the things outside this hierarchy that nodes
    ///   are attached to, in the order ``Attachment/external(_:)`` indexes. Must hold at least
    ///   ``externalCount`` of them.
    public mutating func refresh(attachedTo externals: [simd_float4x4] = []) {
        precondition(externals.count >= externalCount,
                     "a hierarchy declaring \(externalCount) external attachments was given "
                     + "\(externals.count)")
        for node in 0..<attachments.count {
            let local = localTransforms[node]
            switch attachments[node] {
            case .world:              worldTransforms[node] = local
            case .node(let parent):   worldTransforms[node] = worldTransforms[parent] * local
            case .external(let index):worldTransforms[node] = externals[index] * local
            }
        }
    }

    public func worldTransform(of node: Int) -> simd_float4x4 { worldTransforms[node] }
}
