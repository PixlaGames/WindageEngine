//
//  AudioMixTests.swift
//  WindageEngineTests
//

import AppKit
import AVFoundation
import Foundation
import Testing
import simd
@testable import WindageEngine

/// The effects bus, unplaced sounds with pan and pitch, the meter and the player's sound settings —
/// **measured offline**, like the loops, because nobody here can listen.
@MainActor
@Suite("Audio — the mix, measured offline")
struct AudioMixTests {

    private static let rate = 48_000.0

    private static let noise: [Float] = {
        var state: UInt32 = 0x1234_5678
        return (0..<24_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
    }()

    private func engine() throws -> AudioEngine {
        let audio = try AudioEngine(offlineSampleRate: AudioMixTests.rate)
        try audio.load("noise", samples: AudioMixTests.noise, sampleRate: AudioMixTests.rate)
        audio.updateListener(position: .zero, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        return audio
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    private func level(_ audio: AudioEngine, seconds: Float) throws -> (left: Float, right: Float) {
        let channels = try #require(audio.renderOffline(seconds: seconds))
        return (rms(channels[0]), rms(channels[1]))
    }

    @Test("Half effects is half a one-shot, placed or unplaced, and nothing off a loop")
    func effectsBus() throws {
        func measure(effects: Float, _ play: (AudioEngine) -> Void) throws -> Float {
            let audio = try engine()
            audio.effectsVolume = effects
            play(audio)
            _ = try level(audio, seconds: 0.05)
            let l = try level(audio, seconds: 0.3)
            return l.left + l.right
        }
        let placedFull = try measure(effects: 1) { $0.play("noise", at: SIMD3(0, 0, -10)) }
        let placedHalf = try measure(effects: 0.5) { $0.play("noise", at: SIMD3(0, 0, -10)) }
        let unplacedFull = try measure(effects: 1) { $0.play("noise") }
        let unplacedHalf = try measure(effects: 0.5) { $0.play("noise") }
        let loopFull = try measure(effects: 1) { _ = $0.startLoop("noise", at: SIMD3(0, 0, -4)) }
        let loopHalf = try measure(effects: 0.5) { _ = $0.startLoop("noise", at: SIMD3(0, 0, -4)) }
        #expect(placedFull > 0.005 && unplacedFull > 0.005 && loopFull > 0.005, "something was silent")
        #expect(abs(placedHalf / placedFull - 0.5) < 0.05, "placed: \(placedHalf / placedFull)")
        #expect(abs(unplacedHalf / unplacedFull - 0.5) < 0.05, "unplaced: \(unplacedHalf / unplacedFull)")
        #expect(abs(loopHalf / loopFull - 1) < 0.05, "a loop moved with the effects: \(loopHalf / loopFull)")
    }

    @Test("An unplaced sound panned right is in the right ear; centred, in both")
    func pan() throws {
        let audio = try engine()
        audio.play("noise", pan: 1)
        _ = try level(audio, seconds: 0.05)
        let right = try level(audio, seconds: 0.2)
        #expect(right.right > right.left * 10, "panned right: \(right)")

        let centred = try engine()
        centred.play("noise")
        _ = try level(centred, seconds: 0.05)
        let both = try level(centred, seconds: 0.2)
        #expect(abs(both.left / both.right - 1) < 0.05, "centred: \(both)")
    }

    /// Half a second of noise at twice the speed lasts a quarter of a second.
    @Test("Twice the rate plays in half the time")
    func rate() throws {
        func lasts(_ rate: Float) throws -> Float {
            let audio = try engine()
            audio.play("noise", rate: rate)
            let channels = try #require(audio.renderOffline(seconds: 1))
            let last = channels[0].lastIndex { abs($0) > 1e-4 } ?? 0
            return Float(last) / Float(AudioMixTests.rate)
        }
        let normal = try lasts(1), fast = try lasts(2)
        #expect(abs(normal - 0.5) < 0.03 && abs(fast - 0.25) < 0.03, "normal \(normal) s, fast \(fast) s")
    }

    @Test("A stereo file at another rate plays unplaced, and loads from a URL")
    func stereoFromURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("we-stereo-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        for frame in 0..<22_050 {
            buffer.floatChannelData![0][frame] = 0.3 * sin(Float(frame) * 0.05)   // left only
            buffer.floatChannelData![1][frame] = 0
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let audio = try engine()
        try audio.load("stereo", url: url)
        #expect(audio.isLoaded("stereo"))
        #expect(abs((audio.duration(of: "stereo") ?? 0) - 0.5) < 0.01)
        audio.play("stereo")
        _ = try level(audio, seconds: 0.05)
        let l = try level(audio, seconds: 0.2)
        #expect(l.left > 0.05 && l.left > l.right * 10, "a left-only stereo take stays left: \(l)")
    }

    @Test("Many sounds load off the main thread, and a bad one is named rather than fatal")
    func batchLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("we-batch-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var files: [String: URL] = [:]
        for index in 0..<3 {
            let url = folder.appendingPathComponent("take_\(index).wav")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
            files["take_\(index)"] = url
        }
        files["broken"] = folder.appendingPathComponent("missing.wav")
        let audio = try engine()
        let failures = await audio.load(files)
        #expect(failures.keys.sorted() == ["broken"])
        #expect((0..<3).allSatisfy { audio.isLoaded("take_\($0)") } && !audio.isLoaded("broken"))
    }

    @Test("An ambient bed is heard in both ears, follows ambience not effects, and stops")
    func ambientBed() throws {
        let audio = try engine()
        let bed = try #require(audio.startAmbience("noise", volume: 0.8))
        #expect(audio.loopCount == 1)
        _ = try level(audio, seconds: 0.05)
        let full = try level(audio, seconds: 0.3)
        #expect(full.left > 0.01 && abs(full.left / full.right - 1) < 0.1, "unplaced in both ears: \(full)")
        // Longer than the sound itself: a bed loops.
        _ = try level(audio, seconds: 1)
        #expect(try level(audio, seconds: 0.2).left > 0.01, "the bed did not loop")
        audio.effectsVolume = 0
        _ = try level(audio, seconds: 0.2)
        let afterEffects = try level(audio, seconds: 0.3)
        #expect(abs(afterEffects.left / full.left - 1) < 0.15, "a bed moved with the effects")
        audio.loopVolume = 0.5
        _ = try level(audio, seconds: 0.3)                  // a mixer's level ramps rather than jumps
        let half = try level(audio, seconds: 0.3)
        #expect(abs(half.left / full.left - 0.5) < 0.08, "half ambience: \(half.left / full.left)")
        audio.stopLoop(bed)
        _ = try level(audio, seconds: 0.05)
        #expect(try level(audio, seconds: 0.2).left < 1e-5 && audio.loopCount == 0)
        #expect(audio.startAmbience("missing") == nil)
    }

    @Test("The meter reads a sound that played, and reads nothing after it")
    func meter() throws {
        let audio = try engine()
        audio.startMetering()
        _ = try level(audio, seconds: 0.1)
        #expect(audio.readPeak() == 0, "silence read as sound")
        audio.play("noise")
        _ = try level(audio, seconds: 0.2)
        let peak = audio.readPeak()
        #expect(peak > 0.1, "a played sound read \(peak)")
        #expect(audio.readPeak() == 0, "reading did not reset")
    }

    @Test("A player's settings set the master, effects and ambience — and quiet in the background")
    func appliesPlayerSettings() throws {
        let audio = try engine()
        var settings = PlayerSettings()
        settings.volume = 0.6
        settings.effectsVolume = 0.5
        settings.ambienceVolume = 0.25
        settings.soundInBackground = true
        audio.apply(settings)
        #expect(audio.masterVolume == 0.6 && audio.effectsVolume == 0.5 && audio.loopVolume == 0.25)
        #expect(audio.playsInBackground)
    }

    @Test("In the background the mix is silent, unless the player asked to hear it; back in front it returns")
    func quietInBackground() throws {
        func loudness(background: Bool, playsInBackground: Bool) throws -> Float {
            let audio = try engine()
            audio.playsInBackground = playsInBackground
            if background { audio.appFocusChanged(inBackground: true) }
            audio.play("noise")
            _ = try level(audio, seconds: 0.05)
            let l = try level(audio, seconds: 0.2)
            return l.left + l.right
        }
        let front = try loudness(background: false, playsInBackground: false)
        let quiet = try loudness(background: true, playsInBackground: false)
        let kept = try loudness(background: true, playsInBackground: true)
        #expect(front > 0.01 && quiet < 1e-4 && abs(kept / front - 1) < 0.05, "front \(front), quiet \(quiet), kept \(kept)")

        let audio = try engine()
        audio.masterVolume = 0.7
        audio.appFocusChanged(inBackground: true)
        #expect(audio.masterVolume == 0.7, "background quiet overwrote the player's volume")
        audio.appFocusChanged(inBackground: false)
        audio.play("noise")
        _ = try level(audio, seconds: 0.05)
        #expect(try level(audio, seconds: 0.2).left > 0.005, "sound did not come back")
    }

    @Test("Sound settings survive being saved, and a file from before them takes the defaults")
    func settingsRoundTrip() throws {
        var settings = PlayerSettings()
        settings.effectsVolume = 0.3
        settings.musicVolume = 0.7
        settings.soundInBackground = true
        let back = try JSONDecoder().decode(PlayerSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.effectsVolume == 0.3 && back.musicVolume == 0.7 && back.soundInBackground)
        let older = try JSONDecoder().decode(PlayerSettings.self, from: Data(#"{"volume":0.5}"#.utf8))
        #expect(older.effectsVolume == 1 && older.musicVolume == 0.45 && !older.soundInBackground)
    }
}

@Suite("Sound variation")
struct SoundVariationTests {

    @Test("A take is never the one just heard, and every take is used")
    func neverTheSameTwice() {
        var variation = SoundVariation()
        var generator = SystemRandomNumberGenerator()
        var previous = -1
        var seen = Set<Int>()
        for _ in 0..<200 {
            let take = variation.take(for: "hit", among: 4, using: &generator)
            #expect(take != previous && (0..<4).contains(take))
            previous = take
            seen.insert(take)
        }
        #expect(seen.count == 4)
        #expect(variation.take(for: "single", among: 1, using: &generator) == 0)
    }

    @Test("Different sounds keep their own history")
    func ownHistory() {
        var variation = SoundVariation()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let a1 = variation.take(for: "a", among: 2, using: &generator)
            _ = variation.take(for: "b", among: 2, using: &generator)
            let a2 = variation.take(for: "a", among: 2, using: &generator)
            #expect(a1 != a2, "another sound's play reset this one's history")
        }
    }

    @Test("Pitch and level stay inside their spread")
    func jitterInRange() {
        let variation = SoundVariation(pitchSpread: 0.05, gainSpreadDecibels: 1.5)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let (rate, gain) = variation.jitter(using: &generator)
            #expect(rate >= 0.95 && rate <= 1.05)
            #expect(gain >= pow(10, -1.5 / 20) - 1e-5 && gain <= pow(10, 1.5 / 20) + 1e-5)
        }
    }

    @Test("A take's file name says which sound it is")
    func takeNames() {
        #expect(SoundVariation.sound(ofTake: "hit_wood_02") == "hit_wood")
        #expect(SoundVariation.sound(ofTake: "ui_select_1") == "ui_select")
        #expect(SoundVariation.sound(ofTake: "crackle") == nil)
        #expect(SoundVariation.sound(ofTake: "hit_") == nil)
        #expect(SoundVariation.sound(ofTake: "hit_wood_a") == nil)
    }
}

@MainActor
@Suite("Music player")
struct MusicPlayerTests {

    private let track = URL(fileURLWithPath: "/nonexistent/score.m4a")

    @Test("Zero volume stops the score and raising it starts the same track again")
    func volumeStopsAndRestarts() async {
        let music = MusicPlayer(volume: 0.5)
        music.play(track)
        #expect(music.playing == track && music.track == track)
        music.volume = 0
        #expect(music.playing == nil && music.track == track, "muting forgot the track")
        music.volume = 0.4
        #expect(music.playing == track)
        music.stop()
        #expect(music.playing == nil && music.track == nil)
        await music.settle()
    }

    /// The score pauses in the background — its place kept — and plays on when the game is in front again.
    @Test("The score pauses in the background and resumes in front, unless the player keeps it playing")
    func pausesInBackground() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("we-score-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }

        let music = MusicPlayer(volume: 0.5)
        music.fadeIn = 0
        music.focusFade = 0.05
        music.play(url)
        await music.settle()
        #expect(await music.isAudible(), "the score never started")
        music.appFocusChanged(inBackground: true)
        await music.settle()
        #expect(await music.isAudible() == false, "the score kept playing behind another app")
        music.appFocusChanged(inBackground: false)
        await music.settle()
        #expect(await music.isAudible(), "the score did not come back")

        music.playsInBackground = true
        music.appFocusChanged(inBackground: true)
        await music.settle()
        #expect(await music.isAudible(), "the player asked to keep it playing")
        music.appFocusChanged(inBackground: false)
        music.stop(fade: 0)
        await music.settle()
    }

    /// A file that will not open leaves the game silent, not broken.
    @Test("A track that will not open is silent")
    func unreadableIsSilent() async {
        let music = MusicPlayer()
        music.play(track)
        await music.settle()
        #expect(await music.isAudible() == false)
    }

    @Test("The player's music sits under their main volume")
    func appliesSettings() async {
        let music = MusicPlayer()
        var settings = PlayerSettings()
        settings.volume = 0.5
        settings.musicVolume = 0.6
        settings.soundInBackground = true
        music.apply(settings)
        #expect(abs(music.volume - 0.3) < 1e-6 && music.playsInBackground)
        await music.settle()
    }
}
