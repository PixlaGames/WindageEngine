//
//  FixedTimestepTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

/// Guards the property the whole fixed-timestep arrangement exists for: **simulation results must
/// not depend on frame rate.**
///
/// A bullet is in flight for seconds under gravity and drag, each step feeding the next. If the
/// number and size of those steps varied with how fast the machine happened to be drawing, the same
/// shot would land differently on a 60 Hz and a 120 Hz display — and differently again on a frame
/// that stuttered. These tests pin that down in pure arithmetic, with no GPU involved.
struct FixedTimestepTests {

    private let rate: Double = 120

    @Test("A frame shorter than one step advances nothing yet")
    func subStepFrameDefers() {
        var clock = FixedTimestep(stepsPerSecond: rate)
        #expect(clock.advance(by: 1.0 / 1000.0) == 0)
        #expect(clock.totalSteps == 0)
        #expect(clock.simulatedTime == 0)
    }

    @Test("A frame spanning several steps runs all of them")
    func longFrameCatchesUp() {
        var clock = FixedTimestep(stepsPerSecond: rate)
        #expect(clock.advance(by: 5.0 / 120.0) == 5)
        #expect(clock.totalSteps == 5)
    }

    /// The load-bearing test. Two machines see one second of wall-clock time arrive in completely
    /// different chunks — a steady 120 Hz, a steady 60 Hz, and a ragged one that stutters — and all
    /// three must simulate the identical number of steps.
    @Test("Frame rate does not change how much simulation happens")
    func identicalSimulationAcrossFrameRates() {
        func stepsOverOneSecond(frameTimes: [Double]) -> Int {
            var clock = FixedTimestep(stepsPerSecond: rate)
            for frameTime in frameTimes { clock.advance(by: frameTime) }
            return clock.totalSteps
        }

        let smooth120 = Array(repeating: 1.0 / 120.0, count: 120)
        let smooth60 = Array(repeating: 1.0 / 60.0, count: 60)
        let ragged = [0.004, 0.030, 0.008, 0.008, 0.051, 0.002, 0.017, 0.009, 0.121,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016,
                      0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016, 0.016]

        #expect(stepsOverOneSecond(frameTimes: smooth120) == 120)
        #expect(stepsOverOneSecond(frameTimes: smooth60) == 120)
        // The ragged run covers ~1 s in wildly uneven pieces and must land on the same count.
        let raggedTotal = ragged.reduce(0, +)
        #expect(stepsOverOneSecond(frameTimes: ragged) == Int(raggedTotal * rate))
    }

    /// Simulated time only ever advances in whole steps, so it is exactly reproducible rather than
    /// accumulating whatever float error the frame durations happened to carry.
    @Test("Simulated time advances only in whole steps")
    func simulatedTimeIsQuantised() {
        var clock = FixedTimestep(stepsPerSecond: rate)
        for _ in 0..<97 { clock.advance(by: 0.0071) }
        #expect(abs(clock.simulatedTime - Double(clock.totalSteps) * clock.stepDuration) < 1e-12)
    }

    /// A long stall must not become a burst of steps that takes longer than a frame, making the
    /// next delta larger still. Time is deliberately lost instead.
    @Test("A long stall is clamped rather than spiralling")
    func stallIsClamped() {
        var clock = FixedTimestep(stepsPerSecond: rate, maxFrameTime: 0.25)
        let steps = clock.advance(by: 30.0)   // a breakpoint, or a dragged window
        #expect(steps == Int(0.25 * rate))
    }

    @Test("The clock never runs backwards")
    func negativeDeltaIsIgnored() {
        var clock = FixedTimestep(stepsPerSecond: rate)
        #expect(clock.advance(by: -5) == 0)
        #expect(clock.simulatedTime == 0)
    }

    @Test("Interpolation alpha stays in 0..<1")
    func alphaStaysNormalised() {
        var clock = FixedTimestep(stepsPerSecond: rate)
        for frameTime in stride(from: 0.001, through: 0.05, by: 0.0013) {
            clock.advance(by: frameTime)
            #expect(clock.interpolation >= 0)
            #expect(clock.interpolation < 1)
        }
    }
}
