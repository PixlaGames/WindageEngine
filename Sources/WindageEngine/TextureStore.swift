//
//  TextureStore.swift
//  WindageEngine
//

import Foundation
import Metal
import MetalKit
import simd

public enum TextureStoreError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case loadFailed(String, underlying: any Error)
    case fallbackUnavailable

    public var description: String {
        switch self {
        case .notFound(let name): "no texture named \(name) in the bundle"
        case .loadFailed(let name, let underlying): "could not load \(name) — \(underlying)"
        case .fallbackUnavailable: "the device would not allocate a 1×1 fallback texture"
        }
    }
}

/// Which corner of the image the mesh's `v = 0` is meant to land on.
///
/// ### The flip, and why the engine owns it
///
/// **Metal puts texture coordinate (0, 0) at an image's top-left. USD and OBJ put `st` (0, 0) at
/// its bottom-left.** Something has to reconcile those, exactly once, and if it is not the engine
/// then it is every game — and the failure is silent on any texture that happens to be roughly
/// symmetrical, which is most of them.
///
/// **It was found on a character whose texture is a palette.** Its color map is a 32×32 grid of
/// swatches with a magenta row along the bottom, so a vertical flip does not soften an edge — it
/// hands a limb a completely different color. The sample's own crate, stone and ground textures
/// had been flipped the whole time and looked fine, because noise and brickwork read the same
/// upside down.
///
/// Every format Model I/O reads — USD, USDZ, OBJ, PLY, STL, Alembic — puts `v = 0` at the bottom,
/// so ``bottomLeft`` is the default. ``topLeft`` is here for glTF-derived UVs, which are the other
/// way round, and for anything a game generates itself.
public nonisolated enum TextureOrigin: Sendable, Hashable {
    /// `v = 0` is the bottom of the image: the convention of everything Model I/O imports.
    case bottomLeft
    /// `v = 0` is the top of the image: glTF's convention, and Metal's own.
    case topLeft

    var loaderOrigin: MTKTextureLoader.Origin {
        self == .bottomLeft ? .bottomLeft : .topLeft
    }
}

/// Loads textures once and hands the same one back after that.
///
/// **The GPU half of ``Material``**, split off for the same reason `RigLoader` is split from
/// `MeshLoader`: reading what a material *says* needs no device, and turning that into memory on a
/// GPU does. Everything with a convention in it lives on the other side of that line and is
/// testable; this side is a cache and a loader.
///
/// ### The cache is the point, not a nicety
///
/// A scene's meshes share their maps — every crate in a level names the same file. Loading it per
/// mesh costs the decode, the upload and the mipmap generation each time, and then holds N copies of
/// the same texture in GPU memory. Keyed by file **and by how it is being read**, because the same
/// image genuinely can be wanted both ways.
///
/// ### Main-actor, deliberately
///
/// It holds mutable state, and textures are loaded while a level loads rather than from a render
/// thread. Making it `nonisolated` would buy background loading at the price of locking the cache,
/// and nothing here has asked for that yet.
public final class TextureStore {

    private struct Key: Hashable {
        let source: TextureSource
        let isColor: Bool
        let origin: TextureOrigin
    }

    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private var cache: [Key: MTLTexture] = [:]

    /// A 1×1 opaque white, for binding where a material has no map.
    ///
    /// **So that a shader can always sample.** The alternative is a shader that branches on whether
    /// a texture exists, or a second pipeline compiled without it — one costs a branch per fragment
    /// and the other doubles the pipelines in the game. White multiplies to nothing, so the
    /// material's own color comes through untouched.
    public let white: MTLTexture

    /// A 1×1 flat normal — (0.5, 0.5, 1) — meaning "no perturbation".
    ///
    /// Not the same fallback as ``white``: a white pixel decodes to the normal (1, 1, 1), which
    /// tilts every surface diagonally and lights the whole scene wrongly.
    public let flatNormal: MTLTexture

    /// - Throws: ``TextureStoreError/fallbackUnavailable`` when the device will not make the 1×1
    ///   fallbacks.
    public init(device: MTLDevice) throws {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
        guard let white = TextureStore.makePixel(device: device, color: SIMD4(255, 255, 255, 255),
                                                 label: "White 1×1"),
              let normal = TextureStore.makePixel(device: device, color: SIMD4(128, 128, 255, 255),
                                                  label: "Flat Normal 1×1") else {
            throw TextureStoreError.fallbackUnavailable
        }
        self.white = white
        self.flatNormal = normal
    }

    private static func makePixel(device: MTLDevice, color: SIMD4<UInt8>, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        // Shared rather than private: it is four bytes, and `replace(region:)` on a private texture
        // would need a blit and a command buffer at start-up for nothing.
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        var pixel = color
        withUnsafeBytes(of: &pixel) { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }

    /// The fallback for a slot that a material does not fill.
    public func fallback(for slot: TextureSlot) -> MTLTexture {
        slot == .normal ? flatNormal : white
    }

    /// Loads a texture, or returns the one already loaded.
    ///
    /// - Parameter isColor: whether to decode sRGB on the way in. Take it from
    ///   ``TextureSlot/isColor`` rather than deciding per call site — that is the whole reason it is
    ///   a property of the slot.
    /// - Parameter origin: which corner the mesh's `v = 0` means. Leave it alone for anything loaded
    ///   through ``MeshLoader`` — see ``TextureOrigin``.
    @discardableResult
    public func texture(_ source: TextureSource,
                        isColor: Bool,
                        origin: TextureOrigin = .bottomLeft,
                        bundle: Bundle = .main) throws -> MTLTexture {
        let key = Key(source: source, isColor: isColor, origin: origin)
        if let cached = cache[key] { return cached }

        let url: URL
        switch source {
        case .url(let value):
            url = value
        case .named(let name):
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let found = bundle.url(forResource: stem, withExtension: ext.isEmpty ? nil : ext) else {
                throw TextureStoreError.notFound(name)
            }
            url = found
        }

        // **Mipmaps are not optional for anything seen at an angle.** A ground plane sampled at one
        // level aliases into a shimmering mess as the camera moves, and it is the single most
        // obvious difference between "textured" and "textured properly".
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .generateMipmaps: NSNumber(value: true),
            .SRGB: NSNumber(value: isColor),
            // Flips the image on the way in, so a bottom-left `v` lands where the file meant it to.
            .origin: origin.loaderOrigin.rawValue,
        ]

        do {
            let texture = try loader.newTexture(URL: url, options: options)
            texture.label = url.lastPathComponent
            cache[key] = texture
            return texture
        } catch {
            throw TextureStoreError.loadFailed(url.lastPathComponent, underlying: error)
        }
    }

    /// Every map a material names, with anything missing or unloadable filled in by ``fallback(for:)``.
    ///
    /// **Never throws.** A missing texture should draw the object in a plain color and say so once,
    /// not stop a level loading — a level that will not open because one map is misspelled is a
    /// worse failure than a crate that is the wrong shade.
    public func textures(for material: Material,
                         origin: TextureOrigin = .bottomLeft,
                         bundle: Bundle = .main,
                         reportingTo report: ((String) -> Void)? = nil) -> [TextureSlot: MTLTexture] {
        var result: [TextureSlot: MTLTexture] = [:]
        for slot in TextureSlot.allCases {
            guard let source = material.textures[slot] else {
                result[slot] = fallback(for: slot)
                continue
            }
            do {
                result[slot] = try texture(source, isColor: slot.isColor, origin: origin, bundle: bundle)
            } catch {
                report?("material '\(material.name)' \(slot.rawValue): \(error)")
                result[slot] = fallback(for: slot)
            }
        }
        return result
    }

    /// Everything loaded so far, for the residency set.
    ///
    /// **A texture the GPU cannot reach is not a black object — it is garbage that looks like a
    /// shader bug.** Call this after loading a level's materials and commit residency.
    public var allocations: [any MTLAllocation] { Array(cache.values) + [white, flatNormal] }
}
