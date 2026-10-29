import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
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
}
