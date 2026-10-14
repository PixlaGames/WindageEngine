//
//  RigLoader.swift
//  WindageEngine
//

import Foundation
import ModelIO
import simd

public nonisolated enum RigLoaderError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No file by that name in the bundle, or none at that URL.
    case assetNotFound(String)
    /// The file was read and holds no skeleton.
    case noSkeleton(String)
    case conflictingGeometryBindTransforms(String)
    /// A clip in the file has keys of the wrong shape — see ``AnimationClipError``.
    case malformedClip(String, clip: String, AnimationClipError)

    public var description: String {
        switch self {
        case .assetNotFound(let name): "no rig file \(name)"
        case .noSkeleton(let name): "\(name) loaded but contains no skeleton — it is a statue"
        case .conflictingGeometryBindTransforms(let name):
            "\(name) binds several meshes to one skeleton with different geometry bind transforms"
        case .malformedClip(let name, let clip, let error): "\(name): clip '\(clip)' is malformed — \(error)"
        }
    }
}

/// A rig and everything it can do: one skeleton, and the clips authored against it.
public nonisolated struct Rig: Sendable {
    public let skeleton: Skeleton
    public let clips: [AnimationClip]

    /// Where the rig sits in the file's own node hierarchy, composed from the root.
    ///
    /// **The same matrix the mesh under it carries**, and for the same reason: an exported character
    /// has its geometry *and* its skeleton in centimeters under a parent scaled by 0.01. Apply it in
    /// front of the model matrix and the mesh, the rig and the clips are all corrected at once.
    public let nodeTransform: simd_float4x4

    public init(skeleton: Skeleton,
                clips: [AnimationClip],
                nodeTransform: simd_float4x4 = matrix_identity_float4x4) {
        self.skeleton = skeleton
        self.clips = clips
        self.nodeTransform = nodeTransform
    }

    public func clip(named name: String) -> AnimationClip? {
        clips.first { $0.name == name }
    }

    /// The same rig with more clips on it.
    ///
    /// **This is how a real character arrives.** Every toolchain that exports one animation at a time
    /// gives you a file per clip — and each of those files carries a whole copy of the mesh and the
    /// skeleton with it. The skeleton comes from the base file, once; the clips come from the others.
    /// See ``RigLoader/clips(named:withExtension:bundle:)`` for why the skeletons in those files must
    /// be ignored rather than merged.
    public func adding(_ moreClips: [AnimationClip]) -> Rig {
        Rig(skeleton: skeleton, clips: clips + moreClips, nodeTransform: nodeTransform)
    }

    /// The rig's joints that a clip says nothing about.
    ///
    /// **Empty is what you want; everything is what a clip for a different rig looks like.** Worth
    /// checking once at load — a clip that binds to nothing is indistinguishable at runtime from a
    /// character standing still.
    public func joints(notDrivenBy clip: AnimationClip) -> [String] {
        AnimationBinding(clip: clip, skeleton: skeleton).unboundJoints
    }
}

/// Reads a skeleton and its clips out of a USD file.
///
/// ### Why this is separate from ``MeshLoader``, and not merely tidier
///
/// **Reading a rig needs no GPU.** Geometry does — `MTKMesh` wants a device to put buffers on — but
/// a skeleton and a clip are numbers, and Model I/O will parse them with no allocator at all. Split
/// that way, the half with all the fiddly convention in it is testable by `swift test` against a
/// real file, with nothing to open and no device to create. The half that needs a device is a
/// dozen lines and has nothing to get wrong.
///
/// ### Model I/O does read UsdSkel — measured, not assumed
///
/// The load-bearing question before any of this was written: does Model I/O import skinning, or
/// silently drop it? A hand-authored rig — two joints, eight vertices, a rotating clip — comes back
/// complete: joint indices and weights as vertex attributes, the skeleton with its joint paths and
/// both transform arrays, and the clip with its keys converted to seconds. So no third-party
/// importer is needed, and FBX gets in by way of a Blender import and a USD export.
///
/// ### Three things the API does not tell you, each found by measuring
///
/// 1. **`MDLSkeleton`'s two transform arrays are in different spaces** — rest is joint-local, bind
///    is skeleton-space. See ``Skeleton``, which is where that is written down properly.
/// 2. **Clips do not live in the object hierarchy.** They arrive in `MDLAsset.animations`, a
///    separate container, named by their full path. Walk the objects looking for them and every
///    character is a statue.
/// 3. **`MDLAnimationBindComponent.jointPaths` comes back empty** even when the component has the
///    skeleton attached. The joint paths are on `MDLSkeleton.jointPaths`; a loader that reads only
///    the bind component finds no joints and concludes the same thing.
public nonisolated enum RigLoader {

    /// Something worth knowing about a load that still produced a rig — a clip file that added
    /// nothing, or a clip that was dropped. Handed to the `reportingTo` closure of the loads that take
    /// clip files.
    public enum Warning: Sendable, Equatable, CustomStringConvertible {
        /// The clip file was read and holds no animation.
        case noAnimation(file: String)
        /// The clip drives none of the rig's joints, so it was dropped — see ``Rig/joints(notDrivenBy:)``.
        case clipDrivesNoJoints(file: String, clip: String)
        /// The clip file could not be loaded; the rest of the rig was.
        case clipFileFailed(file: String, error: RigLoaderError)

        public var description: String {
            switch self {
            case .noAnimation(let file): "\(file): no animation in it"
            case .clipDrivesNoJoints(let file, let clip):
                "\(file): clip '\(clip)' drives none of this rig's joints — dropped"
            case .clipFileFailed(let file, let error): "\(file): \(error)"
            }
        }
    }

    /// **`bundle` and the extension have no defaults**, like ``MeshLoader``'s and ``AudioEngine``'s:
    /// `.main` is right for an app and wrong for a SwiftPM target, whose resources are in `.module`, and
    /// the extension is the format.
    public static func load(named name: String,
                            withExtension fileExtension: String,
                            bundle: Bundle) throws -> Rig {
        try load(url: url(of: name, withExtension: fileExtension, in: bundle))
    }

    /// The same, from a file anywhere on disk — see ``MeshLoader/load(url:device:vertexDescriptor:semantics:reportingTo:)``
    /// for why a bundle is not enough.
    public static func load(url: URL) throws -> Rig {
        try rig(from: openAsset(at: url), named: url.lastPathComponent)
    }

    /// A rig from one file and its animations from others, all by URL.
    ///
    /// **A clip file's single animation is renamed to the file's own stem**, so
    /// `…/RobotPlayer_Walk.usdc` becomes `RobotPlayer_Walk` — not
    /// `root_A_MOD_BL_Walk_F_Femn_Animation_Base_Layer`, which is what the exporter called it. The rest
    /// is as for the bundle form below.
    public static func load(url: URL,
                            clipURLs: [URL],
                            reportingTo report: (Warning) -> Void = { _ in }) throws -> Rig {
        let rig = try load(url: url)
        return adding(clipURLs.map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) },
                      to: rig, reportingTo: report)
    }

    /// Loads a rig from one file and its animations from others.
    ///
    /// - Parameter clipFiles: resource names, same extension. **A file holding exactly one clip has
    ///   that clip renamed to the file's own name**, because an exporter's internal name for an
    ///   animation is something like `root_A_MOD_BL_Walk_F_Femn_Animation_Base_Layer` and a game
    ///   wants to ask for `walk`. A file holding several leaves their names alone, since there is
    ///   then no single name the file could mean.
    ///
    /// **A clip file that cannot be read, holds no animation, or holds a clip that drives none of the
    /// rig's joints is reported and skipped**, and the rig loads without it: a clip bound to nothing is
    /// indistinguishable at runtime from a character standing still, and finding that out at load is the
    /// difference between a one-line fix and an afternoon. Only the base file failing throws.
    public static func load(named name: String,
                            withExtension fileExtension: String,
                            clipFiles: [String],
                            bundle: Bundle,
                            reportingTo report: (Warning) -> Void = { _ in }) throws -> Rig {
        let rig = try load(named: name, withExtension: fileExtension, bundle: bundle)
        var files: [(name: String, url: URL)] = []
        for file in clipFiles {
            guard let url = bundle.url(forResource: file, withExtension: fileExtension) else {
                report(.clipFileFailed(file: file, error: .assetNotFound("\(file).\(fileExtension)")))
                continue
            }
            files.append((file, url))
        }
        return adding(files, to: rig, reportingTo: report)
    }

    /// The clips from each file added to `rig` — the part both clip-file loads share, so they report
    /// the same things the same way.
    private static func adding(_ files: [(name: String, url: URL)],
                               to rig: Rig,
                               reportingTo report: (Warning) -> Void) -> Rig {
        var rig = rig
        for file in files {
            let loaded: [AnimationClip]
            do {
                loaded = try clips(url: file.url)
            } catch let error as RigLoaderError {
                report(.clipFileFailed(file: file.name, error: error))
                continue
            } catch {
                report(.clipFileFailed(file: file.name, error: .assetNotFound(file.url.path)))
                continue
            }
            guard !loaded.isEmpty else {
                report(.noAnimation(file: file.name))
                continue
            }
            let named = loaded.count == 1 ? [loaded[0].renamed(to: file.name)] : loaded
            let usable = named.filter { clip in
                guard rig.joints(notDrivenBy: clip).count == rig.skeleton.jointCount else { return true }
                report(.clipDrivesNoJoints(file: file.name, clip: clip.name))
                return false
            }
            rig = rig.adding(usable)
        }
        return rig
    }

    /// Reads **only** the animations out of a file, ignoring everything else in it.
    ///
    /// ### Ignoring the skeleton in a clip file is the whole point
    ///
    /// A per-clip export carries a full copy of the rig, and **its rest pose is not the rig's rest
    /// pose** — it is wherever the exporter happened to leave the skeleton, which is usually the
    /// clip's first frame. Measured on a real character: one joint's rest transform is
    /// (10.42, 4.08, 7.84) in the base file and (3.16, 1.17, 7.84) in the walk file, for the same
    /// joint of the same skeleton.
    ///
    /// So a loader that merges skeletons from clip files gets a different rest pose depending on
    /// which file it read last, and every joint a clip does *not* animate falls back to it. The
    /// character stands wrong, in a way that changes when you add an animation.
    ///
    /// **The rig comes from the base file. Clip files contribute clips and nothing else.**
    ///
    /// > **The mesh in those files is still parsed**, because Model I/O offers no way to open an
    /// > asset's animations alone. What this avoids is the expensive half — no vertex descriptor and
    /// > no buffer allocator, so nothing is laid out, converted or uploaded to a GPU.
    public static func clips(named name: String,
                             withExtension fileExtension: String,
                             bundle: Bundle) throws -> [AnimationClip] {
        try clips(url: url(of: name, withExtension: fileExtension, in: bundle))
    }

    /// The same, from a file anywhere on disk.
    public static func clips(url: URL) throws -> [AnimationClip] {
        try clips(in: openAsset(at: url), named: url.lastPathComponent)
    }

    private static func url(of name: String, withExtension fileExtension: String, in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw RigLoaderError.assetNotFound("\(name).\(fileExtension)")
        }
        return url
    }

    /// **A missing file is said here, rather than as "no skeleton" or no clips.** Model I/O opens a
    /// file that is not there as an empty asset, which is indistinguishable from a file with nothing in
    /// it — the same reason ``MeshLoader`` checks.
    private static func openAsset(at url: URL) throws -> MDLAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RigLoaderError.assetNotFound(url.path)
        }
        return MDLAsset(url: url)
    }

    /// Pulls the rig out of an already-open asset.
    ///
    /// Internal: Model I/O's types stay out of the engine's public API, and nothing outside it opened
    /// an asset to hand one in.
    static func rig(from asset: MDLAsset, named name: String = "asset") throws -> Rig {
        guard let mdlSkeleton = firstSkeleton(in: asset) else {
            throw RigLoaderError.noSkeleton(name)
        }

        // The geometry bind transform takes a vertex from the space it was modelled in into the
        // space the skeleton's bind transforms are measured in. Every export met so far has had it
        // identity; folding it into the inverse bind matrices costs one multiply at load and means
        // the shader never has to know it exists.
        var geometryBind: simd_float4x4?
        for mesh in meshes(in: asset) {
            guard let component = mesh.componentConforming(to: MDLComponent.self) as? MDLAnimationBindComponent,
                  component.skeleton === mdlSkeleton else { continue }
            let transform = float4x4(component.geometryBindTransform)
            if let existing = geometryBind, !simd_almost_equal_elements(existing, transform, 1e-5) {
                throw RigLoaderError.conflictingGeometryBindTransforms(name)
            }
            geometryBind = transform
        }

        let skeleton = try Skeleton(mdlSkeleton, geometryBindTransform: geometryBind ?? matrix_identity_float4x4)
        return Rig(skeleton: skeleton,
                   clips: try clips(in: asset, named: name),
                   nodeTransform: nodeTransform(of: mdlSkeleton, in: asset))
    }

    /// The skeleton bound to a mesh if there is one, otherwise the first in the hierarchy.
    ///
    /// The bind component is asked first because a file may carry several skeletons — a character
    /// and the rig of something it is holding — and the one the geometry points at is the one that
    /// matters. A file with a skeleton and no bound mesh is still readable, which is how an
    /// animation-only file loads.
    private static func firstSkeleton(in asset: MDLAsset) -> MDLSkeleton? {
        for mesh in meshes(in: asset) {
            if let component = mesh.componentConforming(to: MDLComponent.self) as? MDLAnimationBindComponent,
               let skeleton = component.skeleton {
                return skeleton
            }
        }
        var found: MDLSkeleton?
        walk(asset) { object in
            if found == nil, let skeleton = object as? MDLSkeleton { found = skeleton }
        }
        return found
    }

    /// The skeleton's own place in the file's node hierarchy.
    ///
    /// **Not decoration — see ``LoadedMesh/nodeTransform``.** An exported character's rig is in
    /// centimeters under a parent scaled by 0.01, and a loader that reads the joints and ignores the
    /// node chain produces a skeleton a hundred times too big for the world it is placed in.
    private static func nodeTransform(of skeleton: MDLSkeleton, in asset: MDLAsset) -> simd_float4x4 {
        var found = matrix_identity_float4x4
        var matched = false
        func descend(_ object: MDLObject, _ parent: simd_float4x4) {
            let world = object.transform.map { parent * $0.matrix } ?? parent
            if object === skeleton { found = world; matched = true }
            for child in object.children.objects where !matched { descend(child, world) }
        }
        for index in 0..<asset.count where !matched {
            descend(asset.object(at: index), matrix_identity_float4x4)
        }
        return found
    }

    private static func meshes(in asset: MDLAsset) -> [MDLMesh] {
        var result: [MDLMesh] = []
        walk(asset) { if let mesh = $0 as? MDLMesh { result.append(mesh) } }
        return result
    }

    private static func walk(_ asset: MDLAsset, _ visit: (MDLObject) -> Void) {
        func descend(_ object: MDLObject) {
            visit(object)
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }
    }

    /// Every clip in the file.
    ///
    /// **From `asset.animations`, which is not part of the object hierarchy.** Named by the last
    /// component of the animation's path, because `/Root/Walk` is where the clip lives and `Walk` is
    /// what a game asks for.
    static func clips(in asset: MDLAsset, named name: String) throws -> [AnimationClip] {
        guard let container = asset.animations as? MDLObjectContainer else { return [] }
        return try container.objects.compactMap { object in
            guard let packed = object as? MDLPackedJointAnimation else { return nil }
            do {
                return try AnimationClip(packed)
            } catch let error as AnimationClipError {
                throw RigLoaderError.malformedClip(name, clip: packed.name, error)
            }
        }
    }
}

/// Narrows Model I/O's doubles to the floats everything downstream uses. USD stores matrices as
/// doubles; a GPU has no use for them.
private nonisolated func float4x4(_ m: matrix_double4x4) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                              SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
}

nonisolated extension Skeleton {
    /// Builds a skeleton from Model I/O's, folding in the transform that takes the mesh into the
    /// skeleton's space.
    ///
    /// - Parameter geometryBindTransform: applied to a vertex *before* skinning, so it multiplies in
    ///   on the right of each inverse bind matrix. Identity in every export measured so far, which
    ///   is exactly why it is folded in here rather than left for a game to remember.
    init(_ skeleton: MDLSkeleton,
                geometryBindTransform: simd_float4x4 = matrix_identity_float4x4) throws {
        let rest = skeleton.jointRestTransforms.float4x4Array
        let bind = skeleton.jointBindTransforms.float4x4Array
        try self.init(jointPaths: skeleton.jointPaths,
                      restTransforms: rest,
                      bindTransforms: bind,
                      geometryBindTransform: geometryBindTransform)
    }
}

nonisolated extension AnimationClip {
    /// Bakes Model I/O's keyframes into the engine's own storage.
    ///
    /// **Copied out rather than held.** `MDLPackedJointAnimation` samples perfectly well, but it is
    /// a reference type that keeps the whole asset alive, it is not `Sendable`, and it cannot be
    /// constructed in a test without a file on disk. A clip is a few kilobytes of numbers; owning
    /// them is cheaper than any of that.
    ///
    /// **Times arrive in seconds.** Model I/O converts them from the file's time codes using its
    /// `timeCodesPerSecond`, so a clip authored over 24 frames at 24 fps reports a duration of 1 —
    /// nothing here has to know the file's frame rate.
    init(_ packed: MDLPackedJointAnimation) throws {
        let joints = packed.jointPaths
        let name = packed.name.split(separator: "/").last.map(String.init) ?? packed.name

        let translationTimes = packed.translations.times.map(Float.init)
        let rotationTimes = packed.rotations.times.map(Float.init)
        let scaleTimes = packed.scales.times.map(Float.init)

        try self.init(
            name: name,
            jointPaths: joints,
            translation: try JointTrack(times: translationTimes,
                                    values: translationTimes.flatMap {
                                        packed.translations.float3Array(atTime: Double($0))
                                    },
                                    jointCount: joints.count),
            rotation: try JointTrack(times: rotationTimes,
                                 values: rotationTimes.flatMap {
                                     packed.rotations.floatQuaternionArray(atTime: Double($0))
                                 },
                                 jointCount: joints.count),
            scale: try JointTrack(times: scaleTimes,
                              values: scaleTimes.flatMap {
                                  packed.scales.float3Array(atTime: Double($0))
                              },
                              jointCount: joints.count))
    }
}
