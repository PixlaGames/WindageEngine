//
//  MusicPlayer.swift
//  WindageEngine
//

import AppKit
import AVFoundation
import Observation

/// **A game's score**: one track at a time, looped, faded in and out.
///
/// **Not spatialized, and that is a decision rather than an omission.** Score is not a sound in the world:
/// a positional music source swings across the stereo field as the camera turns, which is the single most
/// common way background music is got wrong.
///
/// - **Faded, not cut.** A track arrives over ``fadeIn`` rather than starting, and music that stops dead on
///   a button press sounds like a crash.
/// - **Zero volume stops it** rather than playing silence — an idle player still decodes, and a muted game
///   should not do work a player asked it not to.
/// - **Quiet while the game is not the front app**, unless ``playsInBackground``: paused rather than
///   stopped, so switching back carries on where it was instead of starting the track again.
///
/// **The player lives off the main thread.** Starting the first player in a process brings up the audio
/// session, and part of that is a synchronous code-signature check on whichever thread pressed play — on
/// the main thread, on the frame a game starts its score. Every command goes through an actor, in order.
///
/// Taken from a game's zone music (2026-10-27).
@Observable
public final class MusicPlayer {

    /// 0…1. Zero stops the track; raising it again starts the one asked for.
    ///
    /// **A setter over a stored level, not a clamping `didSet`**: under `@Observable` a `didSet` that assigns
    /// its own property calls the setter again, for ever — measured as a stack overflow on first use.
    public var volume: Float {
        get { level }
        set {
            level = min(max(newValue.isFinite ? newValue : 0, 0), 1)
            volumeChanged()
        }
    }
    private var level: Float

    /// Whether the score keeps playing while the game is not the front app.
    public var playsInBackground = false {
        didSet { applyFocus() }
    }

    /// Seconds a track takes to arrive.
    public var fadeIn: TimeInterval = 3
    /// **Short**: its job is to stop the score sounding cut off when the player switches away, and anything
    /// longer than about a third of a second is still audible over the app they switched to.
    public var focusFade: TimeInterval = 0.3

    /// The track asked for, whether or not it is playing.
    public private(set) var track: URL?
    /// The track that is playing.
    public private(set) var playing: URL?

    @ObservationIgnored private var isBackground = false
    @ObservationIgnored private let deck = Deck()
    @ObservationIgnored private var lastCommand: Task<Void, Never>?
    @ObservationIgnored private var focus: AppFocusWatch?

    public init(volume: Float = 0.45) {
        level = min(max(volume.isFinite ? volume : 0, 0), 1)
        followAppFocus()
    }

    /// The player's score settings: their ``PlayerSettings/musicVolume`` under their ``PlayerSettings/volume``,
    /// and ``PlayerSettings/soundInBackground``.
    public func apply(_ settings: PlayerSettings) {
        volume = settings.volume * settings.musicVolume
        playsInBackground = settings.soundInBackground
    }

    /// Plays a track, looped, fading it in. **The track already playing is left alone**; another one fades
    /// out first. A file that will not open leaves the game silent rather than broken.
    public func play(_ url: URL) {
        track = url
        guard volume > 0, playing != url else { return }
        if playing != nil { send { await $0.stop(fade: 0.6) } }
        playing = url
        let (level, fade) = (volume, fadeIn)
        send { await $0.start(url, volume: level, fadeIn: fade) }
        // A track asked for while the game is in the background starts quiet, not at full volume.
        if isQuiet { applyFocus() }
    }

    /// Stops the score, faded. The next ``play(_:)`` starts the track from the beginning.
    public func stop(fade: TimeInterval = 0.6) {
        playing = nil
        track = nil
        send { await $0.stop(fade: fade) }
    }

    private func volumeChanged() {
        if volume == 0 {
            playing = nil
            send { await $0.stop(fade: 0) }
        } else if playing == nil, let track {
            play(track)
        } else if !isQuiet {
            let level = volume
            send { await $0.setVolume(level) }
        }
        // While hushed there is nothing to set: the new level is what `resume` fades up to.
    }

    private var isQuiet: Bool { isBackground && !playsInBackground }

    private func applyFocus() {
        let quiet = isQuiet
        let (level, fade) = (volume, focusFade)
        send { quiet ? await $0.hush(fade: fade) : await $0.resume(volume: level, fade: fade) }
    }

    private func followAppFocus() {
        focus = AppFocusWatch { [weak self] background in self?.appFocusChanged(inBackground: background) }
    }

    /// The application went to the background or came back. Internal for tests — see ``AudioEngine``'s.
    func appFocusChanged(inBackground background: Bool) {
        guard isBackground != background else { return }
        isBackground = background
        applyFocus()
    }

    /// **Each command waits for the one before**: two tasks reach an actor in no promised order, and a stop
    /// and a play a moment apart arriving reversed would leave the game silent.
    private func send(_ command: @escaping @Sendable (Deck) async -> Void) {
        let previous = lastCommand
        let deck = deck
        lastCommand = Task {
            await previous?.value
            await command(deck)
        }
    }

    /// Waits until every command sent so far has run — for a test, or a game about to quit.
    public func settle() async {
        await lastCommand?.value
    }

    /// Whether the deck has a track playing right now — for a test.
    public func isAudible() async -> Bool { await deck.isPlaying }
}

/// The one `AVAudioPlayer`, owned by an actor so that nothing touching it runs on the main thread.
private actor Deck {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    func start(_ url: URL, volume: Float, fadeIn: TimeInterval) {
        guard player == nil, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        player.setVolume(volume, fadeDuration: fadeIn)
        self.player = player
    }

    func setVolume(_ volume: Float) { player?.volume = volume }

    /// Fades out and **pauses**, keeping the place in the track and stopping the decoding.
    func hush(fade: TimeInterval) async {
        guard let player, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: fade)
        try? await Task.sleep(for: .seconds(fade))
        player.pause()
    }

    /// Plays from where ``hush(fade:)`` left off and fades back up; a no-op on a deck already playing at
    /// that level, which is what makes it safe on every focus change.
    func resume(volume: Float, fade: TimeInterval) async {
        guard let player else { return }
        if !player.isPlaying { player.play() }
        player.setVolume(volume, fadeDuration: fade)
    }

    /// Waits out the fade before stopping, so the next command — usually the next track — starts after
    /// this one has gone rather than on top of it.
    func stop(fade: TimeInterval) async {
        guard let leaving = player else { return }
        player = nil
        if fade > 0 {
            leaving.setVolume(0, fadeDuration: fade)
            try? await Task.sleep(for: .seconds(fade + 0.1))
        }
        leaving.stop()
    }
}
