//
//  SampleRubble.swift
//  WindageSampleCore
//

import simd
import WindageEngine

/// Loose debris strewn round a level's buildings — the sample's use of ``InstanceBatches``.
///
/// **It is here to prove instancing through the public API**, the way every capability in the engine is
/// proved: a scene with a hundred small things in it, drawn as one batch. Debris is the honest case for
/// it — many copies of one mesh, none of them anything the player does anything with — so it is
/// scenery, not solid. It casts shadows, through a self-drawing shadow batch (2026-10-12).
///
/// **Deterministic**: the same level gives the same debris on every run and every machine, so the
/// recorded frames do not drift.
public enum SampleRubble {

    /// Where each piece lies: its transform, for a unit box standing on the ground.
    ///
    /// - Parameters:
    ///   - around: the level's buildings, as boxes in the world — debris lies among them, never inside.
    ///   - count: how many pieces to try to place.
    ///   - margin: how far past the buildings' extent it may stray, in metres.
    public static func transforms(around buildings: [BoundingBox], count: Int = 120, margin: Float = 4,
                                  seed: UInt64 = 0x5EED) -> [simd_float4x4] {
        guard let first = buildings.first else { return [] }
        let extent = buildings.dropFirst().reduce(first) {
            BoundingBox(minimum: simd_min($0.minimum, $1.minimum), maximum: simd_max($0.maximum, $1.maximum))
        }
        let low = SIMD2(extent.minimum.x - margin, extent.minimum.z - margin)
        let high = SIMD2(extent.maximum.x + margin, extent.maximum.z + margin)
        // Kept clear of every building by a little, so nothing pokes through a wall.
        let clear = buildings.map { $0.expanded(by: 0.15) }

        var random = seed
        func next() -> Float {
            // SplitMix64: tiny, fixed, the same on every machine.
            random &+= 0x9E37_79B9_7F4A_7C15
            var z = random
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)
        }

        var pieces: [simd_float4x4] = []
        for _ in 0..<count {
            let x = low.x + (high.x - low.x) * next(), z = low.y + (high.y - low.y) * next()
            let size = 0.12 + 0.16 * next()
            let yaw = next() * 2 * .pi
            let sits = clear.contains { box in
                x + size >= box.minimum.x && x - size <= box.maximum.x
                    && z + size >= box.minimum.z && z - size <= box.maximum.z
            }
            if sits { continue }
            pieces.append(simd_float4x4(translation: SIMD3(x, 0, z))
                          * simd_float4x4(rotationAngle: yaw, axis: SIMD3(0, 1, 0))
                          // **Evenly sized**, so the shader can turn normals with the transform itself:
                          // a squashed piece would need its inverse transpose, per copy.
                          * simd_float4x4(diagonal: SIMD4(size, size, size, 1)))
        }
        return pieces
    }
}
