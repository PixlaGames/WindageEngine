//
//  EnvironmentMap.swift
//  WindageEngine
//

import Foundation
import Metal
import simd

/// Why an ``EnvironmentMap`` could not be made: which of its two cube textures the device would not
/// create.
public nonisolated enum EnvironmentMapError: Error, CustomStringConvertible, Sendable, Equatable {
    /// The specular cube, with its roughness mip chain — too large for this GPU, or out of memory.
    case specularTexture
    /// The irradiance cube.
    case irradianceTexture

    public var description: String {
        switch self {
        case .specularTexture: "the device would not create the environment map's specular cube"
        case .irradianceTexture: "the device would not create the environment map's irradiance cube"
        }
    }
}

/// The lighting an environment contributes: what it looks like reflected, and what it looks like
/// scattered.
///
/// ### Why two textures and not one
///
/// A surface takes light from the whole environment, and *how* it takes it depends on how rough it
/// is. A mirror reflects one direction; chalk gathers the entire hemisphere. Doing that integral per
/// pixel per frame is not affordable, so it is precomputed twice:
///
/// | | what it holds |
/// |---|---|
/// | ``specular`` | The environment convolved with the GGX lobe, **one roughness per mip**: mip 0 is the environment itself, the last mip is nearly uniform. A shader samples it at `roughness × (mips − 1)`. |
/// | ``irradiance`` | The environment convolved with a cosine lobe — what a diffuse surface facing a direction receives. Tiny, because the result has almost no detail in it. |
///
/// ### Built on the CPU, and that is the point
///
/// **Every part of this that can be *wrong* is arithmetic**, and this repository's rule is that such
/// halves want tests and tests should not want a GPU. A compute-shader prefilter would be faster and
/// would put the importance sampling, the mip-to-roughness mapping and the cube face projection
/// somewhere only a screenshot could check. Here they are ordinary functions with ordinary tests, and
/// the cost is a fraction of a second at load — the whole chain is about two million evaluations of a
/// function that is a handful of arithmetic operations.
///
/// The trade is real and it is stated: this prefilters a **function**, not a photograph. An engine
/// that wants to prefilter a captured HDR panorama on the GPU will want the compute version, and the
/// maths here is what it would be written against.
///
/// ### Built anywhere
///
/// **`nonisolated` and `Sendable`**, so a game that would rather not spend the build on the main actor
/// — about two million evaluations — makes it on a worker (`Task.detached`) and hands the finished map
/// over. Unchecked, because Metal does not mark its textures `Sendable`: every field is a `let`, and
/// the textures are written only inside `init`, before anything else can hold them.
public nonisolated final class EnvironmentMap: @unchecked Sendable {

    /// The environment convolved with the GGX lobe, roughness increasing with mip level.
    public let specular: MTLTexture

    /// The environment convolved with a cosine lobe: irradiance per direction.
    public let irradiance: MTLTexture

    /// Sample ``specular`` at `roughness * Float(specularMipCount - 1)`.
    public let specularMipCount: Int

    public var allocations: [any MTLAllocation] { [specular, irradiance] }

    /// - Parameters:
    ///   - size: edge length of the specular cube's base mip. 128 is plenty for a sky — the detail a
    ///     reflection can actually show is limited by the roughness it is convolved with, and mip 0
    ///     is the only one that keeps any.
    ///   - irradianceSize: edge length of the irradiance cube. **16 is not a corner cut**: a cosine
    ///     convolution is a very heavy blur, so the result genuinely has nothing in it finer than
    ///     this, and a larger one is the same picture stored at greater cost.
    /// - Throws: ``EnvironmentMapError``, naming the object the device would not create.
    public init(device: MTLDevice,
                sky: ProceduralSky,
                size: Int = 128,
                irradianceSize: Int = 16) throws {
        let mipCount = max(1, Int(log2(Double(size))) - 1)   // stop at 4×4; below that is noise
        self.specularMipCount = mipCount

        guard let specular = EnvironmentMap.makeCube(device: device, size: size,
                                                     mipCount: mipCount, label: "Environment Specular")
        else { throw EnvironmentMapError.specularTexture }
        guard let irradiance = EnvironmentMap.makeCube(device: device, size: irradianceSize,
                                                       mipCount: 1, label: "Environment Irradiance")
        else { throw EnvironmentMapError.irradianceTexture }
        self.specular = specular
        self.irradiance = irradiance

        for mip in 0..<mipCount {
            let mipSize = max(4, size >> mip)
            let roughness = mipCount > 1 ? Float(mip) / Float(mipCount - 1) : 0
            let samples = EnvironmentMap.sampleCount(forMip: mip)
            EnvironmentMap.fill(specular, mip: mip, size: mipSize) { direction in
                // **Mip 0 is the environment itself, not a convolution of it.** At roughness 0 the
                // GGX lobe is a delta function, and importance sampling a delta produces however many
                // copies of nearly the same value, plus noise.
                roughness <= 0
                    ? sky.radiance(inDirection: direction)
                    : EnvironmentMap.prefiltered(sky: sky, normal: direction,
                                                 roughness: roughness, sampleCount: samples)
            }
        }

        EnvironmentMap.fill(irradiance, mip: 0, size: irradianceSize) { direction in
            EnvironmentMap.irradiance(sky: sky, normal: direction)
        }
    }

    // MARK: - Building

    private static func makeCube(device: MTLDevice, size: Int, mipCount: Int, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float, size: size, mipmapped: mipCount > 1)
        descriptor.mipmapLevelCount = mipCount
        descriptor.usage = .shaderRead
        // Shared so the faces can be written straight in. On Apple silicon there is no separate
        // upload to save, and a private texture would need a staging buffer and a blit for nothing.
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    /// Evaluates `radiance` for every texel of every face and writes it in.
    ///
    /// **The faces are filled in parallel.** Each is independent, and six cores doing six faces is
    /// the difference between a load pause somebody notices and one they do not.
    private static func fill(_ texture: MTLTexture,
                             mip: Int,
                             size: Int,
                             radiance: @escaping @Sendable (SIMD3<Float>) -> SIMD3<Float>) {
        let bytesPerPixel = MemoryLayout<UInt16>.size * 4
        let bytesPerRow = size * bytesPerPixel
        // Each face writes only its own sixth, so the workers never touch the same element.
        nonisolated(unsafe) let faces = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: size * size * 4 * 6)
        defer { faces.deallocate() }

        DispatchQueue.concurrentPerform(iterations: 6) { face in
            let base = face * size * size * 4
            for y in 0..<size {
                for x in 0..<size {
                    // Texel centres, not corners: sampling the corner of a texel biases the whole
                    // face half a texel towards one edge, which shows up as a seam between faces.
                    let u = (Float(x) + 0.5) / Float(size)
                    let v = (Float(y) + 0.5) / Float(size)
                    let color = radiance(direction(face: face, u: u, v: v))
                    let index = base + (y * size + x) * 4
                    faces[index] = halfBits(color.x)
                    faces[index + 1] = halfBits(color.y)
                    faces[index + 2] = halfBits(color.z)
                    faces[index + 3] = halfBits(1)
                }
            }
        }

        for face in 0..<6 {
            let offset = face * size * size * 4
            texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: mip,
                            slice: face,
                            withBytes: faces.baseAddress! + offset,
                            bytesPerRow: bytesPerRow,
                            bytesPerImage: bytesPerRow * size)
        }
    }

    /// A `Float` as the bits of a half float, for an `.rgba16Float` texture.
    ///
    /// **Bits, not `Float16`, so the engine compiles for Intel (2026-10-14).** Swift has no `Float16` on Intel
    /// Macs, and an App Store archive builds for both architectures: an editor's failed outright here, while every
    /// Debug build — this Mac's architecture only — had passed. Metal 4 needs Apple silicon, so Intel never runs
    /// this; it only has to compile. On Apple silicon it is `Float16` exactly as before, so every frame is
    /// unchanged; on Intel it is the same round-to-nearest-even, written out.
    @inline(__always)
    static func halfBits(_ value: Float) -> UInt16 {
        #if arch(arm64)
        return Float16(value).bitPattern
        #else
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let magnitude = bits & 0x7FFF_FFFF
        if magnitude > 0x7F80_0000 { return sign | 0x7E00 }               // NaN
        let exponent = Int(magnitude >> 23) - 127 + 15
        var mantissa = magnitude & 0x7F_FFFF
        if exponent >= 31 { return sign | 0x7C00 }                          // too large: infinity
        if exponent <= 0 {                                                  // subnormal, or zero
            if exponent < -10 { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            var half = mantissa >> shift
            let rest = mantissa & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rest > halfway || (rest == halfway && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(exponent) << 10 | mantissa >> 13
        let rest = mantissa & 0x1FFF
        if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) { half += 1 } // a carry into the exponent is right
        return sign | UInt16(half)
        #endif
    }

    /// How many samples a mip's convolution gets. **Quadrupling per mip, and this is not a tuning
    /// preference — it is a fix for fireflies, bought for free.**
    ///
    /// Measured against a converged reference: at a fixed 96 samples the chain stops getting blurrier
    /// around roughness 0.6 and starts getting *brighter* again — 0.72 at roughness 0.6 rising to
    /// 1.67 at roughness 1.0, where the true values fall to 0.60. A wide lobe over a small, very
    /// bright sun means the estimate is decided by whether any sample happened to land on the sun, so
    /// the rough mips come out blotched with sun-colored speckle.
    ///
    /// **Quadrupling exactly cancels the mip chain.** Each level has a quarter of the texels of the
    /// one above, so four times the samples costs the same per level — the whole chain is a flat
    /// budget, and the roughest mips, which need the samples most, are the cheapest place to spend
    /// them. A 4×4 face at 4,096 samples is a sixth of the work of a 64×64 face at 96.
    static func sampleCount(forMip mip: Int) -> Int {
        min(4096, 24 << (2 * mip))
    }

    // MARK: - The arithmetic, which is what the tests are for

    /// The direction a cube map texel faces.
    ///
    /// **Metal's cube convention, which is Direct3D's**: +X, −X, +Y, −Y, +Z, −Z, with the second
    /// texture axis running *downwards*. Get a sign wrong here and the sky is mirrored or a face is
    /// rotated — which looks like nothing at all on a smooth gradient and like a seam the moment
    /// anything has structure in it. That is why the sun disc is in the sky at all.
    static func direction(face: Int, u: Float, v: Float) -> SIMD3<Float> {
        let s = 2 * u - 1
        let t = 2 * v - 1
        switch face {
        case 0: return simd_normalize(SIMD3(1, -t, -s))
        case 1: return simd_normalize(SIMD3(-1, -t, s))
        case 2: return simd_normalize(SIMD3(s, 1, t))
        case 3: return simd_normalize(SIMD3(s, -1, -t))
        case 4: return simd_normalize(SIMD3(s, -t, 1))
        default: return simd_normalize(SIMD3(-s, -t, -1))
        }
    }

    /// The van der Corput sequence, base 2 — the second half of a Hammersley point.
    ///
    /// **A low-discrepancy sequence rather than random numbers.** Sixty-four random directions leave
    /// visible clumps and gaps, and the gaps are what a reflection shows as noise; the same count
    /// spread evenly is clean.
    static func radicalInverse(_ bits: UInt32) -> Float {
        var b = bits
        b = (b << 16) | (b >> 16)
        b = ((b & 0x5555_5555) << 1) | ((b & 0xAAAA_AAAA) >> 1)
        b = ((b & 0x3333_3333) << 2) | ((b & 0xCCCC_CCCC) >> 2)
        b = ((b & 0x0F0F_0F0F) << 4) | ((b & 0xF0F0_F0F0) >> 4)
        b = ((b & 0x00FF_00FF) << 8) | ((b & 0xFF00_FF00) >> 8)
        return Float(b) * 2.328_306_4e-10
    }

    static func hammersley(_ index: Int, count: Int) -> SIMD2<Float> {
        SIMD2(Float(index) / Float(count), radicalInverse(UInt32(index)))
    }

    /// An orthonormal basis around `normal`.
    static func basis(around normal: SIMD3<Float>) -> (tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
        // **Picked away from the normal.** Crossing with a fixed axis that happens to be the normal
        // gives a zero vector, and the pole of every cube face is exactly where that happens.
        let up = abs(normal.y) < 0.999 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let tangent = simd_normalize(simd_cross(up, normal))
        return (tangent, simd_cross(normal, tangent))
    }

    /// A half-vector drawn from the GGX distribution for this roughness.
    static func importanceSampleGGX(_ xi: SIMD2<Float>,
                                    normal: SIMD3<Float>,
                                    roughness: Float) -> SIMD3<Float> {
        let alpha = roughness * roughness
        let phi = 2 * Float.pi * xi.x
        let cosTheta = sqrt((1 - xi.y) / (1 + (alpha * alpha - 1) * xi.y))
        let sinTheta = sqrt(max(0, 1 - cosTheta * cosTheta))
        let local = SIMD3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta)
        let (tangent, bitangent) = basis(around: normal)
        return simd_normalize(tangent * local.x + bitangent * local.y + normal * local.z)
    }

    /// The environment convolved with the GGX lobe, for a viewer looking straight down `normal`.
    ///
    /// **Assumes the view direction is the normal**, which is the standard split-sum approximation
    /// and the reason a prefiltered map can be a cube at all: the true integral depends on the view
    /// angle as well, and storing that would need a dimension nobody has. The cost is that
    /// reflections stretch too little at grazing angles, which nobody has ever noticed in a game.
    static func prefiltered(sky: ProceduralSky,
                            normal: SIMD3<Float>,
                            roughness: Float,
                            sampleCount: Int = 96) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        var weight: Float = 0
        for index in 0..<sampleCount {
            let h = importanceSampleGGX(hammersley(index, count: sampleCount),
                                        normal: normal, roughness: roughness)
            let l = 2 * simd_dot(normal, h) * h - normal
            let nDotL = simd_dot(normal, l)
            guard nDotL > 0 else { continue }
            // Weighted by N·L: a sample arriving edge-on contributes less, and dividing by the total
            // weight rather than the sample count is what keeps the result unbiased.
            sum += sky.radiance(inDirection: l) * nDotL
            weight += nDotL
        }
        return weight > 0 ? sum / weight : sky.radiance(inDirection: normal)
    }

    /// The environment convolved with a cosine lobe: what a diffuse surface facing `normal` receives.
    ///
    /// Stepped in spherical coordinates rather than importance sampled, because the integrand is the
    /// whole hemisphere and there is no lobe to concentrate samples in.
    static func irradiance(sky: ProceduralSky,
                           normal: SIMD3<Float>,
                           step: Float = 0.1) -> SIMD3<Float> {
        let (tangent, bitangent) = basis(around: normal)
        var sum = SIMD3<Float>.zero

        var phi: Float = 0
        while phi < 2 * .pi {
            var theta: Float = 0
            while theta < .pi / 2 {
                let local = SIMD3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
                let world = tangent * local.x + bitangent * local.y + normal * local.z
                // `cos θ` for Lambert's law and `sin θ` for the shrinking area of each ring towards
                // the pole. Leaving the second out over-weights the pole and lights everything from
                // straight ahead.
                sum += sky.radiance(inDirection: world) * cos(theta) * sin(theta)
                theta += step
            }
            phi += step
        }
        // **Times the area of a cell, not divided by the sample count.** This is a Riemann sum over
        // dφ dθ, so each term is worth `step²` of solid-angle measure; dividing by the count instead
        // gives an *average* rather than an integral, and the two differ by a factor of π — which
        // reads as ambient light being mysteriously too dark, uniformly, everywhere.
        return sum * step * step
    }
}
