//
//  Material.swift
//  WindageEngine
//

import Foundation
import ModelIO
import simd

/// Which map a texture is, and therefore how it must be read.
///
/// **The split that matters is color against numbers**, and getting it wrong is the single most
/// common texture bug there is — see ``isColor``.
public nonisolated enum TextureSlot: String, Sendable, Hashable, CaseIterable {
    case baseColor
    case normal
    case metallic
    case roughness
    case ambientOcclusion
    case emissive

    /// Which channel of its texture this slot reads, for the slots that are packed together.
    ///
    /// ### One file, three maps, and Model I/O loses which is which
    ///
    /// Occlusion, roughness and metalness are each a single number, so they are conventionally packed
    /// into one RGB texture — **R occlusion, G roughness, B metalness**, which is glTF's packing and
    /// what every exporter writes. One file instead of three: a third of the memory, a third of the
    /// bindings, one sample in the shader instead of three.
    ///
    /// **A USD file says which channel each input reads and Model I/O does not pass it on.** Measured:
    /// a `UsdPreviewSurface` with `roughness` connected to a texture's `.g` and `metallic` to its `.b`
    /// arrives as two properties, both naming the same file, with nothing to say they differ. So the
    /// convention has to be assumed, and this is where it is written down rather than guessed at each
    /// call site.
    ///
    /// **It is also right for an unpacked map**, which is the reason the convention survives: a
    /// standalone roughness map is grayscale, so its green channel is its value. Reading a fixed
    /// channel works for both, and that is why glTF fixed one.
    public var packedChannel: Int? {
        switch self {
        case .ambientOcclusion: 0
        case .roughness: 1
        case .metallic: 2
        // Base colour, normals and emission use all three channels and are never packed with others.
        case .baseColor, .normal, .emissive: nil
        }
    }

    /// Whether this map holds a **color** or **numbers**.
    ///
    /// A color map is authored in sRGB — the encoding a monitor expects, which spends more of its
    /// range on darks because eyes do. Shading arithmetic is only correct in linear space, so a
    /// color texture has to be decoded on the way in. The GPU does that for free if the texture is
    /// created with an `_srgb` pixel format, and not at all if it is not.
    ///
    /// **A roughness or normal map is not a color.** Its bytes are already numbers. Decode one as
    /// sRGB and every value is bent — mid-gray roughness 0.5 arrives as 0.21, so everything looks
    /// wetter than it was authored, and a normal map's flat regions stop being flat.
    ///
    /// Both mistakes look like a lighting problem rather than a loading one, which is why this is a
    /// property of the slot and not a decision left to each caller.
    public var isColor: Bool { self == .baseColor || self == .emissive }
}

/// Where a texture comes from, before anything has loaded it.
///
/// **Unresolved on purpose.** Reading a material's numbers needs no GPU; turning a file into an
/// `MTLTexture` does. Keeping the reference as data means ``Material`` stays testable, `Sendable`
/// and free of any device — the same split that makes `RigLoader` testable.
public nonisolated enum TextureSource: Sendable, Hashable {
    /// A file on disk, usually resolved by Model I/O relative to the asset that named it.
    case url(URL)
    /// A resource in a bundle, by name including its extension.
    case named(String)
}

/// How a surface responds to light: the metallic-roughness parameter set.
///
/// **This set and not another, because it is the one everything speaks.** glTF, USD's
/// `UsdPreviewSurface`, Unreal, Unity's standard shader and every DCC exporter agree on base color,
/// metallic, roughness, normal, occlusion and emissive. An engine that invented its own vocabulary
/// would make every bought asset a conversion problem.
///
/// ### This is a material, not a material *system*
///
/// It is a value type describing a surface, and that is deliberately all it is. **No shader graph,
/// no permutations, no passes, no authoring model** — those are the contested part, where engines
/// genuinely disagree and where one game's needs would decide it wrongly for everybody. What is
/// settled is the parameter set, and that is what this is.
public nonisolated struct Material: Sendable, Equatable {

    public var name: String

    /// Linear, with alpha carrying opacity. **Multiplied with ``TextureSlot/baseColor`` when there
    /// is one**, so a material with a texture normally leaves this white.
    public var baseColor: SIMD4<Float>

    /// 0 for everything that is not metal, 1 for bare metal, and very little in between is physical.
    public var metallic: Float

    /// 0 is a mirror, 1 is chalk.
    public var roughness: Float

    /// Light the surface emits regardless of what is shining on it. Linear.
    public var emissive: SIMD3<Float>

    /// The maps, by slot. A slot with no entry has no map, and draws with the fallback
    /// `TextureStore.fallback(for:)` binds.
    public var textures: [TextureSlot: TextureSource]

    /// The Blinn-Phong exponent, where the file gave one. **Present means the material came from a
    /// format that speaks in exponents rather than in roughness** — see ``init(_:name:)``.
    public var specularExponent: Float?

    /// **Defaults chosen so that a material nobody filled in still draws.** White, dielectric and
    /// fairly rough is a plausible painted surface; zeroes would be a black hole and 0 roughness a
    /// mirror, and both read as a bug in the renderer rather than a missing material.
    public init(name: String = "",
                baseColor: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                metallic: Float = 0,
                roughness: Float = 0.65,
                emissive: SIMD3<Float> = .zero,
                textures: [TextureSlot: TextureSource] = [:],
                specularExponent: Float? = nil) {
        self.name = name
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.emissive = emissive
        self.textures = textures
        self.specularExponent = specularExponent
    }
}

nonisolated extension Material {

    /// Reads a material out of Model I/O's.
    ///
    /// ### Two properties can share one semantic, and `property(with:)` hides that
    ///
    /// **The finding this method exists for.** A USD `UsdPreviewSurface` with a textured diffuse
    /// arrives as *two* properties both carrying `.baseColor`: a float3 named `baseColor` and a
    /// texture named `diffuseColor`. `MDLMaterial.property(with:)` returns whichever it reaches
    /// first, so a loader using it gets a color on one asset and a texture on the next, with
    /// nothing to say which. Every semantic here is read from the **whole list**.
    ///
    /// ### Model I/O's own default is 0.18 gray, and it is not the file's intent
    ///
    /// That float3 `baseColor` above is 0.18 in a file that never mentioned a base color — it is
    /// the importer filling in a principled-shader default. Multiply a texture by it and the whole
    /// asset comes in at 18% brightness, which reads as a lighting bug. **So a slot with a texture
    /// takes a white tint**, and the numeric value is used only when there is no map to tint.
    ///
    /// Model I/O also fills in a full Disney parameter set — subsurface, sheen, clearcoat, two
    /// indices of refraction — which a metallic-roughness renderer has no use for. Ignored rather
    /// than carried, because a field nothing reads is a field somebody will eventually trust.
    public init(_ material: MDLMaterial, name: String? = nil) {
        self.init(name: name ?? material.name)

        for slot in TextureSlot.allCases {
            guard let semantic = slot.semantic else { continue }
            // **The first match wins, and that is not arbitrary.** Where a semantic has two
            // properties, `properties(with:)` returns the one the file actually authored before the
            // one the importer invented — `diffuseColor` before its 0.18 `baseColor`,
            // `emissiveColor` before a zeroed `emission`. Taking the last instead reads every
            // authored value back out as the default that was going to be overridden.
            let properties = material.properties(with: semantic)

            if let source = properties.lazy.compactMap({ $0.textureSource }).first {
                textures[slot] = source
                // **A map's scalar is the identity, not the type's default**, because the two are
                // multiplied. This is the 0.18 trap again in a second place: a file that connects
                // `metallic` to a texture supplies **no scalar at all**, so the field keeps whatever
                // this type initialises it to — and `metallic` initialises to 0, which multiplies the
                // map away entirely. A metal character comes out a dielectric one, and nothing says
                // so. Measured on a `UsdPreviewSurface` with all three channels connected.
                switch slot {
                case .metallic: metallic = 1
                case .roughness: roughness = 1
                case .emissive: emissive = .one
                default: break
                }
            }

            // Only meaningful without a map — see the 0.18 note above.
            guard textures[slot] == nil else { continue }
            for property in properties {
                switch (slot, property.type) {
                case (.baseColor, .float3):
                    baseColor = SIMD4(property.float3Value, baseColor.w)
                case (.baseColor, .float4):
                    baseColor = property.float4Value
                case (.emissive, .float3):
                    emissive = property.float3Value
                case (.metallic, .float):
                    metallic = property.floatValue
                case (.roughness, .float):
                    roughness = property.floatValue
                default:
                    continue
                }
                break
            }
        }

        if let opacity = material.property(with: .opacity), opacity.type == .float {
            baseColor.w = opacity.floatValue
        }

        // **An OBJ's roughness has to come from `Ns`, because Model I/O's roughness field is a
        // constant.** Measured across five materials: whatever `Ns` says, whatever `Pr` and `Pm` say,
        // the roughness semantic comes back 0.9 and metallic 0.0. The PBR extensions are read and
        // discarded; the specular exponent is the only thing an OBJ can actually say about how shiny
        // a surface is, and it does arrive.
        //
        // **`specularExponent` is the tell for an OBJ-style material**, and a reliable one: a USD
        // `UsdPreviewSurface` carries real roughness and metallic and no exponent at all. So its
        // presence means "this is a Blinn-Phong material and the roughness beside it is invented".
        if let exponent = material.property(with: .specularExponent), exponent.type == .float,
           exponent.floatValue > 0 {
            specularExponent = exponent.floatValue
            roughness = Material.roughness(fromSpecularExponent: exponent.floatValue)
        }
    }

    /// The usual conversion from a Blinn-Phong specular exponent to a perceptual roughness.
    ///
    /// `α = sqrt(2 / (Ns + 2))` is the standard equivalence between a Blinn-Phong lobe and a GGX one,
    /// and perceptual roughness is `sqrt(α)` — so `Ns` of 12 is roughness 0.62, 200 is 0.32, and 1 is
    /// 0.90. **An approximation between two things that are not the same shape**, but every renderer
    /// that reads OBJ makes some version of it, and the alternative is treating every OBJ surface as
    /// equally rough.
    static func roughness(fromSpecularExponent exponent: Float) -> Float {
        min(max(pow(2 / (max(exponent, 0) + 2), 0.25), 0), 1)
    }
}

nonisolated extension TextureSlot {
    /// The Model I/O semantic this slot reads from, or nil where there is no equivalent.
    var semantic: MDLMaterialSemantic? {
        switch self {
        case .baseColor: .baseColor
        case .normal: .tangentSpaceNormal
        case .metallic: .metallic
        case .roughness: .roughness
        case .ambientOcclusion: .ambientOcclusion
        case .emissive: .emission
        }
    }
}

nonisolated extension MDLMaterialProperty {
    /// The file this property points at, if it is a texture at all.
    ///
    /// **Read as a URL rather than through `textureSamplerValue`.** Model I/O will happily hand back
    /// a texture object with no name and no data — it logs *"unsupported image format"* for an
    /// ordinary PNG referenced from a `.usda` — while `urlValue` resolves correctly relative to the
    /// asset every time. The URL is also what a texture cache can be keyed on.
    ///
    /// **And the property's *type* cannot be used to recognize a texture.** The same property in the
    /// same file is `.string` before `MDLAsset.loadTextures()` is called and `.texture` after it, so
    /// a loader matching on `.texture` works or fails depending on an unrelated call somewhere else.
    /// Having a URL is the thing that actually means "this is a map".
    var textureSource: TextureSource? {
        guard let url = urlValue, type == .texture || type == .URL || type == .string else { return nil }
        return .url(url)
    }
}
