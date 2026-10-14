import Testing
import simd
import WindageEngine
@testable import WindageSampleCore

@MainActor
struct SampleRubbleTests {
    private let buildings = [
        BoundingBox(minimum: SIMD3(-2, 0, -2), maximum: SIMD3(2, 3, 2)),
        BoundingBox(minimum: SIMD3(6, 0, 1), maximum: SIMD3(8, 1, 3)),
    ]

    @Test func debrisLiesAmongTheBuildingsNeverInsideThem() {
        let pieces = SampleRubble.transforms(around: buildings)
        #expect(pieces.count > 60, "most tries find room: \(pieces.count)")
        for piece in pieces {
            let p = piece.columns.3
            #expect(p.y == 0, "on the ground")
            #expect(p.x >= -6 && p.x <= 12 && p.z >= -6 && p.z <= 7, "within the margin")
            for box in buildings {
                let inside = p.x > box.minimum.x && p.x < box.maximum.x && p.z > box.minimum.z && p.z < box.maximum.z
                #expect(!inside)
            }
        }
    }

    @Test func theSameLevelGivesTheSameDebris() {
        #expect(SampleRubble.transforms(around: buildings) == SampleRubble.transforms(around: buildings))
    }

    @Test func noBuildingsNoDebris() {
        #expect(SampleRubble.transforms(around: []).isEmpty)
    }

    @Test func piecesAreEvenlySizedSoNormalsNeedNoInverse() {
        for piece in SampleRubble.transforms(around: buildings) {
            let sx = simd_length(SIMD3(piece.columns.0.x, piece.columns.0.y, piece.columns.0.z))
            let sy = simd_length(SIMD3(piece.columns.1.x, piece.columns.1.y, piece.columns.1.z))
            #expect(abs(sx - sy) < 1e-5)
        }
    }

    @Test func oneKindIsOneBatch() {
        let batches = InstanceBatches(SampleRubble.transforms(around: buildings).map { ("box", $0) })
        #expect(batches.batches.count == 1)
    }
}
