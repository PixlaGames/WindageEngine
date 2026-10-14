//
//  VolumeTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

struct VolumeTests {

    private let crate = Volume(localBounds: BoundingBox(minimum: SIMD3(-0.5, 0, -0.5),
                                                  maximum: SIMD3(0.5, 1, 0.5)))

    private func placed(_ volume: Volume, at position: SIMD3<Float>) -> Volume {
        var moved = volume
        moved.transform = simd_float4x4(translation: position)
        return moved
    }

    /// **The failure a stored world box produces**: a round passes through something that is visibly
    /// in the way, because the box is where the thing used to be.
    @Test("World bounds follow the transform")
    func boundsFollowTheTransform() {
        let before = placed(crate, at: SIMD3(0, 0, -10)).worldBounds
        let after = placed(crate, at: SIMD3(0, 0, -60)).worldBounds
        #expect(abs((after.minimum.z - before.minimum.z) + 50) < 1e-4)
    }

    /// Rotation too, and this is the case transforming two corners gets wrong — a rotated "box" from
    /// min and max alone can come out inside-out.
    @Test("World bounds follow a rotation, not just a translation")
    func boundsFollowARotation() {
        var wide = Volume(localBounds: BoundingBox(minimum: SIMD3(-3, 0, -0.5),
                                             maximum: SIMD3(3, 1, 0.5)))
        let alongX = wide.worldBounds
        wide.transform = simd_float4x4(rotationAngle: .pi / 2, axis: SIMD3(0, 1, 0))
        let alongZ = wide.worldBounds

        #expect(alongX.size.x > 5 && alongX.size.z < 1.1)
        #expect(alongZ.size.z > 5 && alongZ.size.x < 1.1, "the long axis did not turn with it")
        #expect(alongZ.minimum.y <= alongZ.maximum.y, "the box came out inside-out")
    }

    /// **The seam, demonstrated rather than argued.** Whatever a thing is, a bullet asks it one
    /// question, and one array answers.
    @Test("One hit test covers everything in the list, nearest first")
    func nearestVolumeStopsTheRound() throws {
        let far = placed(crate, at: SIMD3(0, 0, -60))
        let near = placed(crate, at: SIMD3(0, 0, -30))

        let hit = try #require(Volume.firstHit(segmentFrom: SIMD3(0, 0.5, 0),
                                               to: SIMD3(0, 0.5, -200),
                                               against: [far, near]))
        #expect(hit.index == 1, "the further volume stopped the round")
        #expect(abs(hit.distance - 29.5) < 0.6, "stopped at \(hit.distance) m rather than about 30")
    }

    @Test("A shot that passes to one side hits nothing")
    func aMissIsAMiss() {
        let aside = placed(crate, at: SIMD3(40, 0, -30))
        #expect(Volume.firstHit(segmentFrom: SIMD3(0, 0.5, 0),
                                to: SIMD3(0, 0.5, -200),
                                against: [aside]) == nil)
    }

    /// **Ranging and hitting must agree about what is out there.** They share the volume list for
    /// that reason; if the two forms disagreed, the reticle would read a distance the round does not
    /// travel — which is worse than no readout, because the player acts on it.
    @Test("The ray form and the segment form agree about the same scene")
    func rayAndSegmentAgree() throws {
        let scene = [placed(crate, at: SIMD3(0, 0, -60)),
                     placed(crate, at: SIMD3(0, 0, -30)),
                     placed(crate, at: SIMD3(9, 0, -20))]
        let origin = SIMD3<Float>(0, 0.5, 0)
        let direction = SIMD3<Float>(0, 0, -1)

        let ranged = try #require(Volume.firstHit(origin: origin, direction: direction, against: scene))
        let struck = try #require(Volume.firstHit(segmentFrom: origin,
                                                  to: origin + direction * 500,
                                                  against: scene))
        #expect(ranged.index == struck.index)
        #expect(abs(ranged.distance - struck.distance) < 1e-3)
    }

    /// A ray form that reported things behind the shooter would range the scenery at their back.
    @Test("The ray form ignores what is behind the origin")
    func rayIgnoresWhatIsBehind() {
        let behind = placed(crate, at: SIMD3(0, 0, 30))
        #expect(Volume.firstHit(origin: SIMD3(0, 0.5, 0),
                                direction: SIMD3(0, 0, -1),
                                against: [behind]) == nil)
    }

    /// **A measured box is an underestimate for anything that moves inside it** — a skinned mesh's
    /// bounds are the bind pose's, and a raised arm leaves them.
    @Test("A box can be widened, and a negative margin is allowed to invert it")
    func boxExpands() {
        let box = BoundingBox(minimum: SIMD3(-1, 0, -1), maximum: SIMD3(1, 2, 1))
        let wide = box.expanded(by: 0.5)
        #expect(wide.minimum == SIMD3(-1.5, -0.5, -1.5))
        #expect(wide.maximum == SIMD3(1.5, 2.5, 1.5))
        #expect(wide.contains(SIMD3(1.4, 2.4, 0)))
        #expect(!box.contains(SIMD3(1.4, 2.4, 0)))

        // Shrinking past the middle inverts it rather than clamping: a caller asking for that is
        // asking for an empty volume, and quietly fixing it would hide the mistake.
        let inverted = box.expanded(by: -5)
        #expect(inverted.minimum.x > inverted.maximum.x)
        #expect(!inverted.contains(.zero))
    }
}
