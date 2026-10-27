import Foundation
import Testing
import simd
@testable import WindageEngine

/// Measuring a stick, and what the measurement is allowed to conclude.
///
/// **Two faults that look identical from the sofa.** A stick that rests off center pulls one way for ever; a stick whose
/// pot is worn comes back to a different place depending on which way it was last pushed. Only the first has a center
/// to subtract; the second needs a dead zone wide enough to swallow the wander. These tests keep the two apart.
@Suite("Stick calibration")
struct StickCalibrationTests {

    /// The fixed guess a game used before measuring: wide enough to cover a bad pad.
    private let guess: Float = 0.18

    private func deflection(_ raw: SIMD2<Float>, _ calibration: StickCalibration) -> SIMD2<Float> {
        StickResponse.shaped(raw, calibration: calibration, exponent: 1)
    }
    private func guessed(_ raw: SIMD2<Float>) -> SIMD2<Float> {
        StickResponse.shaped(raw, deadzone: guess, exponent: 1)
    }

    private func rest(_ samples: [SIMD2<Float>]) -> StickRest {
        var rest = StickRest()
        for sample in samples { rest.observe(sample) }
        return rest
    }

    private func steady(_ point: SIMD2<Float>, count: Int = 60) -> [SIMD2<Float>] {
        Array(repeating: point, count: count)
    }

    @Test("A healthy stick earns a narrower dead zone than the guess")
    func healthyStickGainsTravel() throws {
        let measured = try #require(rest(steady(SIMD2(0.004, -0.002))).calibration())
        #expect(measured.deadzone == StickRest.floor)
        #expect(measured.deadzone < guess, "measuring gained nothing")
        #expect(simd_length(measured.center) < 0.01)
    }

    @Test("A stick that rests off center has that center subtracted")
    func classicDriftIsSubtracted() throws {
        let measured = try #require(rest(steady(SIMD2(0, 0.12))).calibration())
        #expect(abs(measured.center.y - 0.12) < 0.001)
        #expect(deflection(SIMD2(0, 0.12), measured) == .zero)
    }

    /// **What a drifting stick costs is evenness at all.** Resting 0.12 forward under the fixed guess, a gentle forward
    /// push walks and the same push backward does nothing. Measured, equal pushes are (nearly) equal.
    @Test("Equal pushes either way move equally, once the stick is measured")
    func measuringMakesTheTwoDirectionsMatch() throws {
        let measured = try #require(rest(steady(SIMD2(0, 0.12))).calibration())
        let push: Float = 0.10
        #expect(simd_length(guessed(SIMD2(0, 0.12 + push))) > 0 && simd_length(guessed(SIMD2(0, 0.12 - push))) == 0,
                "the fault this fixes is not present, so the fix proves nothing")
        let forward = simd_length(deflection(SIMD2(0, 0.12 + push), measured))
        let back = simd_length(deflection(SIMD2(0, 0.12 - push), measured))
        #expect(back > 0, "pushing back still did nothing")
        #expect(back > forward * 0.7, "forward \(forward) and back \(back) are still lopsided")
    }

    /// **Full push must still be full push**, on the side the stick leans away from.
    @Test("Full deflection still reaches full, every way")
    func theEdgeStillMeansOne() throws {
        let measured = try #require(rest(steady(SIMD2(0, 0.12))).calibration())
        for direction in [SIMD2<Float>(0, 1), SIMD2(0, -1), SIMD2(1, 0), SIMD2(-1, 0)] {
            let travel = simd_length(deflection(direction, measured))
            #expect(abs(travel - 1) < 0.01, "pushing \(direction) reached only \(travel)")
        }
    }

    @Test("A stick that wanders is given a dead zone that covers the wandering")
    func wornPotWidensRatherThanShifts() throws {
        let wobble = (0..<60).map { n in SIMD2<Float>(0, n.isMultiple(of: 2) ? 0.09 : -0.09) }
        let measured = try #require(rest(wobble).calibration())
        #expect(measured.deadzone > 0.09)
        #expect(deflection(SIMD2(0, 0.09), measured) == .zero)
        #expect(deflection(SIMD2(0, -0.09), measured) == .zero)
    }

    @Test("A stick that was being held is refused, not recorded")
    func aHeldStickIsRefused() {
        var samples = steady(SIMD2(0, 0.02), count: 40)
        samples[20] = SIMD2(0, 0.85)
        let taken = rest(samples)
        #expect(taken.wasHeld)
        #expect(taken.calibration() == nil)
    }

    @Test("Too short a sample is refused")
    func aShortSampleIsRefused() {
        #expect(rest(steady(.zero, count: 5)).calibration() == nil)
    }

    @Test("The center is a median, so a single twitch does not move it")
    func theCenterResistsATwitch() throws {
        var samples = steady(SIMD2(0, 0.10), count: 60)
        samples[30] = SIMD2(0, 0.40)
        let measured = try #require(rest(samples).calibration())
        #expect(abs(measured.center.y - 0.10) < 0.005)
    }

    /// The engine's shaping for an unmeasured stick is unchanged by any of this, curve included.
    @Test("An unmeasured stick shapes exactly as before")
    func unmeasuredIsUnchanged() {
        for raw in [SIMD2<Float>(0.1, 0), SIMD2(0.5, 0.5), SIMD2(1, 0), SIMD2(0, -0.3), SIMD2(0.7, -0.7)] {
            for (deadzone, exponent) in [(Float(0.16), Float(1.3)), (0.10, 2.0), (0.0, 1.0)] {
                let before = Self.oldShaped(raw, deadzone: deadzone, exponent: exponent)
                let now = StickResponse.shaped(raw, deadzone: deadzone, exponent: exponent)
                #expect(simd_length(before - now) < 1e-6, "\(raw) at \(deadzone), \(exponent): \(before) became \(now)")
            }
        }
    }

    /// `StickResponse.shaped` as it was before calibration, kept to hold the new one to it.
    private static func oldShaped(_ raw: SIMD2<Float>, deadzone: Float, exponent: Float) -> SIMD2<Float> {
        let magnitude = simd_length(raw)
        guard magnitude > deadzone else { return .zero }
        return raw / magnitude * pow(min((magnitude - deadzone) / (1 - deadzone), 1), exponent)
    }

    @Test("A calibration survives being saved, and a game's older `centre` spelling still reads")
    func itRoundTrips() throws {
        let pad = PadCalibration(left: StickCalibration(center: SIMD2(0.01, -0.12), deadzone: 0.2), right: nil)
        #expect(try JSONDecoder().decode(PadCalibration.self, from: JSONEncoder().encode(pad)) == pad)
        let older = #"{"left":{"centre":[0.01,-0.12],"deadzone":0.2},"right":{"centre":[0,0],"deadzone":0.18}}"#
        let read = try JSONDecoder().decode(PadCalibration.self, from: Data(older.utf8))
        #expect(read.left?.center == SIMD2(0.01, -0.12) && read.right?.deadzone == 0.18)
    }

    @Test("Player settings carry the calibration, and a file from before it still loads")
    func playerSettingsCarryIt() throws {
        var settings = PlayerSettings()
        settings.padCalibration = PadCalibration(left: StickCalibration(center: SIMD2(0, 0.1), deadzone: 0.08))
        let back = try JSONDecoder().decode(PlayerSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.padCalibration == settings.padCalibration)
        let older = try JSONDecoder().decode(PlayerSettings.self, from: Data(#"{"volume":0.5}"#.utf8))
        #expect(older.padCalibration == .unmeasured && older.volume == 0.5)
    }

    @Test("Measuring over three seconds finishes with both sticks, or refuses a held one")
    func measuringBothSticks() throws {
        var measurement = PadMeasurement()
        measurement.begin(at: 100, seconds: 3)
        var t = 100.0
        while t < 103.1 {
            measurement.observe(left: SIMD2(0, 0.12), right: SIMD2(0.01, 0), at: t)
            t += 1.0 / 60
        }
        guard case .finished(let pad) = measurement.state else { Issue.record("\(measurement.state)"); return }
        #expect(abs((pad.left?.center.y ?? 0) - 0.12) < 0.001 && pad.right != nil)

        measurement.begin(at: 200)
        t = 200
        while t < 203.1 {
            measurement.observe(left: SIMD2(0, t > 201 && t < 201.5 ? 0.9 : 0), right: .zero, at: t)
            t += 1.0 / 60
        }
        guard case .refused = measurement.state else { Issue.record("a held stick was recorded"); return }
    }
}

@Suite("A frozen pad report")
struct FrozenStickWatchTests {
    /// **Measured, not imagined**: an Xbox pad repeated (0.0146, 0.6082) for thirty seconds with nobody touching it.
    @Test("A non-zero reading that never moves is disbelieved after two seconds; a moving one never is")
    func frozenIsCaught() {
        var watch = FrozenStickWatch()
        var t = 0.0
        while t < 1.9 {
            let frozen = watch.observe(left: SIMD2(0.0146, 0.6082), right: .zero, at: t)
            #expect(!frozen)
            t += 1.0 / 60
        }
        while t < 2.5 { _ = watch.observe(left: SIMD2(0.0146, 0.6082), right: .zero, at: t); t += 1.0 / 60 }
        #expect(watch.isFrozen)
        let moved = watch.observe(left: SIMD2(0.0147, 0.6082), right: .zero, at: t)
        #expect(!moved, "a moved report is believed again")

        var held = FrozenStickWatch()
        t = 0
        var wobble: Float = 0
        while t < 5 {
            wobble += 0.0001
            let frozen = held.observe(left: SIMD2(0, 0.6 + wobble), right: .zero, at: t)
            #expect(!frozen)
            t += 1.0 / 60
        }
    }

    @Test("A stick at rest repeating its rest is not a fault")
    func restIsFine() {
        var watch = FrozenStickWatch()
        var t = 0.0
        while t < 5 {
            let frozen = watch.observe(left: SIMD2(0.01, 0), right: .zero, at: t)
            #expect(!frozen)
            t += 1.0 / 60
        }
    }
}
