//
//  OrbitCameraInterpolationTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// The camera drawn between two fixed simulation steps (``OrbitCamera/interpolated(from:to:alpha:)``).
struct OrbitCameraInterpolationTests {
    private func camera(focus: SIMD3<Float>, yaw: Float, clearance: Float? = nil) -> OrbitCamera {
        var c = OrbitCamera()
        c.focus = focus
        c.yaw = yaw
        if let clearance { c.constrain(to: clearance, deltaTime: 1) }
        return c
    }

    @Test("Halfway between two steps is halfway, and the ends are the steps")
    func halfwayIsHalfway() {
        let a = camera(focus: SIMD3(0, 0, 0), yaw: 0.2), b = camera(focus: SIMD3(2, 0, -4), yaw: 0.6)
        let half = OrbitCamera.interpolated(from: a, to: b, alpha: 0.5)
        #expect(simd_distance(half.focus, SIMD3(1, 0, -2)) < 1e-5)
        #expect(abs(half.yaw - 0.4) < 1e-5)
        #expect(simd_distance(OrbitCamera.interpolated(from: a, to: b, alpha: 0).position, a.position) < 1e-4)
        #expect(simd_distance(OrbitCamera.interpolated(from: a, to: b, alpha: 1).position, b.position) < 1e-4)
    }

    @Test("A turn across ±π goes the short way")
    func turnsTheShortWay() {
        let a = camera(focus: .zero, yaw: .pi - 0.1), b = camera(focus: .zero, yaw: -.pi + 0.1)
        let half = OrbitCamera.interpolated(from: a, to: b, alpha: 0.5)
        // Halfway the short way round is facing ±π, not 0.
        #expect(abs(abs(sin(half.yaw))) < 1e-4 && cos(half.yaw) < -0.99)
    }

    @Test("The scenery's pull on the camera is blended too")
    func clearanceIsBlended() {
        let open = camera(focus: .zero, yaw: 0), close = camera(focus: .zero, yaw: 0, clearance: 2.5)
        #expect(close.workingDistance == 2.5)
        let half = OrbitCamera.interpolated(from: open, to: close, alpha: 0.5)
        #expect(abs(half.workingDistance - (open.workingDistance + 2.5) / 2) < 1e-4)
    }
}
