//
//  CompressedTextures.swift
//  WindageEngine
//

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal

/// **Textures compressed for the GPU — ASTC 4×4 — made once and kept in a cache folder.**
///
/// A texture loaded from a PNG is held uncompressed: four bytes a pixel, a third more for its mips. A 4096² atlas is
/// 85 MB that way, and 21 MB as ASTC 4×4, which every Apple GPU samples directly at the same resolution. The cost is the
/// encoding — about 1.5 s for that atlas and its mips — so it is done the first time a texture is asked for and the
/// result kept, keyed by the file's path, size and modification date and by how it is read; a changed file is
/// compressed again. Unity's import cache, for the same reason.
///
/// **macOS's own encoder.** ImageIO writes ASTC — but only into a `.astc` file, one image without mips; asked for KTX it
/// writes uncompressed pixels and ignores the request. So each mip level is made here, encoded on its own, and the levels
/// are written together as a **KTX 1.1** file, a format other tools read too.
///
/// **Safe from any thread**: a loader warms the cache in the background (``prepare(_:isColor:origin:quality:in:)``), and
/// ``TextureStore`` then reads the file on the main actor. Two threads asking for the same texture encode it once.
public nonisolated enum CompressedTextures {

    public enum CompressionError: Error, CustomStringConvertible {
        case unreadable(String)
        case encodingFailed(String)
        case notCompressedKTX(String)

        public var description: String {
            switch self {
            case .unreadable(let name): "\(name) is not an image ImageIO can read"
            case .encodingFailed(let name): "could not compress \(name) to ASTC"
            case .notCompressedKTX(let name): "\(name) is not an ASTC 4×4 KTX file"
            }
        }
    }

    /// The images this compresses: what ImageIO reads that a pack's materials name.
    public static let compressible: Set<String> = ["png", "jpg", "jpeg", "tga", "tif", "tiff", "bmp", "gif", "heic"]

    /// **The cached ASTC file for an image, made first if it is not there yet.** Blocks while another thread makes it.
    @discardableResult
    public static func prepare(_ url: URL, isColor: Bool, origin: TextureOrigin = .bottomLeft,
                               quality: GraphicsSettings.TextureQuality = .full, in cache: URL) throws -> URL {
        let file = try cache.appending(path: key(url, isColor: isColor, origin: origin, quality: quality) + ".ktx")
        while true {
            if FileManager.default.fileExists(atPath: file.path) { return file }
            if claim(file.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { release(file.path) }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let data = try encode(url, isColor: isColor, origin: origin, quality: quality)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The cache's name for a texture: its file as it is now, and how it is read. A version in it retires old files.
    static func key(_ url: URL, isColor: Bool, origin: TextureOrigin, quality: GraphicsSettings.TextureQuality) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let text = "astc4x4-v1|\(url.standardizedFileURL.path)|\(size)|\(modified)|\(isColor)|\(origin)|\(quality.reduction)"
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return url.deletingPathExtension().lastPathComponent + "-" + digest
    }

    // MARK: Encoding

    /// An image as a KTX file of ASTC 4×4 levels, the way up `origin` asks and at `quality`'s size.
    static func encode(_ url: URL, isColor: Bool, origin: TextureOrigin, quality: GraphicsSettings.TextureQuality) throws -> Data {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw CompressionError.unreadable(name) }
        let longest = max(width, height)
        let image: CGImage?
        if quality.reduction > 0, longest > TextureStore.smallestReduced {
            let target = max(longest >> quality.reduction, TextureStore.smallestReduced)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        // **ImageIO's ASTC encoder writes rows bottom-up** — an upright image's bottom row is the file's first block row,
        // which is what a texture's `v = 0` reads. So `.bottomLeft` is the image as it is, and `.topLeft` is flipped first.
        // (ImageIO flips back when it decodes a `.astc`, so checking a file with ImageIO cannot tell; the blocks can.)
        guard let image, var level = draw(image, width: image.width, height: image.height, flipped: origin == .topLeft)
        else { throw CompressionError.unreadable(name) }
        // Each level drawn from the one before, halving: what the GPU's own mip generation does, but filtered in the
        // image's sRGB rather than in linear light — invisible on an atlas of flat colours, slightly darker on fine
        // high-contrast detail far off.
        var levels: [(width: Int, height: Int, blocks: Data)] = []
        while true {
            guard let blocks = astc(level) else { throw CompressionError.encodingFailed(name) }
            levels.append((level.width, level.height, blocks))
            if level.width == 1 && level.height == 1 { break }
            guard let next = draw(level, width: max(level.width / 2, 1), height: max(level.height / 2, 1), flipped: false)
            else { throw CompressionError.encodingFailed(name) }
            level = next
        }
        return ktx(levels, isColor: isColor)
    }

    /// The image drawn into plain RGBA at a size — `flipped` puts its bottom row first.
    private static func draw(_ image: CGImage, width: Int, height: Int, flipped: Bool) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .high
        if flipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// One image's ASTC 4×4 blocks, by ImageIO — the `.astc` file's 16-byte header taken off.
    private static func astc(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "org.khronos.astc" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyASTCBlockSize: kCGImagePropertyASTCBlockSize4x4] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 16 else { return nil }
        let bytes = data as Data
        // The header: 13 AB A1 5C, then the block's size (4, 4, 1), then the size in pixels.
        guard bytes.prefix(4) == Data([0x13, 0xAB, 0xA1, 0x5C]), bytes[4] == 4, bytes[5] == 4 else { return nil }
        let blocks = bytes.dropFirst(16)
        guard blocks.count == ((image.width + 3) / 4) * ((image.height + 3) / 4) * 16 else { return nil }
        return Data(blocks)
    }

    // MARK: KTX 1.1

    private static let identifier: [UInt8] = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
    /// `GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR` and `GL_COMPRESSED_RGBA_ASTC_4x4_KHR`.
    static let srgbFormat: UInt32 = 0x93D0, linearFormat: UInt32 = 0x93B0

    private static func ktx(_ levels: [(width: Int, height: Int, blocks: Data)], isColor: Bool) -> Data {
        var out = Data(identifier)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        word(0x0403_0201)                               // endianness
        word(0); word(1); word(0)                       // glType, glTypeSize, glFormat: compressed
        word(isColor ? srgbFormat : linearFormat)       // glInternalFormat
        word(0x1908)                                    // glBaseInternalFormat: RGBA
        word(UInt32(levels[0].width)); word(UInt32(levels[0].height)); word(0)
        word(0); word(1)                                // array elements, faces
        word(UInt32(levels.count)); word(0)             // mip levels, key-value bytes
        for level in levels {
            word(UInt32(level.blocks.count))
            out.append(level.blocks)                    // a whole number of 16-byte blocks: already 4-aligned
        }
        return out
    }

    /// **A cached file as a texture**, its levels uploaded as they are — nothing decoded.
    public static func texture(fromKTX file: URL, device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let name = file.lastPathComponent
        // The header's thirteen words after the identifier: endianness 0, internal format 4, width 6, height 7, mip
        // levels 11, key-value bytes 12.
        func word(_ index: Int) -> UInt32? {
            let at = 12 + index * 4
            guard data.count >= at + 4 else { return nil }
            return data.subdata(in: at..<(at + 4)).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        guard data.count >= 64, Array(data.prefix(12)) == identifier, word(0) == 0x0403_0201,
              let format = word(4), format == srgbFormat || format == linearFormat,
              let width = word(6).map(Int.init), let height = word(7).map(Int.init), width > 0, height > 0,
              let levelCount = word(11).map(Int.init), levelCount > 0, let keyValues = word(12).map(Int.init)
        else { throw CompressionError.notCompressedKTX(name) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format == srgbFormat ? .astc_4x4_srgb : .astc_4x4_ldr, width: width, height: height,
            mipmapped: levelCount > 1)
        descriptor.mipmapLevelCount = levelCount
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        // Each level's blocks, found in the file. **Copied into the staging buffer at 16-byte boundaries**: Metal's
        // validation requires a copy of compressed blocks to start at a multiple of 16 — the file's first level starts at
        // 68 — and stops the app there (2026-10-28, found when run from Xcode; the tests now run under validation too).
        var levels: [(at: Int, size: Int, width: Int, height: Int, rowBytes: Int)] = []
        var at = 64 + keyValues
        for level in 0..<levelCount {
            guard data.count >= at + 4 else { throw CompressionError.notCompressedKTX(name) }
            let size = Int(data.subdata(in: at..<(at + 4)).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            at += 4
            let w = max(width >> level, 1), h = max(height >> level, 1)
            let rowBytes = ((w + 3) / 4) * 16
            guard size == rowBytes * ((h + 3) / 4), data.count >= at + size else { throw CompressionError.notCompressedKTX(name) }
            levels.append((at, size, w, h, rowBytes))
            at += size + (3 - (size + 3) % 4)
        }
        let aligned = levels.map { ($0.size + 15) / 16 * 16 }.reduce(0, +)
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(length: max(aligned, 16), options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { throw CompressionError.notCompressedKTX(name) }
        var offset = 0
        data.withUnsafeBytes { bytes in
            for (level, item) in levels.enumerated() {
                (staging.contents() + offset).copyMemory(from: bytes.baseAddress! + item.at, byteCount: item.size)
                blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: item.rowBytes, sourceBytesPerImage: item.size,
                          sourceSize: MTLSize(width: item.width, height: item.height, depth: 1), to: texture,
                          destinationSlice: 0, destinationLevel: level, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                offset += (item.size + 15) / 16 * 16
            }
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        texture.label = name
        return texture
    }

    // MARK: One encoder a texture

    private static let lock = NSLock()
    nonisolated(unsafe) private static var making: Set<String> = []

    private static func claim(_ path: String) -> Bool { lock.withLock { making.insert(path).inserted } }
    private static func release(_ path: String) { _ = lock.withLock { making.remove(path) } }
}
