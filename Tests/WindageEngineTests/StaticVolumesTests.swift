//
//  StaticVolumesTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// **The grid must give the answer testing every volume gives** — the same volume, at the same distance — or a shot
/// passes through a wall the slow way would have stopped it on.
struct StaticVolumesTests {

    /// A scattered field of boxes of mixed sizes, turned, over a few hundred metres — the shape of a level's scenery.
    private static let field: [Volume] = {
        var seed: UInt64 = 0x5EED
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        return (0..<600).map { _ in
            let size = SIMD3<Float>(0.5 + random() * 12, 0.5 + random() * 20, 0.5 + random() * 12)
            let local = BoundingBox(minimum: -size / 2 * SIMD3(1, 0, 1), maximum: size / 2 * SIMD3(1, 2, 1))
            let at = SIMD3(random() * 600 - 300, random() * 6 - 3, random() * 600 - 300)
            let turned = simd_mul(simd_float4x4(translation: at), simd_float4x4(rotationAngle: random() * 6.28, axis: SIMD3(0, 1, 0)))
            return Volume(localBounds: local, transform: turned)
        }
    }()

    @Test("A ray meets the same volume, at the same distance, as testing every one")
    func raysAgree() {
        let grid = StaticVolumes(Self.field)
        var hits = 0
        for i in 0..<400 {
            let a = Float(i) * 0.731
            let origin = SIMD3<Float>(cos(a) * 340, 1 + Float(i % 7), sin(a * 1.3) * 340)
            let direction = simd_normalize(SIMD3(-cos(a + 0.3), -0.01 * Float(i % 5), -sin(a * 1.3 + 0.2)))
            let slow = Volume.firstHit(origin: origin, direction: direction, against: Self.field, maxDistance: 900)
            let fast = grid.firstHit(origin: origin, direction: direction, maxDistance: 900)
            #expect(slow?.index == fast?.index, "ray \(i): \(String(describing: slow)) against \(String(describing: fast))")
            if let slow, let fast { #expect(abs(slow.distance - fast.distance) < 1e-3); hits += 1 }
        }
        #expect(hits > 100, "only \(hits) rays met anything — the field is not testing the grid")
    }

    /// A round's step: short segments, many of them missing everything.
    @Test("A shot's step meets the same volume as testing every one")
    func segmentsAgree() {
        let grid = StaticVolumes(Self.field)
        for i in 0..<2000 {
            let a = Float(i) * 0.37
            let start = SIMD3<Float>(cos(a) * Float(i % 300), Float(i % 9), sin(a * 0.7) * Float(i % 280))
            let end = start + SIMD3(sin(a) * 9, -0.4, cos(a) * 9)
            let slow = Volume.firstHit(segmentFrom: start, to: end, against: Self.field)
            let fast = grid.firstHit(segmentFrom: start, to: end)
            #expect(slow?.index == fast?.index, "step \(i)")
        }
    }

    @Test("Straight down, and from outside the field toward it")
    func edgeCases() {
        let box = Volume(localBounds: BoundingBox(minimum: SIMD3(-1, 0, -1), maximum: SIMD3(1, 2, 1)),
                         transform: simd_float4x4(translation: SIMD3(100, 0, 100)))
        let grid = StaticVolumes([box])
        #expect(grid.firstHit(origin: SIMD3(100, 50, 100), direction: SIMD3(0, -1, 0))?.distance == 48)
        let far = grid.firstHit(origin: SIMD3(-900, 1, 100), direction: SIMD3(1, 0, 0))
        #expect(far?.index == 0 && abs(far!.distance - 999) < 1e-3)
        #expect(grid.firstHit(origin: SIMD3(-900, 1, 100), direction: SIMD3(-1, 0, 0)) == nil)
        #expect(StaticVolumes([]).firstHit(origin: .zero, direction: SIMD3(1, 0, 0)) == nil)
    }
}
