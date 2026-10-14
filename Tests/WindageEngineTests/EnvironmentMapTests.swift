//
//  EnvironmentMapTests.swift
//  WindageEngineTests
//

import Testing
import Metal
import simd
@testable import WindageEngine

/// **The whole reason the prefilter is on the CPU.** Cube face projection, importance sampling and
/// the two convolutions are exactly the kind of arithmetic that produces a *plausible* picture when
/// it is wrong — a seam, a mirrored face, a reflection lit from the wrong side. A compute shader
/// would put all of it somewhere only a screenshot could check.
@MainActor
struct ProceduralSkyTests {

    private let sky = ProceduralSky()

    @Test("Up is the zenith and down is the ground")
    func gradientEnds() {
        #expect(simd_distance(sky.radiance(inDirection: SIMD3(0, 1, 0)), sky.zenith) < 1e-4)
        #expect(simd_distance(sky.radiance(inDirection: SIMD3(0, -1, 0)), sky.ground) < 1e-4)
    }

    /// **Not black below the horizon.** A surface facing down is lit by the ground, and a black lower
    /// hemisphere is the commonest reason an image-based lit object looks like it is floating.
    @Test("The lower hemisphere carries light")
    func groundIsNotBlack() {
        let below = sky.radiance(inDirection: SIMD3(0.2, -0.8, 0.1))
        #expect(simd_reduce_min(below) > 0.05)
    }

    @Test("The sun is far brighter than the sky around it")
    func sunIsBright() {
        let atSun = sky.radiance(inDirection: sky.sunDirection)
        let besideSun = sky.radiance(inDirection: simd_normalize(sky.sunDirection + SIMD3(0, 0.4, 0)))
        #expect(atSun.x > besideSun.x * 10, "a sun no brighter than the sky reflects as a smudge")
    }

    /// A hard-edged disc, sampled a few dozen times per texel by the prefilter, is a ring of speckle
    /// rather than a sun.
    @Test("The sun's edge is soft")
    func sunEdgeIsSoft() {
        let radius = sky.sunAngularRadius
        let (tangent, _) = EnvironmentMap.basis(around: sky.sunDirection)
        func offset(_ angle: Float) -> SIMD3<Float> {
            simd_normalize(sky.sunDirection * cos(angle) + tangent * sin(angle))
        }
        let inner = sky.radiance(inDirection: offset(radius * 0.5)).x
        let middle = sky.radiance(inDirection: offset(radius * 0.8)).x
        let outside = sky.radiance(inDirection: offset(radius * 1.2)).x
        #expect(inner > middle && middle > outside, "the disc has no falloff")
    }

    @Test("An unnormalised direction is handled")
    func lengthDoesNotMatter() {
        let a = sky.radiance(inDirection: SIMD3(0, 5, 0))
        let b = sky.radiance(inDirection: SIMD3(0, 1, 0))
        #expect(simd_distance(a, b) < 1e-5)
        #expect(!sky.radiance(inDirection: .zero).x.isNaN)
    }
}

@MainActor
struct EnvironmentMapTests {

    /// The six faces must tile the sphere without overlap or gap. **A sign wrong here mirrors a face
    /// or rotates it** — invisible on a smooth gradient and a hard seam the moment the sky has a sun
    /// in it.
    @Test("The six faces point the six ways and agree at their centres")
    func faceCentersAreTheAxes() {
        let expected: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
                                        SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        for face in 0..<6 {
            let center = EnvironmentMap.direction(face: face, u: 0.5, v: 0.5)
            #expect(simd_distance(center, expected[face]) < 1e-5, "face \(face)")
        }
    }

    @Test("Every direction a face produces is a unit vector")
    func directionsAreNormalised() {
        for face in 0..<6 {
            for u in stride(from: Float(0.05), through: 0.95, by: 0.15) {
                for v in stride(from: Float(0.05), through: 0.95, by: 0.15) {
                    let length = simd_length(EnvironmentMap.direction(face: face, u: u, v: v))
                    #expect(abs(length - 1) < 1e-5)
                }
            }
        }
    }

    /// Adjacent faces have to meet. Sampling the shared edge from either side must give the same
    /// direction, or there is a visible line down every cube seam.
    @Test("Faces meet along their shared edges")
    func facesMeetAtEdges() {
        // The +X face's left edge (u→0) and the +Z face's right edge (u→1) share the same points.
        for v in stride(from: Float(0.05), through: 0.95, by: 0.1) {
            let a = EnvironmentMap.direction(face: 0, u: 0, v: v)
            let b = EnvironmentMap.direction(face: 4, u: 1, v: v)
            #expect(simd_distance(a, b) < 1e-5, "the +X and +Z faces do not meet at v = \(v)")
        }
    }

    @Test("The low-discrepancy sequence covers the unit square")
    func hammersleyIsWellSpread() {
        #expect(EnvironmentMap.radicalInverse(0) == 0)
        #expect(abs(EnvironmentMap.radicalInverse(1) - 0.5) < 1e-6)
        #expect(abs(EnvironmentMap.radicalInverse(2) - 0.25) < 1e-6)

        // Every point inside the square, and both halves populated — the property that random
        // numbers fail at these counts and that a reflection shows as noise.
        var lowerHalf = 0
        let count = 64
        for index in 0..<count {
            let point = EnvironmentMap.hammersley(index, count: count)
            #expect(point.x >= 0 && point.x < 1 && point.y >= 0 && point.y < 1)
            if point.y < 0.5 { lowerHalf += 1 }
        }
        #expect(lowerHalf == count / 2)
    }

    /// The basis has to be orthonormal *at the poles too*: crossing with a fixed axis that happens to
    /// be the normal gives a zero vector, and straight up is exactly where that happens.
    @Test("The tangent basis survives the poles")
    func basisIsOrthonormalEverywhere() {
        for normal in [SIMD3<Float>(0, 1, 0), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
                       simd_normalize(SIMD3<Float>(0.3, 0.9, -0.2))] {
            let (t, b) = EnvironmentMap.basis(around: normal)
            #expect(abs(simd_length(t) - 1) < 1e-4, "tangent not unit at \(normal)")
            #expect(abs(simd_length(b) - 1) < 1e-4, "bitangent not unit at \(normal)")
            #expect(abs(simd_dot(t, normal)) < 1e-4)
            #expect(abs(simd_dot(b, normal)) < 1e-4)
            #expect(abs(simd_dot(t, b)) < 1e-4)
        }
    }

    /// At roughness 0 the lobe is a delta function; every sample must come back down the normal.
    @Test("A smooth surface samples only its own direction")
    func smoothLobeIsADelta() {
        let normal = simd_normalize(SIMD3<Float>(0.2, 0.9, 0.3))
        for index in 0..<32 {
            let h = EnvironmentMap.importanceSampleGGX(
                EnvironmentMap.hammersley(index, count: 32), normal: normal, roughness: 0)
            #expect(simd_distance(h, normal) < 1e-3)
        }
    }

    /// A rough lobe must actually spread — and never below the surface, which would sample the
    /// environment through the object.
    @Test("A rough surface spreads, and stays in its own hemisphere")
    func roughLobeSpreadsAboveTheSurface() {
        let normal = SIMD3<Float>(0, 1, 0)
        var maximumAngle: Float = 0
        for index in 0..<128 {
            let h = EnvironmentMap.importanceSampleGGX(
                EnvironmentMap.hammersley(index, count: 128), normal: normal, roughness: 0.8)
            let cosine = simd_dot(h, normal)
            #expect(cosine >= -1e-4, "a half-vector went below the surface")
            maximumAngle = max(maximumAngle, acos(min(cosine, 1)))
        }
        #expect(maximumAngle > 0.5, "the lobe did not spread")
    }

    /// **The property that makes a prefiltered chain a chain**: rougher mips must be blurrier, so the
    /// sun's contribution spreads out and its peak comes down.
    @Test("Roughness blurs: the sun's peak falls as roughness rises")
    func roughnessBlursTheSun() {
        let sky = ProceduralSky()
        var previous = Float.greatestFiniteMagnitude
        for roughness in [Float(0.15), 0.35, 0.6, 0.9] {
            let peak = EnvironmentMap.prefiltered(sky: sky, normal: sky.sunDirection,
                                                  roughness: roughness, sampleCount: 4096).x
            #expect(peak < previous, "roughness \(roughness) was not blurrier than the one before")
            previous = peak
        }
    }

    /// **The firefly this test was written to catch.** At a fixed sample count the chain stops
    /// getting blurrier and starts getting *brighter* again: measured against a converged reference,
    /// 96 samples give 0.72 at roughness 0.6 rising to 1.67 at roughness 1.0, where the truth falls
    /// to 0.60. A wide lobe over a small, very bright sun means the estimate is decided by whether
    /// any sample happened to land on the sun, and the rough mips come out blotched.
    @Test("A fixed sample count goes wrong at high roughness, which is why it is not fixed")
    func fixedSampleCountFirefliesAtHighRoughness() {
        let sky = ProceduralSky()
        let cheap = EnvironmentMap.prefiltered(sky: sky, normal: sky.sunDirection,
                                               roughness: 1.0, sampleCount: 96).x
        let converged = EnvironmentMap.prefiltered(sky: sky, normal: sky.sunDirection,
                                                   roughness: 1.0, sampleCount: 4096).x
        #expect(cheap > converged * 2, "the firefly this guards against has gone away — check why")

        // And the fix: the count quadruples per mip until it caps, so the roughest mips — which are
        // also the smallest — get the most samples. **Quadrupling is what makes it free**: each mip
        // has a quarter of the texels, so the cost per level is flat.
        var previous = 0
        var texelsTimesSamples: [Int] = []
        for mip in 0..<5 {
            let count = EnvironmentMap.sampleCount(forMip: mip)
            #expect(count >= previous, "mip \(mip) samples less heavily than the one above")
            previous = count
            let face = max(4, 128 >> mip)
            texelsTimesSamples.append(face * face * 6 * count)
        }
        // No level costs more than the first, which is the property that keeps the total bounded.
        for cost in texelsTimesSamples.dropFirst() {
            #expect(cost <= texelsTimesSamples[1], "a mip costs more than the most expensive one")
        }
    }

    /// Prefiltering must not invent or destroy energy: a uniform environment stays exactly itself at
    /// every roughness. **This is the test that catches a wrong weight**, which otherwise shows up as
    /// rough surfaces being subtly darker than smooth ones.
    @Test("A uniform environment survives prefiltering unchanged")
    func uniformEnvironmentIsPreserved() {
        let flat = ProceduralSky(zenith: SIMD3(repeating: 0.5), horizon: SIMD3(repeating: 0.5),
                                 ground: SIMD3(repeating: 0.5), sunRadiance: .zero)
        for roughness in [Float(0.1), 0.4, 0.7, 1.0] {
            let result = EnvironmentMap.prefiltered(sky: flat, normal: SIMD3(0, 1, 0),
                                                    roughness: roughness)
            #expect(abs(result.x - 0.5) < 1e-3, "roughness \(roughness) changed a uniform sky")
        }
    }

    /// Irradiance from a uniform environment of radiance `L` is `π L`. Getting the `sin θ` weight
    /// wrong over-weights the pole and lights everything from straight ahead; the error shows here as
    /// a wrong constant.
    @Test("Irradiance from a uniform sky is pi times its radiance")
    func irradianceOfAUniformSky() {
        let flat = ProceduralSky(zenith: SIMD3(repeating: 1), horizon: SIMD3(repeating: 1),
                                 ground: SIMD3(repeating: 1), sunRadiance: .zero)
        let result = EnvironmentMap.irradiance(sky: flat, normal: SIMD3(0, 1, 0), step: 0.05)
        #expect(abs(result.x - .pi) < 0.05, "got \(result.x), expected pi")
    }

    /// Facing the bright half of the sky must gather more than facing the dark half — the sanity
    /// check that the convolution is oriented at all.
    @Test("Irradiance follows the sky it faces")
    func irradianceFollowsTheSky() {
        let sky = ProceduralSky(sunRadiance: .zero)      // gradient only, so this is about direction
        let up = EnvironmentMap.irradiance(sky: sky, normal: SIMD3(0, 1, 0))
        let down = EnvironmentMap.irradiance(sky: sky, normal: SIMD3(0, -1, 0))
        #expect(up.z > down.z, "facing the sky gathered no more than facing the ground")
    }

    // MARK: - The GPU half, which is a texture descriptor and little else

    @Test("The cubes are built with the mip chain a shader indexes by roughness")
    func texturesAreShaped() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let environment = try? EnvironmentMap(device: device, sky: ProceduralSky(),
                                               size: 32, irradianceSize: 8) else { return }
        #expect(environment.specular.textureType == .typeCube)
        #expect(environment.specular.width == 32)
        #expect(environment.specular.mipmapLevelCount == environment.specularMipCount)
        #expect(environment.specularMipCount > 1)
        #expect(environment.irradiance.width == 8)
        #expect(environment.irradiance.mipmapLevelCount == 1)
        #expect(environment.allocations.count == 2)
    }
}

/// **The sun's direction stays normalized however it is set.** Set by hand at any other length, every
/// shader dot product with it was scaled by that length and the pitch read back was wrong.
struct ProceduralSkyDirectionTests {

    @Test("A sun direction set at any length is normalized")
    func sunDirectionNormalizedOnSet() {
        var sky = ProceduralSky()
        sky.sunDirection = SIMD3(0, 3, 4)
        #expect(abs(simd_length(sky.sunDirection) - 1) < 1e-6)
        #expect(abs(sky.sunDirection.y - 0.6) < 1e-6 && abs(sky.sunDirection.z - 0.8) < 1e-6)
    }

    @Test("A zero sun direction points straight up rather than becoming NaN")
    func zeroSunPointsUp() {
        var sky = ProceduralSky()
        sky.sunDirection = .zero
        #expect(sky.sunDirection == SIMD3(0, 1, 0))
        #expect(ProceduralSky(sunDirection: .zero).sunDirection == SIMD3(0, 1, 0))
    }

    @Test("Setting the sun by its angles stores the direction they give, unchanged")
    func anglesStoreTheirDirection() {
        var sky = ProceduralSky()
        sky.sunPitchDegrees = 34
        sky.sunYawDegrees = 295
        let expected = ProceduralSky.direction(pitchDegrees: 34, yawDegrees: 295)
        #expect(abs(sky.sunPitchDegrees - 34) < 1e-3)
        #expect(simd_distance(sky.sunDirection, expected) < 1e-6)
    }
}

/// **`nonisolated` and `Sendable`, so the build can leave the main actor.**
struct EnvironmentMapIsolationTests {

    @Test("An environment map can be built on a worker and handed back")
    func buildsOffTheMainActor() async {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let map = await Task.detached {
            try? EnvironmentMap(device: device, sky: ProceduralSky(), size: 16, irradianceSize: 4)
        }.value
        #expect(map?.specular.width == 16)
    }
}
