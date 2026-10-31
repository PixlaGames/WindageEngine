//
//  CharacterFacingTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Which way a third-person character faces as it moves.
///
/// **Found by driving a game:** holding back turned the character round to face the camera, so the step back that
/// dodges a counter-blow left the foe behind you; and a swing thrown while strafing twisted back to the strafe inside
/// the blow.
@Suite("Character facing")
struct CharacterFacingTests {

    /// A second of a held input under a camera looking down −Z, at 60 steps a second.
    private func moved(_ axis: SIMD2<Float>, from yaw: Float = 0, viewYaw: Float = 0, held: Bool = false,
                       seconds: Float = 1, steps: Int = 60) -> CharacterFacing {
        var facing = CharacterFacing(yaw: yaw)
        facing.isHeld = held
        let step = seconds / Float(steps)
        for _ in 0..<steps { facing.turn(toward: axis, viewYaw: viewYaw, deltaTime: step) }
        return facing
    }

    private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.02 }

    @Test("Forward keeps facing forward, and is not backing away")
    func forwardUnchanged() {
        let facing = moved(SIMD2(0, 1))
        #expect(near(facing.yaw, 0))
        #expect(!facing.isBackpedaling)
    }

    @Test("A strafe turns the character to face it")
    func strafeTurns() {
        let facing = moved(SIMD2(1, 0))
        #expect(near(facing.yaw, -.pi / 2), "facing \(facing.yaw)")
        #expect(!facing.isBackpedaling)
    }

    @Test("Backing away keeps facing forward, and says so")
    func backpedalFacesForward() {
        let facing = moved(SIMD2(0, -1))
        #expect(near(facing.yaw, 0), "facing \(facing.yaw)")
        #expect(facing.isBackpedaling)
    }

    /// **Mirrored, so it is continuous.** Backing away to the right faces forward-right — the same facing as walking
    /// forward-right — rather than flipping the moment a strafe gains a backward component.
    @Test("Backing away diagonally faces the mirrored forward diagonal")
    func diagonalBackpedal() {
        let back = moved(simd_normalize(SIMD2(1, -1)))
        let forward = moved(simd_normalize(SIMD2(1, 1)))
        #expect(near(back.yaw, -.pi / 4), "facing \(back.yaw)")
        #expect(near(back.yaw, forward.yaw))
    }

    /// Movement is in the camera's frame: with the camera swung a quarter turn, forward is the camera's forward.
    @Test("Forward is the camera's forward")
    func followsTheView() {
        let facing = moved(SIMD2(0, 1), viewYaw: .pi / 2)
        #expect(near(facing.yaw, .pi / 2))
        let along = CharacterFacing.direction(of: SIMD2(0, 1), viewYaw: .pi / 2)
        #expect(simd_distance(along, SIMD3(-1, 0, 0)) < 1e-5)
    }

    @Test("A held facing survives a strafe")
    func heldFacingStays() {
        let facing = moved(SIMD2(1, 0), held: true)
        #expect(facing.yaw == 0)
    }

    /// Held, it still knows it is backing away — the stride runs backwards through a swing stepped back from.
    @Test("A held facing still reports backing away")
    func heldStillBackpedals() {
        #expect(moved(SIMD2(0, -1), from: .pi, held: true).isBackpedaling == false)
        #expect(moved(SIMD2(0, -1), held: true).isBackpedaling)
    }

    @Test("Standing still neither turns nor backs away")
    func stillDoesNothing() {
        var facing = CharacterFacing(yaw: 1)
        facing.turn(toward: SIMD2(0, -1), viewYaw: 0, deltaTime: 1.0 / 60)
        facing.turn(toward: .zero, viewYaw: 0, deltaTime: 1)
        #expect(!facing.isBackpedaling)
        let before = facing.yaw
        facing.turn(toward: .zero, viewYaw: 0, deltaTime: 1)
        #expect(facing.yaw == before)
    }

    /// The short way: from just short of half a turn to just past it is a small turn, not nearly a whole one.
    @Test("Turning takes the short way round")
    func shortWay() {
        var facing = CharacterFacing(yaw: .pi - 0.05)
        var travelled: Float = 0
        for _ in 0..<10 {
            let before = facing.yaw
            // Facing −Z + a hair to the right, from just short of facing +Z on the left.
            facing.turn(toward: SIMD2(0, -1), viewYaw: .pi + 0.1, deltaTime: 1.0 / 60)
            travelled += abs(facing.yaw - before)
        }
        #expect(travelled < 0.5, "it travelled \(travelled) rad; the short way is about 0.15")
    }

    /// Frame-rate independence, the property the rest of the third-person pieces hold.
    @Test("The same second of turning is the same turn at any frame rate")
    func turningIsTimeKeyed() {
        let at60 = moved(SIMD2(1, 0), seconds: 0.08, steps: 5)
        let at240 = moved(SIMD2(1, 0), seconds: 0.08, steps: 20)
        #expect(abs(at60.yaw - at240.yaw) < 0.01)
        #expect(at60.yaw < -0.5 && at60.yaw > -.pi / 2, "partway round after 80 ms: \(at60.yaw)")
    }

    // MARK: - Pace

    /// **Slower backwards is what makes stepping back a decision**, and in proportion to how backward the input is.
    @Test("Backing away is slowed by its backward share, a strafe not at all")
    func backpedalPace() {
        let facing = CharacterFacing()
        #expect(abs(facing.backpedalled(4.5, axis: SIMD2(0, -1)) - 4.5 * 0.6) < 1e-5)
        #expect(facing.backpedalled(4.5, axis: SIMD2(1, 0)) == 4.5)
        #expect(facing.backpedalled(4.5, axis: SIMD2(0, 1)) == 4.5)
        let diagonal = facing.backpedalled(4.5, axis: simd_normalize(SIMD2(1, -1)))
        #expect(abs(diagonal - 4.5 * (1 - 0.4 * Float(0.5).squareRoot())) < 1e-4)
    }

    /// **Never below the walk clip's own pace**, or the walk plays slower than it was animated — and never above the
    /// pace asked for, when that is slower still.
    @Test("Backing away is not slowed below the minimum")
    func floorAtMinimum() {
        let facing = CharacterFacing()
        #expect(facing.backpedalled(1.45, axis: SIMD2(0, -1), minimum: 1.45) == 1.45)
        #expect(facing.backpedalled(1.2, axis: SIMD2(0, -1), minimum: 1.45) == 1.2)
        #expect(abs(facing.backpedalled(4.5, axis: SIMD2(0, -1), minimum: 1.45) - 4.5 * 0.6) < 1e-5)
        #expect(facing.backpedalled(4.5, axis: .zero, minimum: 1.45) == 4.5)
    }
}
