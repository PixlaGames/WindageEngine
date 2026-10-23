//
//  ImportedModel.swift
//  WindageEngine
//

import Basis
import CoreGraphics
import Foundation
import ImageIO
import simd

/// A model read from a file, as plain values: meshes, the materials they use, and their images.
///
/// **What a format reader produces, and nothing more.** The glTF reader makes one; so can a game's or a
/// tool's own reader of a format the engine does not read — an FBX one, say. `MeshLoader` turns one into
/// meshes to draw, and a tool can write one out as another format, which Model I/O cannot do with textures:
/// its USD exporter drops every one (measured 2026-10-14). Extracted from a character-creator app's model, with the
/// rig left out, because a prop has none.
///
/// **Conventions, fixed so every reader means the same thing:** metres, Y up, counter-clockwise front faces;
/// texture coordinates with v running *down* the image, as glTF and Metal have it; colours linear.
public nonisolated struct ImportedModel: Sendable {
    public var meshes: [ImportedMesh]
    public var materials: [ImportedMaterial]

    public init(meshes: [ImportedMesh] = [], materials: [ImportedMaterial] = []) {
        self.meshes = meshes
        self.materials = materials
    }

    /// Every image the materials use, each once.
    public var textures: [ImportedTexture] {
        var seen = Set<ObjectIdentifier>()
        return materials.flatMap(\.textures).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The box round every mesh, in model space — each mesh's points placed by its transform.
    public var bounds: BoundingBox? {
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for mesh in meshes {
            for point in mesh.positions {
                let placed = mesh.transform * SIMD4(point, 1)
                low = simd_min(low, SIMD3(placed.x, placed.y, placed.z))
                high = simd_max(high, SIMD3(placed.x, placed.y, placed.z))
            }
        }
        return low.x <= high.x ? BoundingBox(minimum: low, maximum: high) : nil
    }
}

/// One mesh: its vertices, where it sits, and its triangles grouped by material.
public nonisolated struct ImportedMesh: Sendable {
    /// The mesh's name in the file, for a person to recognise.
    public var name: String
    /// Where the mesh sits in the model: its node's transform composed from the file's root.
    public var transform: simd_float4x4
    public var positions: [SIMD3<Float>]
    /// One per vertex, or empty when the file has none and they are to be made from the faces.
    public var normals: [SIMD3<Float>]
    /// The first set of texture coordinates, one per vertex, v running down the image. Empty for none.
    public var uvs: [SIMD2<Float>]
    /// Linear RGBA vertex colours, one per vertex, or empty.
    public var colors: [SIMD4<Float>]
    public var submeshes: [ImportedSubmesh]

    public init(name: String = "", transform: simd_float4x4 = matrix_identity_float4x4,
                positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [],
                colors: [SIMD4<Float>] = [], submeshes: [ImportedSubmesh]) {
        self.name = name
        self.transform = transform
        self.positions = positions
        self.normals = normals
        self.uvs = uvs
        self.colors = colors
        self.submeshes = submeshes
    }
}

/// Triangles drawn with one material: three indices into the mesh's vertices per triangle.
public nonisolated struct ImportedSubmesh: Sendable {
    public var indices: [UInt32]
    /// Index into the model's `materials`, or nil for none.
    public var material: Int?

    public init(indices: [UInt32], material: Int? = nil) {
        self.indices = indices
        self.material = material
    }
}

/// How a surface looks: glTF 2.0's metallic-roughness model, which USD's `UsdPreviewSurface` also speaks.
///
/// Factors multiply their textures, exactly as glTF defines, so a material with no textures is just its
/// factors. The character-creator app's material, field for field.
public nonisolated struct ImportedMaterial: Sendable {
    public var name: String
    /// Linear RGBA. Multiplies `baseColorTexture`.
    public var baseColor: SIMD4<Float>
    public var baseColorTexture: ImportedTextureReference?
    public var metallic: Float
    public var roughness: Float
    /// Roughness in green, metalness in blue, as glTF packs them.
    public var metallicRoughnessTexture: ImportedTextureReference?
    public var normalTexture: ImportedTextureReference?
    public var normalScale: Float
    /// Ambient occlusion in red.
    public var occlusionTexture: ImportedTextureReference?
    public var occlusionStrength: Float
    /// Linear RGB. Multiplies `emissiveTexture`.
    public var emissive: SIMD3<Float>
    public var emissiveTexture: ImportedTextureReference?
    public var alphaMode: AlphaMode
    /// Below this alpha, a `.mask` surface is not drawn.
    public var alphaCutoff: Float
    /// Drawn from behind as well as in front — leaves, cloth, anything one polygon thick.
    public var doubleSided: Bool

    public enum AlphaMode: String, Sendable, Equatable, Codable {
        /// Alpha ignored.
        case opaque
        /// Cut out: each pixel is drawn or not, by `alphaCutoff`. Leaves and grass cards.
        case mask
        /// See-through.
        case blend
    }

    public init(name: String = "", baseColor: SIMD4<Float> = SIMD4(repeating: 1),
                baseColorTexture: ImportedTextureReference? = nil, metallic: Float = 1, roughness: Float = 1,
                metallicRoughnessTexture: ImportedTextureReference? = nil,
                normalTexture: ImportedTextureReference? = nil, normalScale: Float = 1,
                occlusionTexture: ImportedTextureReference? = nil, occlusionStrength: Float = 1,
                emissive: SIMD3<Float> = .zero, emissiveTexture: ImportedTextureReference? = nil,
                alphaMode: AlphaMode = .opaque, alphaCutoff: Float = 0.5, doubleSided: Bool = false) {
        self.name = name
        self.baseColor = baseColor
        self.baseColorTexture = baseColorTexture
        self.metallic = metallic
        self.roughness = roughness
        self.metallicRoughnessTexture = metallicRoughnessTexture
        self.normalTexture = normalTexture
        self.normalScale = normalScale
        self.occlusionTexture = occlusionTexture
        self.occlusionStrength = occlusionStrength
        self.emissive = emissive
        self.emissiveTexture = emissiveTexture
        self.alphaMode = alphaMode
        self.alphaCutoff = alphaCutoff
        self.doubleSided = doubleSided
    }

    /// A plain, untextured color — non-metallic and fairly rough, so it reads as painted rather than chrome.
    public static func plain(_ color: SIMD3<Float>, named name: String = "") -> ImportedMaterial {
        ImportedMaterial(name: name, baseColor: SIMD4(color, 1), metallic: 0, roughness: 0.8)
    }

    /// Every image the material uses.
    public var textures: [ImportedTexture] {
        [baseColorTexture, metallicRoughnessTexture, normalTexture, occlusionTexture, emissiveTexture]
            .compactMap { $0?.texture }
    }
}

/// A texture as a material uses it: the image, how it is sampled, and how its coordinates are moved.
public nonisolated struct ImportedTextureReference: Sendable {
    public var texture: ImportedTexture
    public var wrapS: Wrap
    public var wrapT: Wrap
    /// Nearest-neighbour magnification: what pixel-art and palette textures ask for.
    public var nearest: Bool
    /// KHR_texture_transform: applied to the coordinates before sampling — offset, rotation, scale.
    public var transform: simd_float3x3

    public enum Wrap: String, Sendable, Equatable { case repeating, clamp, mirror }

    public init(texture: ImportedTexture, wrapS: Wrap = .repeating, wrapT: Wrap = .repeating,
                nearest: Bool = false, transform: simd_float3x3 = matrix_identity_float3x3) {
        self.texture = texture
        self.wrapS = wrapS
        self.wrapT = wrapT
        self.nearest = nearest
        self.transform = transform
    }
}

/// An image, kept both as the file it came from and as pixels.
///
/// **The encoded bytes are kept so a tool can write the image exactly as it arrived**, never re-encoding a
/// JPEG — when the format it writes can carry that encoding. `pngData()` is for when it cannot (KTX2, WebP).
/// The pixels are 8-bit RGBA, straight alpha, top row first, with no color conversion: which space they are
/// in is the material's business — a base color is sRGB, a normal map is not.
public nonisolated final class ImportedTexture: Sendable {
    public let name: String
    /// The image file's own bytes.
    public let encoded: Data
    /// `image/png`, `image/jpeg`, `image/webp`, `image/ktx2`.
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    /// An image from pixels already decoded — what a reader with its own decoder (KTX2) makes.
    public init(name: String, encoded: Data, mimeType: String, width: Int, height: Int, pixels: [UInt8]) {
        self.name = name
        self.encoded = encoded
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Decodes an image: PNG, JPEG, WebP and the rest of what ImageIO reads, and KTX2 holding Basis Universal
    /// data through Binomial's transcoder. Nil when neither can.
    public convenience init?(name: String, encoded: Data) {
        if let (width, height, pixels) = Self.basis(encoded) {
            self.init(name: name, encoded: encoded, mimeType: "image/ktx2", width: width, height: height, pixels: pixels)
            return
        }
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = Self.rgba(image) else { return nil }
        self.init(name: name, encoded: encoded, mimeType: Self.mimeType(of: source),
                  width: image.width, height: image.height, pixels: pixels)
    }

    /// A KTX2 file's largest level as RGBA8, top row first, or nil when the bytes are not KTX2 with Basis data.
    ///
    /// **ImageIO does not read KTX2**, and glTF's `KHR_texture_basisu` is how packs keep their textures small;
    /// the reference transcoder is what every glTF reader uses (Apache 2.0, vendored as the `Basis` target).
    private static func basis(_ data: Data) -> (Int, Int, [UInt8])? {
        data.withUnsafeBytes { raw -> (Int, Int, [UInt8])? in
            guard let base = raw.baseAddress, we_basis_is_ktx2(base, raw.count) != 0 else { return nil }
            var width: UInt32 = 0, height: UInt32 = 0
            guard let pixels = we_basis_decode(base, raw.count, &width, &height) else { return nil }
            defer { we_basis_free(pixels) }
            return (Int(width), Int(height), Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height) * 4)))
        }
    }

    /// Whether the encoded bytes are a PNG or a JPEG — the two every tool reads.
    public var isPortable: Bool { mimeType == "image/png" || mimeType == "image/jpeg" }

    /// The file's own bytes when they are PNG or JPEG, otherwise the pixels as a PNG.
    public func portableData() -> (data: Data, fileExtension: String)? {
        if mimeType == "image/png" { return (encoded, "png") }
        if mimeType == "image/jpeg" { return (encoded, "jpg") }
        return pngData().map { ($0, "png") }
    }

    /// The pixels as a PNG.
    public func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The pixels as an image, straight alpha, with no color space conversion.
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draws the image into 8-bit RGBA with no color conversion, so the numbers are the file's own.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Device RGB, not sRGB: drawing into a named space would convert, and a normal map must arrive
        // untouched. Premultiplied because Core Graphics draws no other way; undone below.
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) }
        }
        return pixels
    }

    private static func mimeType(of source: CGImageSource) -> String {
        switch CGImageSourceGetType(source) as String? {
        case "public.jpeg": "image/jpeg"
        case "public.png": "image/png"
        case "org.webmproject.webp": "image/webp"
        case let type?: type
        case nil: "application/octet-stream"
        }
    }
}
