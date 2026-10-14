//
//  AudioLoopTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// **Measured, because nobody here can listen.** An engine with no device, its mix pulled offline and
/// its level taken as RMS — the loops' falloff, the one-shots' for comparison, a loop outliving its
/// buffer, and silence after a stop.
@MainActor
@Suite("Audio — loops, measured offline")
struct AudioLoopTests {

    private static let rate = 48_000.0

    /// One second of noise at a fixed seed — a signal whose level is the same everywhere in it.
    private static let noise: [Float] = {
        var state: UInt32 = 0x9E37_79B9
        return (0..<48_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
    }()

    private func engine(_ configuration: AudioEngine.Configuration = .init()) throws -> AudioEngine {
        let audio = try AudioEngine(offlineSampleRate: AudioLoopTests.rate, configuration: configuration)
        try audio.load("noise", samples: AudioLoopTests.noise, sampleRate: AudioLoopTests.rate)
        audio.updateListener(position: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        return audio
    }

    /// The level of a stretch of the mix, both ears together.
    private func rms(_ audio: AudioEngine, seconds: Float) throws -> Float {
        let channels = try #require(audio.renderOffline(seconds: seconds))
        let all = channels.flatMap { $0 }
        return (all.reduce(0) { $0 + $1 * $1 } / Float(max(all.count, 1))).squareRoot()
    }

    /// Straight ahead, so both ears hear it alike and the level is only the distance.
    private func ahead(_ metres: Float) -> SIMD3<Float> { SIMD3(0, 0, -metres) }

    @Test("A loop falls off with the inverse law from 2 m: a quarter at 8, a tenth at 20")
    func loopFalloff() throws {
        let audio = try engine()
        let loop = try #require(audio.startLoop("noise", at: ahead(2)))
        _ = try rms(audio, seconds: 0.1)                    // let it settle
        let near = try rms(audio, seconds: 0.5)
        audio.moveLoop(loop, to: ahead(8))
        _ = try rms(audio, seconds: 0.1)
        let mid = try rms(audio, seconds: 0.5)
        audio.moveLoop(loop, to: ahead(20))
        _ = try rms(audio, seconds: 0.1)
        let far = try rms(audio, seconds: 0.5)
        print("AUDIO loop at 2/8/20 m: \(near), \(mid), \(far) → \(mid / near), \(far / near)")
        #expect(near > 0.01, "no sound at all: \(near)")
        #expect(abs(mid / near - 0.25) < 0.03, "8 m should be a quarter of 2 m: \(mid / near)")
        #expect(abs(far / near - 0.10) < 0.02, "20 m should be a tenth: \(far / near)")
    }

    /// **Why loops have their own spatialiser.** Through the one-shots' curve a sound at 20 m is still
    /// over half as loud as at 2 m — right for a shot across a range, wrong for a fire.
    ///
    /// > **And a measured quirk, not a model**: under HRTF a source *inside* its spatialiser's
    /// > reference distance is quieter, not flat — here 2 m reads 22% under 8 m, and the loops show
    /// > the same shape inside their 2 m. Beyond the reference the inverse law holds exactly, which is
    /// > what these assertions check.
    @Test("A one-shot through the range curve is over half as loud at 20 m as at 2, and follows its law past 8")
    func oneShotFalloffForComparison() throws {
        let audio = try engine()
        var levels: [Float] = []
        for metres: Float in [2, 8, 20] {
            audio.play("noise", at: ahead(metres))
            _ = try rms(audio, seconds: 0.3)
            levels.append(try rms(audio, seconds: 0.5))
            _ = try rms(audio, seconds: 0.3)                // let the voice finish
        }
        print("AUDIO one-shot at 2/8/20 m: \(levels) → \(levels[1] / levels[0]), \(levels[2] / levels[0])")
        #expect(abs(levels[2] / levels[1] - 8 / (8 + 0.9 * 12)) < 0.02, "the range curve from 8 to 20 m")
        #expect(levels[2] / levels[0] > 0.45, "a fire through this curve would carry: \(levels[2] / levels[0])")
    }

    @Test("A loop is still going, at the same level, long after its sound has come round")
    func loopKeepsGoing() throws {
        let audio = try engine()
        _ = audio.startLoop("noise", at: ahead(2))
        _ = try rms(audio, seconds: 0.1)
        let first = try rms(audio, seconds: 0.5)
        _ = try rms(audio, seconds: 2.0)                    // twice round a one-second sound
        let later = try rms(audio, seconds: 0.5)
        #expect(abs(later / first - 1) < 0.05, "faded or stopped: \(first) then \(later)")
    }

    @Test("Stopping a loop silences it, and its voice is used again")
    func stopSilences() throws {
        let audio = try engine()
        let loop = try #require(audio.startLoop("noise", at: ahead(2)))
        _ = try rms(audio, seconds: 0.2)
        audio.stopLoop(loop)
        _ = try rms(audio, seconds: 0.05)
        #expect(try rms(audio, seconds: 0.3) < 1e-4)
        #expect(audio.loopCount == 0)
        #expect(audio.startLoop("noise", at: ahead(2)) != nil && audio.loopCount == 1)
    }

    /// **The cue a game about long shots reads**: which way an impact came from. Written to check a
    /// switch to the spherical-head model — and it failed: 1.01× louder in the near ear, where HRTF
    /// gives 4.6×. The switch was reverted; this stays, so the cue cannot quietly go missing again.
    @Test("A one-shot off to the right is louder in the right ear, far away as well as near — and a loop")
    func directionSurvives() throws {
        for (metres, loop) in [(Float(5), false), (400, false), (5, true)] {
            let audio = try engine()
            if loop { _ = audio.startLoop("noise", at: SIMD3(metres, 0, 0)) } else { audio.play("noise", at: SIMD3(metres, 0, 0)) }
            _ = try #require(audio.renderOffline(seconds: 0.1))
            let channels = try #require(audio.renderOffline(seconds: 0.5))
            func level(_ c: [Float]) -> Float { (c.reduce(0) { $0 + $1 * $1 } / Float(max(c.count, 1))).squareRoot() }
            let left = level(channels[0]), right = level(channels[1])
            print("AUDIO \(loop ? "loop" : "one-shot") \(metres) m to the right: left \(left), right \(right), ratio \(right / max(left, 1e-9))")
            #expect(right > left * 1.5, "no left–right cue at \(metres) m: left \(left), right \(right)")
        }
    }

    /// **The setting's whole promise**: the loop drops by what it says, and a one-shot does not move.
    @Test("Half ambience is 6 dB off a loop and nothing off a one-shot")
    func ambienceScalesLoopsOnly() throws {
        func loopLevel(_ ambience: Float) throws -> Float {
            let audio = try engine()
            audio.loopVolume = ambience
            _ = audio.startLoop("noise", at: ahead(2))
            _ = try rms(audio, seconds: 0.3)
            return try rms(audio, seconds: 0.5)
        }
        func shotLevel(_ ambience: Float) throws -> Float {
            let audio = try engine()
            audio.loopVolume = ambience
            audio.play("noise", at: ahead(8))
            _ = try rms(audio, seconds: 0.3)
            return try rms(audio, seconds: 0.5)
        }
        let loopDrop = 20 * log10(try loopLevel(0.5) / loopLevel(1))
        let shotDrop = 20 * log10(try shotLevel(0.5) / shotLevel(1))
        print("AUDIO half ambience: loop \(loopDrop) dB, one-shot \(shotDrop) dB")
        #expect(abs(loopDrop + 6.02) < 0.1, "the loop moved \(loopDrop) dB")
        #expect(abs(shotDrop) < 0.05, "the one-shot moved \(shotDrop) dB")
        let silent = try engine()
        silent.loopVolume = 0
        _ = silent.startLoop("noise", at: ahead(2))
        _ = try rms(silent, seconds: 0.2)
        #expect(try rms(silent, seconds: 0.3) < 1e-5, "ambience off should be silence")
    }

    /// **The delay is counted on the audio clock.** It used to be a main-queue timer, which an offline
    /// render never waits for and a pause never held.
    @Test("A delayed one-shot is silent until its delay, then plays — counted in the mix's own time")
    func delayIsOnTheAudioClock() throws {
        let audio = try engine()
        _ = try rms(audio, seconds: 0.1)                       // the voices have rendered: "now" is 0.1 s
        audio.play("noise", at: ahead(8), delay: 0.5)
        let before = try rms(audio, seconds: 0.45)
        _ = try rms(audio, seconds: 0.1)
        let after = try rms(audio, seconds: 0.3)
        print("AUDIO delayed one-shot: before \(before), after \(after)")
        #expect(before < 1e-5, "it played early: \(before)")
        #expect(after > 0.01, "it never played: \(after)")
    }

    @Test("A delayed one-shot still waiting is cancelled by stop")
    func stopCancelsAWaitingOneShot() throws {
        let audio = try engine()
        audio.play("noise", at: ahead(8), delay: 0.2)
        audio.stop()
        #expect(audio.renderOffline(seconds: 0.5).map { $0.flatMap { $0 }.allSatisfy { $0 == 0 } } ?? true)
    }

    /// **Today's curves are the defaults, and a game may set its own.** The loops' measured falloff
    /// above is the default; here a loop given the one-shots' gentler curve carries further.
    @Test("The distance curves are a game's to set")
    func curvesAreConfigurable() throws {
        #expect(AudioEngine.Configuration().loopFalloff
                == .init(referenceDistance: 2, maximumDistance: 200, rolloffFactor: 1))
        #expect(AudioEngine.Configuration().oneShotFalloff
                == .init(referenceDistance: 8, maximumDistance: 2000, rolloffFactor: 0.9))
        #expect(AudioEngine.Configuration().voiceCount == 16)

        func ratio(_ configuration: AudioEngine.Configuration) throws -> Float {
            let audio = try engine(configuration)
            let loop = try #require(audio.startLoop("noise", at: ahead(2)))
            _ = try rms(audio, seconds: 0.1)
            let near = try rms(audio, seconds: 0.5)
            audio.moveLoop(loop, to: ahead(20))
            _ = try rms(audio, seconds: 0.1)
            return try rms(audio, seconds: 0.5) / near
        }
        var gentle = AudioEngine.Configuration()
        gentle.loopFalloff = gentle.oneShotFalloff
        let byDefault = try ratio(.init()), carried = try ratio(gentle)
        #expect(carried > byDefault * 3, "the gentler curve did not carry: \(carried) against \(byDefault)")
    }

    @Test("A sound that cannot be loaded says why")
    func loadFailuresThrow() throws {
        let audio = try engine()
        #expect(throws: AudioEngineError.soundNotFound("no-such-sound.wav")) {
            try audio.load("no-such-sound", bundle: .module)
        }
        #expect(throws: AudioEngineError.noSamples("empty")) {
            try audio.load("empty", samples: [], sampleRate: AudioLoopTests.rate)
        }
    }
}
