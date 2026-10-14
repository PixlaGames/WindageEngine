//
//  SampleRun.swift
//  WindageSampleCore
//

import Foundation
import simd
import WindageEngine

/// **The game part of the sample game.** State that persists across frames, a way to win, a way to
/// lose, and something remembered after you quit.
///
/// The walkthrough proved the engine could *load and draw* a level. It could not say whether the
/// engine supports a game **loop** — anything with state that survives a frame, a pause that is not
/// a stall, an outcome, or progress kept between runs. That is a different class of gap, and this is
/// the smallest thing that opens it.
///
/// It is a fetch quest, on purpose: touch every marked crate before the clock runs out. Nothing here
/// is interesting except that all of it has to work.
public nonisolated struct SampleRun {

    public enum Mode: Equatable {
        case playing
        case paused
        case won(seconds: Double)
        case lost
    }

    /// What is kept between runs. **A version field from the start**, because the first save format
    /// that needs changing is always one that did not have one.
    /// `nonisolated` because a save is data, and `SaveStore` is too — the sample's target defaults
    /// to `MainActor`, and a main-actor `Codable` conformance cannot satisfy a `Sendable` one.
    public nonisolated struct Progress: Codable, Equatable, Sendable {
        /// **Version 2: best times became per level.** Version 1 held a single `bestSeconds`, which
        /// was right while there was one level and silently wrong the moment there were two — the
        /// second level's first win would have overwritten the first level's record.
        ///
        /// The field was there from the start for exactly this, and it earned its keep: a v1 save
        /// migrates instead of being discarded, so nobody loses a time to a format change.
        public static let currentVersion = 2

        public var version = Progress.currentVersion
        /// Level name to best seconds.
        public var best: [String: Double] = [:]
        public var runs = 0
        public var wins = 0

        public init() {}

        private enum CodingKeys: String, CodingKey { case version, best, runs, wins, bestSeconds }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runs = try container.decodeIfPresent(Int.self, forKey: .runs) ?? 0
            wins = try container.decodeIfPresent(Int.self, forKey: .wins) ?? 0
            best = try container.decodeIfPresent([String: Double].self, forKey: .best) ?? [:]
            // The v1 shape: one time, which belonged to the only level that existed.
            if let single = try container.decodeIfPresent(Double.self, forKey: .bestSeconds) {
                best["COURTYARD"] = min(best["COURTYARD"] ?? .infinity, single)
            }
            version = Progress.currentVersion
        }

        /// **Never writes the v1 field.** Migration is one way: a save written by this build is v2,
        /// and an older build reading it gets no `bestSeconds` and starts fresh rather than reading
        /// a number that means something else.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(best, forKey: .best)
            try container.encode(runs, forKey: .runs)
            try container.encode(wins, forKey: .wins)
        }
    }

    /// Where progress is kept.
    ///
    /// **Injected rather than global, and that was found by testing.** It began as one shared
    /// `static let`, which is fine for a game with one process — and wrong the moment there are two
    /// of anything. Swift Testing runs tests in parallel, they all wrote the same file, and the
    /// results depended on which finished first. The same shape breaks a game with save slots or
    /// profiles, which is the real reason to fix it rather than to special-case the tests.
    public let store: SaveStore<Progress>

    /// The one a shipped game uses.
    public static let sharedStore = SaveStore<Progress>(container: "WindageSample", name: "progress")

    /// Seconds allowed. Generous — a sample that is hard to beat is a sample nobody finishes, and
    /// then the win state never gets exercised.
    public static let timeLimit: Double = 90

    /// How near counts as touching one, in metres.
    ///
    /// **Measured to the crate's centre, so it has to clear the crate's own half-width.** At 2.5 m a
    /// crate 1.5 m across could be stood against and not collected — driven in-app, the player ended
    /// up 3.2 m from the centre, visibly touching it, and nothing happened.
    public static let reach: Float = 3.5

    public private(set) var mode: Mode = .playing
    public private(set) var elapsed: Double = 0
    public private(set) var progress: Progress

    /// The objectives, and which are done. Index-parallel to the level's `"objective"` markers.
    public private(set) var objectives: [SIMD3<Float>]
    public private(set) var collected: [Bool]

    public var remaining: Double { max(0, SampleRun.timeLimit - elapsed) }

    /// The best time on *this* level, if there is one.
    public var best: Double? { progress.best[levelName] }
    public var found: Int { collected.filter { $0 }.count }
    public var isOver: Bool { if case .playing = mode { return false }; if case .paused = mode { return false }; return true }

    /// Which level this run is of — best times are recorded against it.
    public let levelName: String

    public init(objectives: [SIMD3<Float>],
                levelName: String = "",
                store: SaveStore<Progress> = SampleRun.sharedStore) {
        self.levelName = levelName
        self.objectives = objectives
        self.collected = Array(repeating: false, count: objectives.count)
        self.store = store
        // A save that will not read must not stop the game: say so, and start fresh.
        do {
            self.progress = try store.load() ?? Progress()
        } catch {
            print("WindageSample: progress could not be read, starting fresh — \(error)")
            self.progress = Progress()
        }
    }

    /// What happened in a step that something outside might want to react to.
    ///
    /// **Returned rather than fired as a callback.** A callback from inside a simulation step runs
    /// on whatever thread the step is on and invites the caller to mutate the run while it is
    /// stepping; a value handed back cannot. It also keeps the run testable without a spy.
    public struct Events: Equatable, Sendable {
        /// Where each crate collected this step was — so a sound can come from the crate.
        public var collected: [SIMD3<Float>] = []
        public var won = false
        public var lost = false

        public var isEmpty: Bool { collected.isEmpty && !won && !lost }
    }

    /// One simulation step.
    ///
    /// **A pause is "do not advance", not "stop the loop".** The frame loop keeps running — the
    /// scene still draws, the HUD still updates, the window still resizes — which is why pausing is
    /// a game's decision and not something the engine has to provide.
    @discardableResult
    public mutating func step(deltaTime: Double, playerAt position: SIMD3<Float>) -> Events {
        var events = Events()
        guard mode == .playing else { return events }

        elapsed += deltaTime
        for (index, objective) in objectives.enumerated() where !collected[index] {
            // Distance in the ground plane: the player's eye is 1.7 m up and the objective sits on
            // the floor, so a 3D distance would need a taller reach for the same feel.
            let flat = SIMD2(position.x - objective.x, position.z - objective.z)
            if simd_length(flat) <= SampleRun.reach {
                collected[index] = true
                events.collected.append(objective)
            }
        }

        if collected.allSatisfy({ $0 }) && !objectives.isEmpty {
            finish(won: true)
            events.won = true
        } else if elapsed >= SampleRun.timeLimit {
            finish(won: false)
            events.lost = true
        }
        return events
    }

    private mutating func finish(won: Bool) {
        mode = won ? .won(seconds: elapsed) : .lost
        progress.runs += 1
        if won {
            progress.wins += 1
            if elapsed < (progress.best[levelName] ?? .infinity) {
                progress.best[levelName] = elapsed
            }
        }
        // **Written when the run ends, not every frame.** A save per frame is a write per frame, and
        // the only thing it buys is remembering a run nobody finished.
        try? store.save(progress)
    }

    public mutating func togglePause() {
        switch mode {
        case .playing: mode = .paused
        case .paused: mode = .playing
        default: break                      // a finished run has nothing to pause
        }
    }

    /// Start again, keeping what was learned across runs.
    public mutating func restart() {
        mode = .playing
        elapsed = 0
        collected = Array(repeating: false, count: objectives.count)
    }
}
