//
//  TextureStoreTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import Metal
import ModelIO
import ImageIO
import CoreGraphics
import simd
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
        let texel = try Self.firstTexel(texture)
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

        let texel = try Self.firstTexel(top)
        #expect(texel[2] > texel[0], "a top-left origin should put the image's top row at v = 0")
    }

    /// The top-left texel, copied out by the GPU: a loaded texture is private, and **reading a private texture from the
    /// CPU is not allowed** — it happened to work until the suite ran under Metal's validation (2026-10-26).
    static func firstTexel(_ texture: MTLTexture) throws -> [UInt8] {
        let device = texture.device
        let buffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: 4), count: 4))
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

    /// A square PNG, red over blue, `size` pixels a side, written for the test — **RGB with no alpha**, as many asset packs' atlases
    /// are: ImageIO reduces such a file to XRGB, which is what turned a map's red rock blue.
    private func redOverBlue(_ size: Int) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // **Mid-tones, not primaries**: 0 and 255 come through any gamma curve unchanged, and a reduced image encoded as
        // sRGB twice — drawn washed out — passed a test of pure red and blue.
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.45, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))       // CG's y is up: the bottom half
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.35, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "red-over-blue-\(size)-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// **Below full quality an image is loaded smaller, the same way up** (2026-10-28), and a small one whole.
    @Test("Texture quality halves a large image, keeps a small one, and is the same way up")
    func textureQualityReducesLargeImages() throws {
        guard let store = try makeStore() else { return }
        let large = try redOverBlue(512), small = try redOverBlue(64)
        defer { try? FileManager.default.removeItem(at: large); try? FileManager.default.removeItem(at: small) }
        let full = try store.texture(.url(large), isColor: false)
        #expect(full.width == 512)
        store.quality = .half
        let half = try store.texture(.url(large), isColor: false)
        #expect(half !== full, "changing the quality forgets what was loaded")
        #expect(half.width == 256 && half.height == 256 && half.mipmapLevelCount > 1)
        // The same colour as the whole image's, channel for channel — each read as its own format says, since the loader
        // may store one BGRA and the other RGBA — blue, the bottom, at v = 0.
        func rgb(_ texture: MTLTexture) throws -> SIMD3<Int> {
            let t = try Self.firstTexel(texture).map(Int.init)
            let bgra = [.bgra8Unorm, .bgra8Unorm_srgb].contains(texture.pixelFormat)
            return bgra ? SIMD3(t[2], t[1], t[0]) : SIMD3(t[0], t[1], t[2])
        }
        let texel = try rgb(half), whole = try rgb(full)
        func apart(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
        #expect(apart(texel, whole) <= 2, "half \(texel), whole \(whole)")
        #expect(texel.z > texel.x + 60, "the bottom's blue, at v = 0: \(texel)")
        // Colour maps too, read as sRGB both ways.
        store.quality = .full
        let colourWhole = try rgb(try store.texture(.url(large), isColor: true))
        store.quality = .half
        let colourHalfTexture = try store.texture(.url(large), isColor: true)
        let colourHalf = try rgb(colourHalfTexture)
        // **Read as sRGB**, as the whole image is: raw bytes alike in a linear texture drew a whole map pale.
        #expect([.rgba8Unorm_srgb, .bgra8Unorm_srgb].contains(colourHalfTexture.pixelFormat))
        #expect(![.rgba8Unorm_srgb, .bgra8Unorm_srgb].contains(half.pixelFormat), "data, not colour, stays linear")
        #expect(apart(colourHalf, colourWhole) <= 2, "colour half \(colourHalf), whole \(colourWhole)")
        store.quality = .quarter
        #expect(try store.texture(.url(large), isColor: false).width == 128)
        #expect(try store.texture(.url(small), isColor: false).width == 64, "a small image stays whole")
    }
}
