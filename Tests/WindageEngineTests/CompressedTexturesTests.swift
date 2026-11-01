import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import simd
@testable import WindageEngine

/// ASTC 4×4 copies of textures, made once and kept (``CompressedTextures``) — 2026-10-28.
@MainActor
struct CompressedTexturesTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "compressed-\(UUID().uuidString)")

    /// A PNG, RGB without alpha, mid-tone red over mid-tone blue — `width` by `height`.
    private func picture(_ width: Int, _ height: Int, top: CGColor, bottom: CGColor) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(bottom)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(top)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let url = folder.appending(path: "picture-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private let red = CGColor(srgbRed: 0.8, green: 0.35, blue: 0.2, alpha: 1)
    private let blue = CGColor(srgbRed: 0.25, green: 0.45, blue: 0.7, alpha: 1)

    /// The colour of a block in a cached file's first level, as the GPU reads it: the test's pictures are two flat halves,
    /// and an ASTC block of one colour is a "void-extent" block — FC FD, six FF, then R, G, B, A as 16-bit values. **Not
    /// decoded by ImageIO**, which writes a `.astc` bottom-up and flips it back when it reads one — a test through it
    /// passed an upside-down texture.
    private func block(_ ktx: URL, _ index: Int) throws -> SIMD3<Int> {
        let data = try Data(contentsOf: ktx)
        let at = 68 + index * 16   // the 64-byte header, the first level's size, then its blocks
        let bytes = [UInt8](data.subdata(in: at..<(at + 16)))
        #expect(bytes[0] == 0xFC && bytes[1] == 0xFD, "a flat block")
        func channel(_ i: Int) -> Int { Int(UInt16(bytes[8 + i * 2]) | UInt16(bytes[9 + i * 2]) << 8) >> 8 }
        return SIMD3(channel(0), channel(1), channel(2))
    }

    private func near(_ a: SIMD3<Int>, _ r: Int, _ g: Int, _ b: Int) -> Bool {
        max(abs(a.x - r), abs(a.y - g), abs(a.z - b)) <= 8
    }

    @Test func anImageBecomesASTCWithItsMipsTheSameWayUpAndTheSameColours() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try picture(512, 256, top: red, bottom: blue)
        let cache = folder.appending(path: "cache")
        let file = try CompressedTextures.prepare(url, isColor: true, origin: .bottomLeft, in: cache)
        // Bottom-left origin: the image's bottom (blue) is the file's first row; its top (red) the last.
        let blocksAcross = 512 / 4, blocksDown = 256 / 4
        let first = try block(file, 0), last = try block(file, blocksAcross * blocksDown - 1)
        #expect(near(first, 64, 115, 179), "first block row, the bottom: \(first)")
        #expect(near(last, 204, 89, 51), "last block row, the top: \(last)")
        // A top-left origin is the other way up.
        let topLeft = try CompressedTextures.prepare(url, isColor: true, origin: .topLeft, in: cache)
        let flippedFirst = try block(topLeft, 0)
        #expect(near(flippedFirst, 204, 89, 51), "top-left: the top first: \(flippedFirst)")

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let texture = try CompressedTextures.texture(fromKTX: file, device: device, queue: queue)
        #expect(texture.pixelFormat == .astc_4x4_srgb && texture.width == 512 && texture.height == 256)
        #expect(texture.mipmapLevelCount == 10, "512 × 256 down to 1 × 1")
        let data = try CompressedTextures.prepare(url, isColor: false, origin: .bottomLeft, in: cache)
        #expect(try CompressedTextures.texture(fromKTX: data, device: device, queue: queue).pixelFormat == .astc_4x4_ldr)
    }

    /// **A cut-out's mips keep its colour** (2026-11-01): a leaf sheet, opaque green columns between empty ones, halves to
    /// green at half coverage — never green times a half, which drew far trees nearly black.
    @Test func aCutOutsMipsKeepTheirColour() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.6, blue: 0.1, alpha: 1))
        for x in stride(from: 0, to: 64, by: 2) { context.fill(CGRect(x: x, y: 0, width: 1, height: 64)) }
        let url = folder.appending(path: "leaves.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let file = try CompressedTextures.prepare(url, isColor: true, in: folder.appending(path: "cache"))
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let texture = try CompressedTextures.texture(fromKTX: file, device: device, queue: queue)
        // Every level below the first, as the GPU reads it: green at half coverage, not green times a half.
        for level in 1..<4 {
            let (colour, alpha) = try average(texture, level: level, device: device, queue: queue)
            #expect(simd_distance(colour, SIMD3(0.25, 0.6, 0.1)) < 0.05, "level \(level): \(colour)")
            #expect(abs(alpha - 0.5) < 0.05, "level \(level): coverage \(alpha)")
        }
    }

    /// A level's average colour (sRGB, as stored) and alpha, read by a compute kernel — ASTC cannot be blitted out.
    private func average(_ texture: MTLTexture, level: Int, device: MTLDevice,
                         queue: MTLCommandQueue) throws -> (SIMD3<Float>, Float) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void readLevel(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]],
                              constant uint &level [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
            uint w = t.get_width(level);
            if (id.x >= w || id.y >= t.get_height(level)) return;
            out[id.y * w + id.x] = t.read(id, level);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "readLevel")))
        let width = max(texture.width >> level, 1), height = max(texture.height >> level, 1)
        let out = try #require(device.makeBuffer(length: width * height * 16, options: .storageModeShared))
        var index = UInt32(level)
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(out, offset: 0, index: 0)
        encoder.setBytes(&index, length: 4, index: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let texels = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: width * height)
        // The texture is sRGB, so the read is linear: back to sRGB to compare with the colour as painted.
        func encoded(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let sum = texels.reduce(SIMD4<Float>.zero, +) / Float(texels.count)
        return (SIMD3(encoded(sum.x), encoded(sum.y), encoded(sum.z)), sum.w)
    }

    @Test func aCachedTextureIsMadeOnceAndAChangedFileAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try picture(256, 256, top: red, bottom: blue)
        let cache = folder.appending(path: "cache")
        let first = try CompressedTextures.prepare(url, isColor: true, in: cache)
        let made = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        let again = try CompressedTextures.prepare(url, isColor: true, in: cache)
        let madeAgain = try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date
        #expect(again == first)
        #expect(madeAgain == made, "not made twice")
        // The file changes: a new copy, in the new colours.
        Thread.sleep(forTimeInterval: 1.1)
        let changed = try picture(256, 256, top: blue, bottom: red)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: changed, to: url)
        let remade = try CompressedTextures.prepare(url, isColor: true, in: cache)
        #expect(remade != first)
        let bottom = try block(remade, 0)
        #expect(near(bottom, 204, 89, 51), "the new bottom, red: \(bottom)")
    }

    /// **Keyed by contents**: the same file copied somewhere else — into a game's bundle — is the cache's same entry; other
    /// pixels, or the same file read as data, are not.
    @Test func aCopyElsewhereIsTheSameEntryAndOtherPixelsAreNot() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try picture(64, 64, top: red, bottom: blue)
        let elsewhere = folder.appending(path: "bundle/Props")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = elsewhere.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(try CompressedTextures.key(copy, isColor: true, origin: .bottomLeft, quality: .full)
                == CompressedTextures.key(url, isColor: true, origin: .bottomLeft, quality: .full))
        let other = try picture(64, 64, top: blue, bottom: red)
        #expect(try CompressedTextures.key(other, isColor: true, origin: .bottomLeft, quality: .full)
                != CompressedTextures.key(url, isColor: true, origin: .bottomLeft, quality: .full))
        #expect(try CompressedTextures.key(url, isColor: false, origin: .bottomLeft, quality: .full)
                != CompressedTextures.key(url, isColor: true, origin: .bottomLeft, quality: .full))
    }

    /// Asking whether a cache has a texture makes nothing; once made, it is found — from a copy anywhere (a copy keeps its
    /// name, which the cached file is named after).
    @Test func cachedFindsWithoutMaking() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try picture(64, 64, top: red, bottom: blue)
        let cache = folder.appending(path: "cache")
        #expect(CompressedTextures.cached(url, isColor: true, in: cache) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path), "nothing made")
        let made = try CompressedTextures.prepare(url, isColor: true, in: cache)
        let elsewhere = folder.appending(path: "bundle")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = elsewhere.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(CompressedTextures.cached(copy, isColor: true, in: cache) == made)
    }

    @Test func manyThreadsAskingForOneTextureMakeItOnce() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try picture(1024, 1024, top: red, bottom: blue)
        let cache = folder.appending(path: "cache")
        let results = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let file = try? CompressedTextures.prepare(url, isColor: true, in: cache)
            lock.withLock { results.add(file?.path ?? "") }
        }
        #expect(Set(results.compactMap { $0 as? String }).count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(files.count == 1, "\(files)")
    }

    @Test func theStoreLoadsThroughTheCacheAtItsQuality() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = try TextureStore(device: device)
        let url = try picture(512, 512, top: red, bottom: blue)
        store.compressionCache = folder.appending(path: "cache")
        let full = try store.texture(.url(url), isColor: true)
        #expect(full.pixelFormat == .astc_4x4_srgb && full.width == 512)
        store.quality = .half
        #expect(try store.texture(.url(url), isColor: true).width == 256)
        // A file it cannot compress loads as before.
        store.compressionCache = nil
        store.quality = .full
        #expect(try store.texture(.url(url), isColor: true).pixelFormat != .astc_4x4_srgb)
    }

    /// A texture made off the main thread and adopted is the one handed out — nothing loaded again.
    @Test func anAdoptedTextureIsTheOneHandedOut() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let store = try TextureStore(device: device)
        let url = try picture(64, 64, top: red, bottom: blue)
        let made = try CompressedTextures.texture(fromKTX: CompressedTextures.prepare(url, isColor: true, in: folder.appending(path: "cache")),
                                                  device: device, queue: queue)
        store.adopt(made, for: .url(url), isColor: true)
        #expect(try store.texture(.url(url), isColor: true) === made)
        #expect(try store.texture(.url(url), isColor: false) !== made, "read as data, it is another texture")
    }

    /// A new version's first file clears what older versions left — loose files from before the version folders, and an
    /// older version's folder — and touches nothing else in the folder (2026-11-01).
    @Test func makingAFileRemovesOlderVersionsAndNothingElse() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "cache")
        let manager = FileManager.default
        try manager.createDirectory(at: cache.appending(path: "astc4x4-v2"), withIntermediateDirectories: true)
        try Data([1]).write(to: cache.appending(path: "astc4x4-v2/old-0123.ktx"))
        try Data([1]).write(to: cache.appending(path: "Loose-4567.ktx"))
        try Data([1]).write(to: cache.appending(path: "notes.txt"))
        let made = try CompressedTextures.prepare(try picture(64, 64, top: red, bottom: blue), isColor: true, in: cache)
        #expect(made.deletingLastPathComponent().lastPathComponent == CompressedTextures.version)
        let left = Set(try manager.contentsOfDirectory(atPath: cache.path))
        #expect(left == [CompressedTextures.version, "notes.txt"], "\(left)")
        #expect(CompressedTextures.cached(made, isColor: true, in: cache) == nil, "a .ktx is not an image it compresses")
    }

    /// Sandboxed, an app's cache is its container's own; not sandboxed, it is in a folder named after the app — never
    /// loose in the user's Caches folder.
    @Test func anAppsCacheIsNamedForItOutsideTheSandbox() throws {
        let inside = try #require(CompressedTextures.appCache(named: "Compressed Textures", owner: "com.example.Game", sandboxed: true))
        let outside = try #require(CompressedTextures.appCache(named: "Compressed Textures", owner: "com.example.Game", sandboxed: false))
        #expect(inside.lastPathComponent == "Compressed Textures")
        #expect(outside.deletingLastPathComponent().lastPathComponent == "com.example.Game")
        #expect(outside.deletingLastPathComponent().deletingLastPathComponent() == inside.deletingLastPathComponent())
    }
}
