//
//  RigLoaderTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import ModelIO
import simd
@testable import WindageEngine

/// Loading a rig from a real USD file, with no GPU and no window.
///
/// **That this is possible at all is the reason ``RigLoader`` is separate from ``MeshLoader``.**
/// Geometry needs a device; a skeleton and a clip are numbers. Split there, everything with a
/// convention in it — which space a transform is in, where a clip lives, whether a joint path
/// survives — is checked by `swift test` against a file somebody can read.
@MainActor
struct RigLoaderTests {

    private func loadRig() throws -> Rig {
        try RigLoader.load(named: "offset-rig", withExtension: "usda", bundle: .module)
    }

    @Test("Model I/O imports UsdSkel — joints, both transform arrays and the hierarchy")
    func skeletonComesThrough() throws {
        let rig = try loadRig()
        #expect(rig.skeleton.jointPaths == ["root", "root/mid"])
        #expect(rig.skeleton.parentIndices == [nil, 0])
    }

    /// **The finding this fixture exists for.** Rest transforms are joint-local, bind transforms are
    /// skeleton-space, and nothing in the API says so. Read them alike and a character collapses
    /// toward the origin or flies apart, depending which way round the mistake went.
    @Test("Rest and bind transforms arrive in different spaces")
    func restAndBindAreDifferentSpaces() throws {
        let skeleton = try loadRig().skeleton
        #expect(simd_distance(skeleton.restTransforms[1].columns.3, SIMD4(0, 1, 0, 1)) < 1e-5)
        let bind = simd_inverse(skeleton.inverseBindTransforms[1])
        #expect(simd_distance(bind.columns.3, SIMD4(5, 1, 0, 1)) < 1e-5)
    }

    /// Clips are not in the object hierarchy — they come from `MDLAsset.animations`, a container of
    /// its own. Walk the objects looking for one and every character is a statue.
    @Test("Clips are found, named by their last path component")
    func clipsAreFound() throws {
        let rig = try loadRig()
        #expect(rig.clips.count == 1)
        #expect(rig.clip(named: "Swing") != nil)
    }

    /// Times come back in seconds, converted from the file's time codes. The fixture runs 24 frames
    /// at 24 fps, so nothing downstream has to know the file's frame rate.
    @Test("Keyframe times are seconds, not frames")
    func timesAreSeconds() throws {
        let clip = try #require(loadRig().clip(named: "Swing"))
        #expect(abs(clip.duration - 1) < 1e-5)
        #expect(clip.rotation.times.count == 3)
        #expect(abs(clip.rotation.times[1] - 0.5) < 1e-5)
    }

    /// The end-to-end check: a file on disk poses a rig, and the joint lands where the file says.
    @Test("A loaded clip poses a loaded skeleton")
    func loadedClipPosesLoadedRig() throws {
        let rig = try loadRig()
        let clip = try #require(rig.clip(named: "Swing"))
        var pose = SkeletonPose(skeleton: rig.skeleton)

        var playhead = AnimationPlayhead(clip: clip, skeleton: rig.skeleton)
        #expect(playhead.binding.unboundJoints.isEmpty)

        playhead.advance(by: 0.5)                       // the quarter-turn key
        pose.set(to: playhead)

        // The child joint is at (5, 1, 0); a vertex a metre above it swings round to (4, 1, 0).
        let skinned = pose.skinningMatrices[1] * SIMD4<Float>(5, 2, 0, 1)
        #expect(simd_distance(SIMD3(skinned.x, skinned.y, skinned.z), SIMD3(4, 1, 0)) < 1e-4)
    }

    @Test("At rest, a loaded rig skins to where it was modelled")
    func loadedRestPoseIsIdentity() throws {
        let pose = SkeletonPose(skeleton: try loadRig().skeleton)
        for matrix in pose.skinningMatrices {
            #expect(simd_almost_equal_elements(matrix, matrix_identity_float4x4, 1e-5))
        }
    }

    @Test("A file with no skeleton says so rather than loading a statue")
    func noSkeletonThrows() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("windage-no-skeleton-\(UUID().uuidString).usda")
        try """
        #usda 1.0
        def Mesh "Box"
        {
            point3f[] points = [(0,0,0), (1,0,0), (1,1,0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0,1,2]
        }
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RigLoaderError.self) {
            try RigLoader.rig(from: MDLAsset(url: url), named: url.lastPathComponent)
        }
    }

    /// **The defect this fixture's scaled root exists for, found by loading a real character.** An
    /// exported rig sits under a node that converts its centimetres to metres, and a loader that
    /// reads the joints while ignoring the node chain produces a skeleton a hundred times too big
    /// for the world it is placed in — which looks like a broken asset rather than a broken loader.
    @Test("The rig's place in the file's node hierarchy is reported")
    func nodeTransformIsComposed() throws {
        let rig = try loadRig()
        let scale = simd_length(SIMD3(rig.nodeTransform.columns.0.x,
                                      rig.nodeTransform.columns.0.y,
                                      rig.nodeTransform.columns.0.z))
        #expect(abs(scale - 0.01) < 1e-6, "the node chain above the skeleton was ignored")
    }

    /// The joints themselves stay in the space the file wrote them in. **Both halves are needed**:
    /// the node transform goes in front of the model matrix, and correcting the joints as well would
    /// apply it twice.
    @Test("The node transform is not baked into the joints")
    func jointsStayInTheirOwnSpace() throws {
        let skeleton = try loadRig().skeleton
        #expect(simd_distance(skeleton.restTransforms[1].columns.3, SIMD4(0, 1, 0, 1)) < 1e-5)
    }

    @Test("Clips added from another file keep the rig's node transform")
    func addingClipsKeepsTheNodeTransform() throws {
        let rig = try loadRig()
        #expect(rig.adding([]).nodeTransform == rig.nodeTransform)
    }

    // MARK: - Clips in files of their own

    /// **The shape a real character actually arrives in.** Every toolchain that exports one animation
    /// at a time gives a file per clip, and each carries a whole copy of the mesh and the skeleton.
    @Test("Clips load from a second file onto the first file's rig")
    func clipsLoadFromAnotherFile() throws {
        let rig = try RigLoader.load(named: "offset-rig", withExtension: "usda",
                                     clipFiles: ["offset-rig-walk"], bundle: .module)
        #expect(rig.clips.count == 2)
        #expect(rig.clip(named: "Swing") != nil)
        // A file with one clip has it renamed to the file's own name — an exporter's internal name
        // for an animation is not something a game wants to ask for.
        #expect(rig.clip(named: "offset-rig-walk") != nil)
        #expect(rig.joints(notDrivenBy: try #require(rig.clip(named: "offset-rig-walk"))).isEmpty)
    }

    /// **The trap this fixture exists for.** The walk file's copy of the skeleton has the child joint
    /// at (0, 9, 0) where the rig says (0, 1, 0) — because a clip file's rest pose is wherever the
    /// exporter left the rig, not the rig's own. Merge it and every joint the clip does not animate
    /// stands in the wrong place, and the fault changes depending on which files were loaded.
    @Test("A clip file's own skeleton is ignored")
    func clipFileSkeletonIsIgnored() throws {
        let rig = try RigLoader.load(named: "offset-rig", withExtension: "usda",
                                     clipFiles: ["offset-rig-walk"], bundle: .module)
        #expect(simd_distance(rig.skeleton.restTransforms[1].columns.3, SIMD4(0, 1, 0, 1)) < 1e-5,
                "the rest pose came from a clip file")

        let pose = SkeletonPose(skeleton: rig.skeleton)
        for matrix in pose.skinningMatrices {
            #expect(simd_almost_equal_elements(matrix, matrix_identity_float4x4, 1e-5))
        }
    }

    @Test("Clips can be read on their own")
    func clipsAloneCanBeRead() throws {
        let clips = try RigLoader.clips(named: "offset-rig-walk", withExtension: "usda", bundle: .module)
        #expect(clips.count == 1)
        #expect(clips[0].jointPaths == ["root", "root/mid"])
    }

    @Test("A clip can be renamed without changing anything else")
    func renamingKeepsTheClip() throws {
        let clip = try #require(loadRig().clip(named: "Swing"))
        let renamed = clip.renamed(to: "swing")
        #expect(renamed.name == "swing")
        #expect(renamed.duration == clip.duration)
        #expect(renamed.jointPaths == clip.jointPaths)
        #expect(renamed.rotation.times == clip.rotation.times)
    }

    /// A clip file that is missing is reported, not thrown — one absent animation should not stop a
    /// character loading.
    @Test("A missing clip file is reported rather than fatal")
    func missingClipFileIsReported() throws {
        var reports: [RigLoader.Warning] = []
        let rig = try RigLoader.load(named: "offset-rig", withExtension: "usda",
                                     clipFiles: ["no-such-clip"], bundle: .module) {
            reports.append($0)
        }
        #expect(rig.clips.count == 1, "the base file's own clip should still be there")
        #expect(reports == [.clipFileFailed(file: "no-such-clip", error: .assetNotFound("no-such-clip.usda"))])
    }

    /// **An engine that can only load from its own bundle cannot load anything a person chose** — a
    /// level editor opening a mesh, a mod, a character sitting in a pipeline's output folder. This
    /// gap existed until something outside the repository was actually loaded.
    @Test("A rig loads from a URL, not only from a bundle")
    func rigLoadsFromAURL() throws {
        let url = try #require(Bundle.module.url(forResource: "offset-rig", withExtension: "usda"))
        let rig = try RigLoader.load(url: url)
        #expect(rig.skeleton.jointPaths == ["root", "root/mid"])
        #expect(rig.clip(named: "Swing") != nil)
    }

    @Test("Clip files load by URL and are named from their own stems")
    func clipsLoadFromURLs() throws {
        let base = try #require(Bundle.module.url(forResource: "offset-rig", withExtension: "usda"))
        let walk = try #require(Bundle.module.url(forResource: "offset-rig-walk", withExtension: "usda"))
        let rig = try RigLoader.load(url: base, clipURLs: [walk])
        #expect(rig.clips.count == 2)
        #expect(rig.clip(named: "offset-rig-walk") != nil)
    }

    /// `MDLAsset(url:)` logs and hands back an empty asset rather than throwing, so a missing clip
    /// file would be one that contributed nothing — said as missing, **the same as the bundle form
    /// says it**, since silence here is a character that simply never plays that move.
    @Test("A missing clip URL is reported as missing, not fatal")
    func unreadableClipURLIsReported() throws {
        let base = try #require(Bundle.module.url(forResource: "offset-rig", withExtension: "usda"))
        let missing = base.deletingLastPathComponent().appendingPathComponent("not-here.usdc")
        var reports: [RigLoader.Warning] = []
        let rig = try RigLoader.load(url: base, clipURLs: [missing]) { reports.append($0) }
        #expect(rig.clips.count == 1)
        #expect(reports == [.clipFileFailed(file: "not-here", error: .assetNotFound(missing.path))])
    }

    @Test("A missing file is named in the error")
    func missingFileThrows() {
        #expect(throws: RigLoaderError.assetNotFound("no-such-rig.usda")) {
            try RigLoader.load(named: "no-such-rig", withExtension: "usda", bundle: .module)
        }
    }

    /// It used to come back as "no skeleton", which sends someone looking inside a file that is not
    /// there.
    @Test("A missing file by URL is missing, not a file with no skeleton")
    func missingURLThrowsNotFound() throws {
        let base = try #require(Bundle.module.url(forResource: "offset-rig", withExtension: "usda"))
        let missing = base.deletingLastPathComponent().appendingPathComponent("not-here.usdc")
        #expect(throws: RigLoaderError.assetNotFound(missing.path)) { try RigLoader.load(url: missing) }
        #expect(throws: RigLoaderError.assetNotFound(missing.path)) { try RigLoader.clips(url: missing) }
    }
}
