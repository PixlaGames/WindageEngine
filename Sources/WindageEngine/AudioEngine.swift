//
//  AudioEngine.swift
//  WindageEngine
//

import AppKit
import AVFoundation
import os
import simd

/// Why an ``AudioEngine`` could not be made, or a sound could not be loaded into one.
public nonisolated enum AudioEngineError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No audio format could be made at this sample rate.
    case unsupportedSampleRate(Double)
    /// The engine could not be put into offline rendering, or could not start; the reason is
    /// AVFoundation's.
    case couldNotStart(reason: String)
    /// No sound file by that name and extension in the bundle.
    case soundNotFound(String)
    /// The file is there and could not be read as audio.
    case unreadableSound(String, reason: String)
    /// Samples handed to ``AudioEngine/load(_:samples:sampleRate:)`` that make no sound: none at all,
    /// or none a buffer could be made for.
    case noSamples(String)

    public var description: String {
        switch self {
        case .unsupportedSampleRate(let rate): "no audio format at \(rate) Hz"
        case .couldNotStart(let reason): "the audio engine could not start — \(reason)"
        case .soundNotFound(let name): "no sound file \(name)"
        case .unreadableSound(let name, let reason): "sound \(name) could not be read — \(reason)"
        case .noSamples(let name): "sound \(name) has no samples"
        }
    }
}

/// Positional one-shot audio.
///
/// **Spatialized from the start, not stereo panning bolted on later.** A game about distance needs
/// sound to carry distance: a plate hit at 800 m should arrive from where the plate is and sound
/// like it is 800 m away. `AVAudioEnvironmentNode` does the head-related work; what a title supplies
/// is a listener each frame and a world position per sound.
///
/// **One-shots, and loops that belong to a place** — a brazier's crackle, a generator's hum — since
/// 2026-09-11. **Unplaced sounds with pan and pitch, an effects bus, a meter and background quiet** since
/// 2026-10-27, taken from a game's own effects deck; the score is ``MusicPlayer``'s.
///
/// ### Three volumes under one
///
/// ``masterVolume`` scales everything; under it ``effectsVolume`` takes every one-shot, placed or not,
/// and ``loopVolume`` every loop. ``apply(_:)`` sets all three from a player's ``PlayerSettings``.
///
/// ### Two spatialisers, because one distance curve cannot serve both
///
/// **The one-shots' default curve was tuned for a shot heard across a range**: full volume out to
/// 8 m, then 90% of the inverse law. Put a brazier's crackle through it and it is as loud at 8 m as at
/// arm's length and still 43% at 20 m — two braziers fill a level with fire. Loops go through a second
/// spatializer with the physical inverse law from 2 m: half as loud at twice the distance, which is
/// what a small, near sound does. Measured, not argued — see ``renderOffline(seconds:)``. Both curves,
/// and the number of one-shot voices, are a game's to set: ``Configuration``.
///
/// ### Lifecycle
///
/// An engine plays from the moment it is made. ``pause()`` holds everything — one-shots, loops and
/// any delayed one-shot still waiting — and ``resume()`` carries on from where it was. ``stop()`` is
/// **final**: it frees the output device, and an engine that has stopped plays nothing again. Make a
/// new one.
///
/// > **A landmine worth knowing before adding any AVFoundation callback here.** This type is
/// > main-actor-isolated like everything else in the engine, and a closure written inside one of its
/// > methods *inherits that isolation*. AVFoundation calls taps and completion handlers on a
/// > realtime audio thread, so such a closure trips the actor assertion and takes the process down
/// > — `_dispatch_assert_queue_fail`, on `RealtimeMessenger.mServiceQueue`, with no mention of
/// > actors anywhere in the crash. Mark any callback `@Sendable` and give it its own thread-safe
/// > storage. Nothing here uses one today, which is the only reason this is a note and not a bug.
public final class AudioEngine {

    /// How an engine spreads sound over distance, and how many one-shots it can play at once — set
    /// when the engine is made. **The defaults are what every game has had so far.**
    public struct Configuration: Equatable, Sendable {

        /// One spatializer's distance curve: the inverse law, in meters.
        public struct Falloff: Equatable, Sendable {
            /// Full volume nearer than this.
            public var referenceDistance: Float
            /// No quieter beyond this.
            public var maximumDistance: Float
            /// 1 is the physical inverse law — half as loud at twice the reference distance; below 1
            /// falls off more gently.
            public var rolloffFactor: Float

            public init(referenceDistance: Float, maximumDistance: Float, rolloffFactor: Float) {
                self.referenceDistance = referenceDistance
                self.maximumDistance = maximumDistance
                self.rolloffFactor = rolloffFactor
            }
        }

        /// One-shots that can overlap. Beyond this the oldest is reused, because a game that runs out of
        /// voices silently drops the *newest* sound — which is always the one that just happened and
        /// therefore the one that mattered.
        public var voiceCount: Int
        /// The one-shots' curve. The default — full volume to 8 m, 90% of the inverse law out to 2 km —
        /// was tuned for a shot heard across a range.
        public var oneShotFalloff: Falloff
        /// The loops' curve. The default is the physical inverse law from 2 m, to 200 m — a small, near
        /// sound.
        public var loopFalloff: Falloff

        public init(voiceCount: Int = 16,
                    oneShotFalloff: Falloff = Falloff(referenceDistance: 8, maximumDistance: 2000,
                                                      rolloffFactor: 0.9),
                    loopFalloff: Falloff = Falloff(referenceDistance: 2, maximumDistance: 200,
                                                   rolloffFactor: 1)) {
            self.voiceCount = max(1, voiceCount)
            self.oneShotFalloff = oneShotFalloff
            self.loopFalloff = loopFalloff
        }
    }

    public let configuration: Configuration

    private let engine = AVAudioEngine()
    /// Every one-shot, placed or not — ``effectsVolume``.
    private let effectsBus = AVAudioMixerNode()
    private let environment = AVAudioEnvironmentNode()
    /// The loops' spatializer — see the type's notes.
    private let nearEnvironment = AVAudioEnvironmentNode()
    private var players: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let monoFormat: AVAudioFormat
    private var loops: [Int: AVAudioPlayerNode] = [:]
    private var idleLoopPlayers: [AVAudioPlayerNode] = []
    private var nextLoop = 0
    private let isOffline: Bool
    private var hasStopped = false

    /// Unplaced voices, a ring per format (sample rate and channel count) — see ``play(_:volume:pan:rate:)``.
    private var directVoices: [DirectFormat: (voices: [DirectVoice], next: Int)] = [:]
    private struct DirectFormat: Hashable { let rate: Double; let channels: AVAudioChannelCount }
    private struct DirectVoice { let player: AVAudioPlayerNode; let speed: AVAudioUnitVarispeed }

    /// The player's volume, before background quiet — what ``masterVolume`` reads back.
    private var requestedMaster: Float = 1
    private var isInBackground = false
    private var focus: AppFocusWatch?
    private let peak = OSAllocatedUnfairLock(initialState: Float(0))
    private var isMetering = false

    /// A loop that is playing. Hand it back to ``moveLoop(_:to:)`` and ``stopLoop(_:)``.
    public struct Loop: Hashable, Sendable {
        fileprivate let id: Int
    }

    /// An engine that plays through the output device.
    ///
    /// - Throws: ``AudioEngineError`` when the device's format is unusable or the engine will not start
    ///   — a machine with no output device, say. A game can run without sound; this says why it is.
    public convenience init(configuration: Configuration = Configuration()) throws {
        try self.init(offline: nil, configuration: configuration)
    }

    /// **An engine with no device at all**, whose mix is pulled with ``renderOffline(seconds:)`` —
    /// for measuring what a game sounds like without anyone listening: how loud a loop is at a
    /// distance, whether it is still going after a minute. `AVAudioEngine`'s manual rendering mode.
    public convenience init(offlineSampleRate sampleRate: Double,
                            configuration: Configuration = Configuration()) throws {
        try self.init(offline: sampleRate, configuration: configuration)
    }

    private init(offline sampleRate: Double?, configuration: Configuration) throws {
        self.configuration = configuration
        isOffline = sampleRate != nil
        if let sampleRate {
            // Before anything is attached: the engine must be stopped, and its format is fixed here.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw AudioEngineError.unsupportedSampleRate(sampleRate)
            }
            do {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            } catch {
                throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
            }
        }
        let rate = sampleRate ?? engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw AudioEngineError.unsupportedSampleRate(rate)
        }
        monoFormat = mono

        engine.attach(effectsBus)
        engine.connect(effectsBus, to: engine.mainMixerNode, format: nil)
        engine.attach(environment)
        engine.connect(environment, to: effectsBus, format: nil)
        engine.attach(nearEnvironment)
        engine.connect(nearEnvironment, to: engine.mainMixerNode, format: nil)

        // Distance attenuation in metres, matching the world's units.
        for (node, falloff) in [(environment, configuration.oneShotFalloff),
                                (nearEnvironment, configuration.loopFalloff)] {
            node.distanceAttenuationParameters.distanceAttenuationModel = .inverse
            node.distanceAttenuationParameters.referenceDistance = falloff.referenceDistance
            node.distanceAttenuationParameters.maximumDistance = falloff.maximumDistance
            node.distanceAttenuationParameters.rolloffFactor = falloff.rolloffFactor
        }
        // **Each voice renders `.auto` — HRTF on stereo output — and that is measured, not assumed.**
        // This line used to set `.sphericalHead` on the *environment* node, with a note that spherical
        // head "keeps the directional cue a game reads at a fraction of the cost". Neither half held:
        // the algorithm is a property of each source, so setting it here did nothing, and measured
        // offline a source 5 m to the right comes out **1.01× louder in the right ear under spherical
        // head, against 4.6× under HRTF** and 5.6× under `.auto`. A game that tells a player which way
        // a shot landed needs the second. (If sixteen HRTF voices ever overload the render thread —
        // `HALC_ProxyIOContext: skipping cycle` — the answer is fewer voices, not a model with no cue.)

        // Mono voices: a spatialiser needs a point source, and a stereo file already has a position
        // baked into it that would fight the one being applied.
        for _ in 0..<configuration.voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: environment, format: mono)
            // Per voice, where it takes effect — see above. Once here rather than on every play().
            player.renderingAlgorithm = .auto
            players.append(player)
        }

        do {
            if isOffline {
                try engine.start()
            } else {
                // **Started off the main thread.** Starting the first audio in a process brings up the audio
                // session, and part of that is a synchronous code-signature check on whichever thread asked —
                // reported by Xcode as "this method should not be called on the main thread" on the frame a game
                // starts its sound. The wait is the same either way; the check is not on the main thread.
                let avEngine = engine
                try DispatchQueue.global(qos: .userInitiated).sync { try avEngine.start() }
            }
        } catch {
            throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
        }
        players.forEach { $0.play() }
        followAppFocus()
    }

    /// Loads a sound and keeps it decoded in memory.
    ///
    /// One-shots are short and are needed *now*; streaming them would add latency to exactly the
    /// sounds that must be immediate.
    ///
    /// **`bundle` has no default, deliberately.** It used to default to `.main`, which is right for
    /// an app bundle and wrong for a SwiftPM executable — there `.main` is the executable itself and
    /// holds no resources, so every load failed and printed. There is no default that is right for
    /// both, and a default that is silently wrong for one of them is worse than making every caller
    /// say where its sounds are. An app passes `.main`; a package target passes `.module`.
    ///
    /// Loading a name already loaded does nothing.
    ///
    /// - Throws: ``AudioEngineError/soundNotFound(_:)`` or ``AudioEngineError/unreadableSound(_:reason:)``.
    public func load(_ name: String, withExtension ext: String = "wav", bundle: Bundle) throws {
        guard buffers[name] == nil else { return }
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw AudioEngineError.soundNotFound("\(name).\(ext)")
        }
        try load(name, url: url)
    }

    /// Loads a sound from a file, under `name` — for a game that finds its sounds itself, such as every
    /// take in a folder. Loading a name already loaded does nothing.
    ///
    /// - Throws: ``AudioEngineError/unreadableSound(_:reason:)``.
    public func load(_ name: String, url: URL) throws {
        guard buffers[name] == nil else { return }
        do {
            buffers[name] = try AudioEngine.decode(url)
        } catch let error as AudioEngineError {
            throw error
        } catch {
            throw AudioEngineError.unreadableSound(url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// **Loads many sounds, reading them off the main thread** — a game's whole library of takes at once,
    /// where reading tens of megabytes on the main thread would stall a frame. Names already loaded are
    /// skipped. Returns what could not be loaded, and why; everything else is ready when it returns.
    public func load(_ files: [String: URL]) async -> [String: AudioEngineError] {
        let wanted = files.filter { buffers[$0.key] == nil }
        let read = await Task.detached(priority: .userInitiated) {
            wanted.mapValues { url -> ReadSound in
                do { return .loaded(DecodedSound(buffer: try AudioEngine.decode(url))) } catch let error as AudioEngineError {
                    return .failed(error)
                } catch {
                    return .failed(.unreadableSound(url.lastPathComponent, reason: error.localizedDescription))
                }
            }
        }.value
        var failures: [String: AudioEngineError] = [:]
        for (name, result) in read {
            switch result {
            case .loaded(let sound): buffers[name] = sound.buffer
            case .failed(let error): failures[name] = error
            }
        }
        return failures
    }

    /// A buffer read on another thread and handed over once — never touched there again.
    nonisolated private struct DecodedSound: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
    nonisolated private enum ReadSound: Sendable { case loaded(DecodedSound), failed(AudioEngineError) }

    nonisolated private static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioEngineError.unreadableSound(url.lastPathComponent, reason: "no buffer for its format")
        }
        try file.read(into: buffer)
        return buffer
    }

    /// Whether a sound is loaded under this name.
    public func isLoaded(_ name: String) -> Bool { buffers[name] != nil }

    /// How long a loaded sound plays at normal speed, in seconds; nil when it is not loaded.
    public func duration(of name: String) -> Double? {
        buffers[name].map { Double($0.frameLength) / $0.format.sampleRate }
    }

    /// Loads a sound from samples already in memory — mono, at `sampleRate` — for a sound a game
    /// makes rather than ships, and for a test that wants a signal it knows exactly. Replaces a sound
    /// already loaded under the name.
    ///
    /// - Throws: ``AudioEngineError/noSamples(_:)`` for an empty array,
    ///   ``AudioEngineError/unsupportedSampleRate(_:)`` for a rate no format can have.
    public func load(_ name: String, samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty else { throw AudioEngineError.noSamples(name) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioEngineError.unsupportedSampleRate(sampleRate)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { throw AudioEngineError.noSamples(name) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        buffers[name] = buffer
    }

    /// Where the ears are. Call once per frame.
    public func updateListener(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let point = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        let orientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))
        // Both spatialisers hear from the same head.
        for node in [environment, nearEnvironment] {
            node.listenerPosition = point
            node.listenerVectorOrientation = orientation
        }
    }

    // MARK: - Loops

    /// Starts a sound looping at a world position, until ``stopLoop(_:)``.
    ///
    /// **Each loop starts somewhere different in its sound**, so two braziers playing the same
    /// crackle are not a single crackle in two places — which is what starting both at sample zero
    /// sounds like. Through the near spatializer; see the type's notes.
    ///
    /// **Keep what it returns**: a loop nobody holds cannot be stopped, short of ``stopAllLoops()``.
    /// `nil` when no sound of that name is loaded.
    public func startLoop(_ name: String, at position: SIMD3<Float>, volume: Float = 1) -> Loop? {
        guard let buffer = buffers[name], buffer.frameLength > 0 else { return nil }
        let player = idleLoopPlayers.popLast() ?? makeLoopPlayer()
        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        player.volume = volume
        let id = nextLoop
        nextLoop += 1
        // A different starting point for every loop: Knuth's multiplicative hash of its number.
        let offset = AVAudioFrameCount((UInt64(id) &* 2_654_435_761) % UInt64(buffer.frameLength))
        if offset > 0, let tail = AudioEngine.frames(of: buffer, from: offset) {
            player.scheduleBuffer(tail, at: nil, options: [])
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        loops[id] = player
        return Loop(id: id)
    }

    public func moveLoop(_ loop: Loop, to position: SIMD3<Float>) {
        loops[loop.id]?.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    public func stopLoop(_ loop: Loop) {
        guard let player = loops.removeValue(forKey: loop.id) else { return }
        player.stop()
        idleLoopPlayers.append(player)
    }

    public func stopAllLoops() {
        for loop in loops.keys.map(Loop.init(id:)) { stopLoop(loop) }
    }

    public var loopCount: Int { loops.count }

    /// **Made on demand and kept**, unlike the one-shots' fixed ring: a level has as many loops as it
    /// has things that hum, and a voice stolen from a brazier by a footstep is a fire that goes out.
    private func makeLoopPlayer() -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: nearEnvironment, format: monoFormat)
        // As the one-shots: a fire to your left should sound as if it is on your left.
        player.renderingAlgorithm = .auto
        return player
    }

    /// The frames of `buffer` from `start` to its end, as a buffer of their own.
    private static func frames(of buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let count = buffer.frameLength - start
        guard count > 0, let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let from = buffer.floatChannelData, let to = tail.floatChannelData else { return nil }
        tail.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            to[channel].update(from: from[channel] + Int(start), count: Int(count))
        }
        return tail
    }

    // MARK: - Measuring

    /// Pulls `seconds` of the mix from an engine made with ``init(offlineSampleRate:)``, one array per
    /// output channel. Nil for an engine playing through a device.
    ///
    /// **What makes a sound checkable without ears.** Every level in this type — the loops' falloff,
    /// a loop still going after its buffer has come round — was measured through this before it was
    /// described.
    public func renderOffline(seconds: Float) -> [[Float]]? {
        guard isOffline else { return nil }
        let format = engine.manualRenderingFormat
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return nil }
        let total = AVAudioFrameCount(Double(seconds) * format.sampleRate)
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        var done: AVAudioFrameCount = 0
        while done < total {
            let wanted = min(block.frameCapacity, total - done)
            guard let status = try? engine.renderOffline(wanted, to: block), status == .success,
                  let data = block.floatChannelData else { return nil }
            for channel in channels.indices {
                channels[channel] += UnsafeBufferPointer(start: data[channel], count: Int(block.frameLength))
            }
            done += block.frameLength
        }
        return channels
    }

    /// Plays a sound at a world position.
    ///
    /// - Parameter delay: seconds to wait first. **The reason this exists:** sound travels at about
    ///   343 m/s, so an impact 800 m away is heard nearly two and a half seconds after it happens.
    ///   In most games that is a detail; in one built around long shots it is the feedback loop
    ///   itself, and the wait is the point.
    ///
    /// **The wait is counted on the audio clock**, not the main thread's: it holds while the engine is
    /// paused, is exact to the sample in an offline render, and a sound still waiting is cancelled by
    /// ``stop()`` — none of which held while it was a `DispatchQueue` timer.
    public func play(_ name: String, at position: SIMD3<Float>, volume: Float = 1, delay: Float = 0) {
        guard let buffer = buffers[name] else { return }

        let player = players[nextVoice]
        nextVoice = (nextVoice + 1) % players.count

        player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        player.volume = volume
        player.scheduleBuffer(buffer, at: startTime(on: player, after: delay), options: .interrupts)
    }

    /// When a voice should start a sound `delay` seconds from now, on its own timeline; `nil` — as soon
    /// as it can — for no delay.
    ///
    /// A voice that has not rendered yet has no "now", and its timeline starts at zero when it does.
    private func startTime(on player: AVAudioPlayerNode, after delay: Float) -> AVAudioTime? {
        guard delay > 0 else { return nil }
        var now: AVAudioFramePosition = 0
        var rate = monoFormat.sampleRate
        if let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            now = playerTime.sampleTime
            rate = playerTime.sampleRate
        }
        return AVAudioTime(sampleTime: now + AVAudioFramePosition((Double(delay) * rate).rounded()), atRate: rate)
    }

    /// Plays without a position — for anything that happens *to the player* rather than in the world, and
    /// for a game that places its sounds by its own rule: the interface, a blow the player threw, a fight
    /// panned by where it is.
    ///
    /// - Parameters:
    ///   - pan: −1 left to +1 right.
    ///   - rate: playback speed, and pitch with it — 1 as recorded. **What makes the same take sound like a
    ///     different blow**; see ``SoundVariation``.
    ///
    /// **Not through the spatializer**: a sound in stereo plays in stereo, at any sample rate. Voices are a
    /// ring per format, ``Configuration/voiceCount`` each, made the first time a format is played; when every
    /// one is busy **the oldest is cut**, which in a fight is the sound the ear has already moved past.
    public func play(_ name: String, volume: Float = 1, pan: Float = 0, rate: Float = 1) {
        guard let buffer = buffers[name], buffer.frameLength > 0 else { return }
        let key = DirectFormat(rate: buffer.format.sampleRate, channels: buffer.format.channelCount)
        if directVoices[key] == nil {
            let voices = (0..<configuration.voiceCount).map { _ in
                let voice = DirectVoice(player: AVAudioPlayerNode(), speed: AVAudioUnitVarispeed())
                engine.attach(voice.player)
                engine.attach(voice.speed)
                engine.connect(voice.player, to: voice.speed, format: buffer.format)
                engine.connect(voice.speed, to: effectsBus, format: buffer.format)
                return voice
            }
            directVoices[key] = (voices, 0)
        }
        guard var ring = directVoices[key] else { return }
        let voice = ring.voices[ring.next]
        ring.next = (ring.next + 1) % ring.voices.count
        directVoices[key] = ring

        voice.player.stop()
        voice.speed.rate = min(max(rate, 0.25), 4)
        voice.player.volume = max(volume, 0)
        voice.player.pan = min(max(pan, -1), 1)
        voice.player.scheduleBuffer(buffer, at: nil, options: [])
        voice.player.play()
    }

    /// The loops, 0…1 — a brazier's crackle, a generator's hum — and **nothing else**: what a game
    /// offers a player as its ambience setting.
    ///
    /// **On the loops' own spatializer**, which is why it can be separate at all: every loop and no
    /// one-shot passes through it. A player who wants the fire quieter should not have to turn down
    /// their own footsteps with it, which is what one volume made them do. ``masterVolume`` still
    /// scales everything, this included.
    public var loopVolume: Float {
        get { nearEnvironment.outputVolume }
        set { nearEnvironment.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Every one-shot, placed or unplaced, 0…1 — what a game offers as its effects setting. Under
    /// ``masterVolume``, beside ``loopVolume``.
    public var effectsVolume: Float {
        get { effectsBus.outputVolume }
        set { effectsBus.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Everything this engine plays, 0…1 — the player's volume setting.
    ///
    /// **On the main mixer, after the spatializer**, so it scales every voice by the same amount
    /// without touching the distance attenuation that says how far away each one is.
    public var masterVolume: Float {
        get { requestedMaster }
        set {
            requestedMaster = min(max(newValue, 0), 1)
            applyMaster()
        }
    }

    /// **Whether the game is heard while it is not the front app.** Off by default: sound still playing over
    /// whatever the player switched to is noise, and the usual next move is to turn it off entirely —
    /// losing the setting they wanted. On for a second monitor with the world on it.
    public var playsInBackground = false {
        didSet { applyMaster() }
    }

    /// The player's sound settings: ``masterVolume``, ``effectsVolume``, ``loopVolume`` and
    /// ``playsInBackground`` from theirs. The score's are ``MusicPlayer/apply(_:)``.
    public func apply(_ settings: PlayerSettings) {
        masterVolume = settings.volume
        effectsVolume = settings.effectsVolume
        loopVolume = settings.ambienceVolume
        playsInBackground = settings.soundInBackground
    }

    private func applyMaster() {
        engine.mainMixerNode.outputVolume = isInBackground && !playsInBackground ? 0 : requestedMaster
    }

    private func followAppFocus() {
        focus = AppFocusWatch { [weak self] background in self?.appFocusChanged(inBackground: background) }
    }

    /// What the application's going to the background, or coming back, does to the mix. Internal for tests,
    /// which call it rather than post app-wide notifications that would reach every engine running beside them.
    func appFocusChanged(inBackground background: Bool) {
        isInBackground = background
        applyMaster()
    }

    // MARK: - Metering

    /// **The loudest sample the mix has carried since the last reset**, 0…1 linear — how a sound is checked
    /// without ears: a play that reaches the output shows here. Call ``startMetering()`` first.
    ///
    /// - Parameter resetting: start the next reading from silence. **Pass `false` while other sounds being
    ///   measured are still playing** — one mix has one peak, and a reset for a second sound erases the first
    ///   one's reading.
    public func readPeak(resetting: Bool = true) -> Float {
        peak.withLock { level in
            defer { if resetting { level = 0 } }
            return level
        }
    }

    /// Starts measuring the mix's peak, for ``readPeak()``. **A tap on the main mixer**, called on a
    /// realtime audio thread — see the type's note on callbacks; this one is `@Sendable` and writes only
    /// through a lock.
    public func startMetering() {
        guard !isMetering else { return }
        isMetering = true
        let peak = peak
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(data[channel][frame])) }
            }
            let found = loudest
            peak.withLock { $0 = max($0, found) }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tap)
    }

    /// Holds everything — one-shots, loops and delayed one-shots still waiting — until ``resume()``.
    public func pause() {
        engine.pause()
    }

    /// Carries on after ``pause()``. Does nothing after ``stop()``, which is final.
    ///
    /// - Throws: ``AudioEngineError/couldNotStart(reason:)`` — the output device went away, say.
    public func resume() throws {
        guard !hasStopped, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw AudioEngineError.couldNotStart(reason: error.localizedDescription)
        }
    }

    /// **Final**: stops every sound, cancels any one-shot still waiting on its delay, and frees the
    /// output device. A stopped engine plays nothing again — make a new one. To hold sound for a while,
    /// ``pause()``.
    public func stop() {
        hasStopped = true
        focus = nil
        if isMetering { engine.mainMixerNode.removeTap(onBus: 0) }
        stopAllLoops()
        players.forEach { $0.stop() }
        directVoices.values.forEach { $0.voices.forEach { $0.player.stop() } }
        engine.stop()
    }
}
