//
//  GPUResourceErrorTests.swift
//  WindageEngineTests
//

import Testing
import Metal
@testable import WindageEngine

/// **A GPU object that cannot be made says which one.** The shadow passes and the environment map
/// returned `nil` for every failure alike; each now throws an error naming the object.
///
/// **The failures themselves cannot be brought about here.** A texture past the GPU's largest edge is
/// the obvious way to make the device refuse one, and Metal stops the process with a descriptor
/// assertion instead of returning `nil` — so what is tested is what each error says, and that what
/// fits is still made.
struct GPUResourceErrorTests {

    @Test("Each error names the object the device would not create")
    func errorsNameTheirObject() {
        #expect(ShadowMapError.texture.description.contains("shadow map's depth texture array"))
        #expect(ShadowMapError.matrixBuffer.description.contains("matrix buffer"))
        #expect(ShadowAtlasError.depthState.description.contains("shadow atlas's depth state"))
        #expect(ShadowCubesError.texture.description.contains("shadow cubes' cube-array depth texture"))
        struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
        #expect(ShadowCubesError.argumentTable(underlying: Refused()).description
                    .contains("argument table — refused"))
        #expect(EnvironmentMapError.specularTexture.description.contains("specular cube"))
        #expect(EnvironmentMapError.irradianceTexture.description.contains("irradiance cube"))
    }

    @Test("Shadow passes and an environment map that fit are made as before")
    @MainActor
    func whatFitsIsMade() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let cascades = ShadowCascades(splits: [8, 22], resolution: 256, lightDepthRange: 200)
        #expect(try ShadowMap(device: device, cascades: cascades).texture.arrayLength == 2)
        #expect(try ShadowAtlas(device: device, resolution: 256).texture.width == 256)
        #expect(try ShadowCubes(device: device, resolution: 64).texture.width == 64)
        #expect(try EnvironmentMap(device: device, sky: ProceduralSky(), size: 16, irradianceSize: 4)
                    .specular.width == 16)
    }
}
