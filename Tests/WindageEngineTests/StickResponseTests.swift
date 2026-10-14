//
//  StickResponseTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

struct StickResponseTests {

    private let deadzone: Float = 0.15
    private let exponent: Float = 2.0

    private func shaped(_ x: Float, _ y: Float) -> SIMD2<Float> {
        StickResponse.shaped(SIMD2(x, y), deadzone: deadzone, exponent: exponent)
    }

    @Test("A resting stick produces nothing")
    func restIsSilent() {
        #expect(shaped(0, 0) == .zero)
        // Sticks wander a few percent at rest; that must not turn the camera.
        #expect(shaped(0.05, -0.04) == .zero)
    }

    @Test("Full deflection is full output")
    func fullDeflectionIsFull() {
        let output = shaped(0, 1)
        #expect(abs(simd_length(output) - 1) < 1e-5)
    }

    /// Sticks can read slightly past 1 on the diagonals. Full speed should be full speed, not a
    /// little more, or diagonal movement outruns straight movement.
    @Test("Over-range readings are clamped")
    func overRangeIsClamped() {
        let output = shaped(0.9, 0.9)   // magnitude ~1.27
        #expect(simd_length(output) <= 1.0001)
    }

    /// The bug a per-axis deadzone produces: at 45° each axis is only 0.71 of the magnitude, so a
    /// square deadzone swallows diagonal input that a radial one passes.
    @Test("The deadzone is radial, so diagonals are not swallowed")
    func deadzoneIsRadialNotSquare() {
        // Both axes sit below the deadzone individually, but the magnitude (0.198) clears it.
        let output = shaped(0.14, 0.14)
        #expect(output != .zero)
    }

    @Test("Direction is preserved exactly")
    func directionSurvives() {
        let raw = SIMD2<Float>(0.6, -0.8)
        let output = StickResponse.shaped(raw, deadzone: deadzone, exponent: exponent)
        let rawDirection = raw / simd_length(raw)
        let outDirection = output / simd_length(output)
        #expect(simd_length(rawDirection - outDirection) < 1e-5)
    }

    @Test("Output rises smoothly from zero at the deadzone edge")
    func noStepAtTheEdge() {
        // Just past the threshold the output must be near zero, not jump to a step.
        let justPast = shaped(deadzone + 0.001, 0)
        #expect(simd_length(justPast) < 0.01)
    }

    @Test("Pushing further always gives more")
    func responseIsMonotonic() {
        var previous: Float = -1
        for magnitude in stride(from: Float(0.16), through: 1.0, by: 0.02) {
            let output = simd_length(shaped(magnitude, 0))
            #expect(output > previous)
            previous = output
        }
    }
}

/// Stick look is a **rate**; mouse look is a **displacement**. Confusing the two is the single
/// easiest way to make aiming feel wrong on one device or the other.
struct StickLookTests {

    @Test("Holding the stick twice as long turns twice as far")
    func stickLookIsTimeScaled() {
        var short = Camera(), long = Camera()
        short.turn(rate: SIMD2(1, 0), deltaTime: 0.1)
        long.turn(rate: SIMD2(1, 0), deltaTime: 0.2)
        #expect(abs(long.yaw - 2 * short.yaw) < 1e-5)
    }

    @Test("Stick look does not depend on how the time was divided")
    func stickLookIsStepRateIndependent() {
        var coarse = Camera(), fine = Camera()
        for _ in 0..<60 { coarse.turn(rate: SIMD2(0.5, 0), deltaTime: 1.0 / 60.0) }
        for _ in 0..<240 { fine.turn(rate: SIMD2(0.5, 0), deltaTime: 1.0 / 240.0) }
        #expect(abs(coarse.yaw - fine.yaw) < 1e-4)
    }

    @Test("Stick pitch is clamped like mouse pitch")
    func stickPitchIsClamped() {
        var camera = Camera()
        for _ in 0..<600 { camera.turn(rate: SIMD2(0, 1), deltaTime: 1.0 / 60.0) }
        #expect(camera.pitch <= Camera.pitchLimit)
    }

    @Test("Stick right turns right, matching the mouse")
    func stickAndMouseAgreeOnDirection() {
        var byStick = Camera(), byMouse = Camera()
        byStick.turn(rate: SIMD2(1, 0), deltaTime: 0.1)
        byMouse.look(mouseDelta: SIMD2(100, 0))
        // Both should decrease yaw — positive yaw is left.
        #expect(byStick.yaw < 0)
        #expect(byMouse.yaw < 0)
    }
}

@Suite("Stick response — values that used to break it")
struct StickResponseGuardTests {
    @Test("A negative, NaN or full dead zone, and a bad exponent, still give a finite answer")
    func guarded() {
        for deadzone in [Float(-1), .nan, 1, 2] {
            for exponent in [Float(2), 0, -1, .nan] {
                for raw in [SIMD2<Float>(0, 0), SIMD2(0.5, 0), SIMD2(1, 1)] {
                    let out = StickResponse.shaped(raw, deadzone: deadzone, exponent: exponent)
                    #expect(out.x.isFinite && out.y.isFinite, "\(raw) with \(deadzone), \(exponent) gave \(out)")
                }
            }
        }
        #expect(StickResponse.shaped(.zero, deadzone: -1, exponent: 2) == .zero, "a resting stick moved")
    }
}
