//
//  MaterialTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import ModelIO
import simd
@testable import WindageEngine

@MainActor
struct MaterialTests {

    /// Reading a material's *numbers* needs no GPU — which is the whole reason `Material` is split
    /// from `TextureStore`, and why this suite exists at all.
    private func loadMaterial() throws -> Material {
        let url = try #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda"))
        let asset = MDLAsset(url: url)
        var found: MDLMaterial?
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                for submesh in (mesh.submeshes as? [MDLSubmesh] ?? []) {
                    if found == nil { found = submesh.material }
                }
            }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }
        return Material(try #require(found))
    }

    @Test("A material with nothing filled in still draws")
    func defaultsAreDrawable() {
        let material = Material()
        #expect(material.baseColor == SIMD4(1, 1, 1, 1), "black is indistinguishable from a bug")
        #expect(material.metallic == 0)
        #expect(material.roughness > 0, "zero roughness is a mirror, which also reads as a bug")
        #expect(material.textures.isEmpty)
    }

    @Test("The scalars come through")
    func scalarsAreRead() throws {
        let material = try loadMaterial()
        #expect(abs(material.metallic - 0.1) < 1e-5)
        #expect(abs(material.roughness - 0.65) < 1e-5)
        #expect(abs(material.emissive.x - 0.02) < 1e-5)
    }

    @Test("A texture is found even though another property shares its semantic")
    func textureWinsOverTheSharedSemantic() throws {
        let material = try loadMaterial()
        let source = try #require(material.textures[.baseColor])
        guard case .url(let url) = source else {
            Issue.record("base colour did not come through as a file")
            return
        }
        #expect(url.lastPathComponent == "material-map.png")
    }

    /// **The 0.18 trap.** Model I/O invents a principled-shader default base colour of 0.18 grey for
    /// a file that never mentions one. Multiply a texture by it and the whole asset arrives at 18%
    /// brightness — which reads as a lighting bug, in a renderer that is working correctly.
    @Test("A slot with a map takes a white tint, not Model I/O's invented default")
    func texturedSlotIsNotTintedByTheImportersDefault() throws {
        let material = try loadMaterial()
        #expect(material.baseColor.x == 1 && material.baseColor.y == 1 && material.baseColor.z == 1)
    }

    /// Colour maps are encoded for eyes; everything else holds numbers. Decoding a roughness map as
    /// sRGB bends every value — 0.5 arrives as 0.21 and the whole scene looks wet.
    @Test("Only the colour slots are sRGB")
    func onlyColorSlotsAreColor() {
        #expect(TextureSlot.baseColor.isColor)
        #expect(TextureSlot.emissive.isColor)
        for slot in [TextureSlot.normal, .metallic, .roughness, .ambientOcclusion] {
            #expect(!slot.isColor, "\(slot.rawValue) holds numbers, not colour")
        }
    }

    /// **Model I/O's OBJ reader hard-codes roughness.** Measured across five materials: whatever
    /// `Ns` says, and whatever the `Pr`/`Pm` PBR extensions say, the roughness semantic comes back
    /// 0.9 and metallic 0.0. The specular exponent is the only thing an OBJ can actually say about
    /// shininess and it does arrive — so it is what roughness comes from.
    @Test("An OBJ's roughness comes from its specular exponent")
    func objRoughnessComesFromTheExponent() throws {
        let url = try #require(Bundle.module.url(forResource: "box-exponent", withExtension: "obj"))
        let asset = MDLAsset(url: url)
        var found: MDLMaterial?
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                for submesh in (mesh.submeshes as? [MDLSubmesh] ?? []) {
                    if found == nil { found = submesh.material }
                }
            }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }

        let material = Material(try #require(found))
        #expect(material.specularExponent == 200)
        #expect(abs(material.roughness - 0.315) < 1e-3,
                "roughness is still Model I/O's invented 0.9")
    }

    /// A USD `UsdPreviewSurface` carries real roughness and metallic and **no** exponent, which is
    /// what makes the exponent a reliable tell for a Blinn-Phong material.
    @Test("A USD material keeps its own roughness")
    func usdRoughnessIsNotOverridden() throws {
        let material = try loadMaterial()
        #expect(material.specularExponent == nil)
        #expect(abs(material.roughness - 0.65) < 1e-5)
        #expect(abs(material.metallic - 0.1) < 1e-5)
    }

    @Test("The exponent conversion covers the useful range")
    func exponentConversionIsSane() {
        #expect(abs(Material.roughness(fromSpecularExponent: 1) - 0.9036) < 1e-3)
        #expect(abs(Material.roughness(fromSpecularExponent: 12) - 0.6156) < 1e-3)
        #expect(abs(Material.roughness(fromSpecularExponent: 200) - 0.3151) < 1e-3)
        // Never outside 0…1, whatever a file claims.
        #expect(Material.roughness(fromSpecularExponent: 0) <= 1)
        #expect(Material.roughness(fromSpecularExponent: -5) <= 1)
        #expect(Material.roughness(fromSpecularExponent: 1e9) >= 0)
    }

    /// **The 0.18 trap in a second place, and it was nearly shipped.** A file that connects
    /// `metallic` to a texture supplies *no scalar at all*, so the field keeps whatever the type
    /// initialises it to — and `metallic` initialises to 0. Multiplied by the map, that is zero
    /// everywhere: a metal character renders as a dielectric one, with nothing to say why.
    ///
    /// A slot with a map takes the identity for the operation it is used in, which for a multiplied
    /// factor is 1.
    @Test("A slot with a map takes the identity scalar, not the type's default")
    func mappedSlotsTakeIdentityScalars() throws {
        let url = try #require(Bundle.module.url(forResource: "packed-orm", withExtension: "usda"))
        let asset = MDLAsset(url: url)
        var found: MDLMaterial?
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                for submesh in (mesh.submeshes as? [MDLSubmesh] ?? []) {
                    if found == nil { found = submesh.material }
                }
            }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }

        let material = Material(try #require(found))
        #expect(material.textures[.metallic] != nil, "the metalness map did not come through")
        #expect(material.textures[.roughness] != nil)
        #expect(material.metallic == 1, "a metalness map multiplied by 0 is not metal")
        #expect(material.roughness == 1, "a roughness map multiplied by 0.65 is not the map")
        #expect(material.textures[.emissive] != nil, "the emissive map did not come through")
        #expect(material.emissive == SIMD3(repeating: 1), "an emissive map multiplied by 0 is dark")
    }

    /// And a slot with no map keeps the file's own number, or a plausible one.
    @Test("An unmapped slot keeps its scalar")
    func unmappedSlotsKeepScalars() throws {
        let material = try loadMaterial()
        #expect(material.textures[.metallic] == nil)
        #expect(abs(material.metallic - 0.1) < 1e-5)
        #expect(abs(material.roughness - 0.65) < 1e-5)
    }

    /// **The convention Model I/O drops.** A USD file says which channel each input reads — roughness
    /// from `.g`, metalness from `.b` — and the material that arrives names the same file for both
    /// with nothing to distinguish them. glTF's packing is the assumption, written down once.
    @Test("The packed slots read glTF's channels, and the unpacked ones read none")
    func packedChannels() {
        #expect(TextureSlot.ambientOcclusion.packedChannel == 0)
        #expect(TextureSlot.roughness.packedChannel == 1)
        #expect(TextureSlot.metallic.packedChannel == 2)
        for slot in [TextureSlot.baseColor, .normal, .emissive] {
            #expect(slot.packedChannel == nil, "\(slot.rawValue) uses every channel")
        }
        // Distinct, or two of them would read the same number out of one texture.
        let packed = TextureSlot.allCases.compactMap(\.packedChannel)
        #expect(Set(packed).count == packed.count)
    }

    /// A materials array shorter than the submeshes indexing it is an out-of-bounds crash at draw
    /// time, in a loop with nothing to do with loading. Padding happens at load, once.
    @Test("The materials list is padded to the submesh count")
    func materialsArePaddedToSubmeshCount() throws {
        let url = try #require(Bundle.module.url(forResource: "textured-quad", withExtension: "usda"))
        let asset = MDLAsset(url: url)
        var mesh: MDLMesh?
        func descend(_ object: MDLObject) {
            if mesh == nil, let found = object as? MDLMesh { mesh = found }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }

        let one = try #require(mesh)
        #expect(MeshLoader.materials(of: one, count: 1).count == 1)
        #expect(MeshLoader.materials(of: one, count: 4).count == 4)
        #expect(MeshLoader.materials(of: one, count: 0).isEmpty)
    }
}
