//
//  TextureStoreTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import Metal
import ModelIO
@testable import WindageEngine

/// The GPU half of materials.
///
/// **These need a device, which is why there are only a few of them.** A Metal device can be created
/// without a window, so a cache and a pixel format are checkable here; anything needing a compiled
/// shader is not, because `swift build` compiles no Metal at all. Everything with a convention in it
/// lives in `Material` instead, and is tested without any of this.
@MainActor
struct TextureStoreTests {

    /// Skipped rather than failed on a machine with no Metal device — a headless builder should not
    /// report a red suite for hardware it does not have.
    private func makeStore() throws -> TextureStore? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try TextureStore(device: device)
    }

    private var mapURL: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "material-map", withExtension: "png"))
        }
    }

    @Test("The same file is loaded once")
    func cacheReturnsTheSameTexture() throws {
        guard let store = try makeStore() else { return }
        let first = try store.texture(.url(try mapURL), isColor: true)
        let second = try store.texture(.url(try mapURL), isColor: true)
        #expect(first === second)
    }

    /// The same image genuinely can be wanted both ways — a map used as colour on one material and
    /// as a mask on another — so the cache key has to carry the decision, not just the file.
    @Test("Colour and data readings of one file are different textures")
    func cacheKeyIncludesTheColorDecision() throws {
        guard let store = try makeStore() else { return }
        let color = try store.texture(.url(try mapURL), isColor: true)
        let data = try store.texture(.url(try mapURL), isColor: false)
        #expect(color !== data)
        #expect(color.pixelFormat != data.pixelFormat, "one of these was not decoded as sRGB")
    }

    @Test("Mipmaps are generated")
    func texturesHaveMipmaps() throws {
        guard let store = try makeStore() else { return }
        let texture = try store.texture(.url(try mapURL), isColor: true)
        #expect(texture.mipmapLevelCount > 1, "a ground plane without mips shimmers as you walk")
    }

    /// A white pixel decodes to the normal (1, 1, 1), which tilts every surface diagonally and lights
    /// the whole scene wrongly. The two fallbacks are not interchangeable.
    @Test("The normal fallback is not the white one")
    func normalFallbackIsFlatNotWhite() throws {
        guard let store = try makeStore() else { return }
        #expect(store.fallback(for: .normal) === store.flatNormal)
        #expect(store.fallback(for: .baseColor) === store.white)
        #expect(store.flatNormal !== store.white)
    }

    /// A level that will not open because one map is misspelled is a worse failure than a crate that
    /// is the wrong shade.
    @Test("A material naming a missing file still gets a full set of textures")
    func missingTextureFallsBackAndReports() throws {
        guard let store = try makeStore() else { return }
        var material = Material(name: "broken")
        material.textures[.baseColor] = .named("no-such-file.png")

        var reports: [String] = []
        let resolved = store.textures(for: material, bundle: .module) { reports.append($0) }

        #expect(resolved.count == TextureSlot.allCases.count)
        #expect(resolved[.baseColor] === store.white)
        #expect(reports.count == 1)
    }

    /// **The flip, pinned.** Metal puts texture (0, 0) at an image's top-left; USD and OBJ put
    /// `st` (0, 0) at its bottom-left. Load without reconciling them and every textured asset is
    /// upside down — silently, on anything roughly symmetrical, which is most textures. It took a
    /// character whose texture is a palette of swatches to make it visible.
    ///
    /// The fixture is red on top and blue on the bottom precisely because the suite's other images
    /// are noise and brickwork, which read the same either way up.
    @Test("v = 0 lands on the bottom of the image, as every format Model I/O reads intends")
    func defaultOriginIsBottomLeft() throws {
        guard let store = try makeStore() else { return }
        let url = try #require(Bundle.module.url(forResource: "red-top-blue-bottom",
                                                 withExtension: "png"))
        let texture = try store.texture(.url(url), isColor: false)

        // Texture row 0 is what `v = 0` samples.
        var texel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&texel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let red = texel[2], blue = texel[0]        // BGRA
        #expect(blue > red, "v = 0 sampled the top of the image; every USD and OBJ asset is flipped")
    }

    /// glTF's UVs are the other way round, so the flip has to be refusable.
    @Test("A top-left origin is available and is a different texture")
    func topLeftOriginIsAvailable() throws {
        guard let store = try makeStore() else { return }
        let url = try #require(Bundle.module.url(forResource: "red-top-blue-bottom",
                                                 withExtension: "png"))
        let bottom = try store.texture(.url(url), isColor: false, origin: .bottomLeft)
        let top = try store.texture(.url(url), isColor: false, origin: .topLeft)
        #expect(bottom !== top, "the cache key does not include the origin")

        var texel = [UInt8](repeating: 0, count: 4)
        top.getBytes(&texel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        #expect(texel[2] > texel[0], "a top-left origin should put the image's top row at v = 0")
    }

    @Test("Everything loaded is offered to the residency set")
    func allocationsIncludeLoadedTextures() throws {
        guard let store = try makeStore() else { return }
        let texture = try store.texture(.url(try mapURL), isColor: true)
        #expect(store.allocations.contains { ($0 as? MTLTexture) === texture })
        #expect(store.allocations.contains { ($0 as? MTLTexture) === store.white })
    }

    /// **A texture packed in a `.usdz` used to draw white** (2026-10-22): Model I/O gave the package's own URL,
    /// which no image loader opens, and the fallback was drawn. The entry now rides as the URL's fragment.
    @Test("A texture inside a .usdz is read out of the package")
    func textureInsideAUSDZ() throws {
        guard let store = try makeStore() else { return }
        let url = try #require(Bundle.module.url(forResource: "textured-quad-packed", withExtension: "usdz"))
        let asset = MDLAsset(url: url)
        var found: MDLMaterial?
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                for submesh in (mesh.submeshes as? [MDLSubmesh] ?? []) where found == nil { found = submesh.material }
            }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }
        let material = Material(try #require(found))
        let source = try #require(material.textures[.baseColor])
        guard case .url(let packed) = source else { Issue.record("expected a URL"); return }
        #expect(packed.pathExtension == "usdz")
        #expect(packed.fragment(percentEncoded: false) == "textures/material-map.png")

        let texture = try store.texture(source, isColor: true)
        #expect(texture.width == 256 && texture.height == 256, "the map is 256 px square; the fallback is 1")

        // The package itself, without the entry, is not an image — what was drawn white before.
        var bare = URLComponents(url: packed, resolvingAgainstBaseURL: false)!
        bare.fragment = nil
        #expect(throws: (any Error).self) { try store.texture(.url(bare.url!), isColor: true) }
    }

    /// A damaged package is refused, never read past its end: every byte count cut short in turn.
    @Test("A truncated .usdz is refused, not read past its end")
    func truncatedUSDZIsRefused() throws {
        let url = try #require(Bundle.module.url(forResource: "textured-quad-packed", withExtension: "usdz"))
        let whole = try Data(contentsOf: url)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cut = folder.appending(path: "cut.usdz")
        for length in stride(from: 0, to: whole.count, by: 97) {
            try whole.prefix(length).write(to: cut)
            #expect(throws: (any Error).self) { try USDZArchive.entry("textures/material-map.png", in: cut) }
        }
        // And a central directory whose name runs past the end of the file.
        var bent = whole
        if let end = (0...(bent.count - 22)).reversed().first(where: { bent[$0] == 0x50 && bent[$0+1] == 0x4B && bent[$0+2] == 5 && bent[$0+3] == 6 }) {
            let directory = Int(bent[end+16]) | Int(bent[end+17]) << 8 | Int(bent[end+18]) << 16 | Int(bent[end+19]) << 24
            bent[directory + 28] = 0xFF; bent[directory + 29] = 0xFF
            try bent.write(to: cut)
            #expect(throws: (any Error).self) { try USDZArchive.entry("textures/material-map.png", in: cut) }
        }
    }

    @Test("Forgetting a file loads it afresh, packed textures included, and leaves others cached")
    func forgettingAFile() throws {
        guard let store = try makeStore() else { return }
        let map = try mapURL
        let package = try #require(Bundle.module.url(forResource: "textured-quad-packed", withExtension: "usdz"))
        var packed = URLComponents(url: package, resolvingAgainstBaseURL: false)!
        packed.fragment = "textures/material-map.png"
        let before = try store.texture(.url(packed.url!), isColor: true)
        let other = try store.texture(.url(map), isColor: true)
        store.forget(file: package)
        #expect(try store.texture(.url(packed.url!), isColor: true) !== before)
        #expect(try store.texture(.url(map), isColor: true) === other)
    }
}
