//
//  SampleLevel.swift
//  WindageSample
//

import Foundation
import WindageEngine

/// The sample's levels: **two JSON files in this target's resources**, and nothing else.
///
/// **They used to be Swift functions that built a `Level` in code, and that was the sample teaching
/// the opposite of what the engine says.** The format's whole claim is that a level is data — a file
/// you open, edit and reload without a compiler — and the first thing anybody who clones this repo
/// reads is the sample. A level assembled by a function said the file was an export.
///
/// The files were generated once from those functions, so the courtyard is exactly the courtyard it
/// has always been, and the functions were deleted. There is one description of a level now, it is
/// the one the game loads, and a change to it is a readable diff rather than a Swift diff.
///
/// `nonisolated`, like the level format itself: a level's contents are data, and a game that wanted
/// to load one on a background thread should be able to.
public nonisolated enum SampleLevel {

    /// Every level the sample ships, in order. **Two, on purpose** — one is not enough to find out
    /// whether anything assumed there would only ever be one, and something always has.
    public static let names = ["courtyard", "ruins"]

    /// The surfaces this sample has footsteps and landings for — `step_<surface>_0…2` and
    /// `land_<surface>`, generated with the sample. **Every solid in a level names one of
    /// these**, which `SampleLevelContentTests` checks, so a new material cannot arrive silent.
    public static let footstepSurfaces = ["dirt", "stone", "wood", "metal"]

    /// **The sample's lift, in code rather than in the level file.** How a thing moves is behaviour,
    /// and the level format has no behaviour in it — it says *what* is where. A `"lift"` tag is the
    /// game's word, like `"solid"`: this game reads it as "rise 0.9 m, ease in and out over 2.5 s, wait
    /// 1.5 s, come back". The engine's part is only carrying whoever stands on it.
    public static let liftRise: Float = 0.9, liftTravel: Float = 2.5, liftPause: Float = 1.5
    public static var liftCycle: Float { 2 * (liftTravel + liftPause) }

    /// How fast the sample's turntables turn, radians a second — thirty degrees, a full turn in twelve
    /// seconds: slow enough to stand on and look about, fast enough to see it is turning.
    public static let turntableRate: Float = .pi / 6

    /// How far above where the level put it a lift stands, `t` seconds into its cycle: waiting at the
    /// bottom, rising, waiting at the top, coming down. **Eased at both ends** — a lift that starts and
    /// stops at full speed jolts whoever is on it, and in a first-person view a jolt is the camera.
    public static func liftHeight(at t: Float) -> Float {
        shuttle(at: t, distance: liftRise, travel: liftTravel, pause: liftPause)
    }

    /// **The sample's sliding block**, the same way as the lift: a `"slider"` tag in the level, and
    /// the movement here — 5 m along its facing (+x unturned), eased over 4 s, waiting 1.5 s at each end. A block to be pushed
    /// by, at up to 1.9 m/s in the middle of its run; the engine's part is the pushing.
    public static let slideDistance: Float = 5, slideTravel: Float = 4, slidePause: Float = 1.5
    public static var slideCycle: Float { 2 * (slideTravel + slidePause) }

    /// How far along its facing from where the level put it a slider stands, `t` seconds into an
    /// unobstructed cycle. What ``SlideRun`` does while nothing is in its way.
    public static func slideOffset(at t: Float) -> Float {
        shuttle(at: t, distance: slideDistance, travel: slideTravel, pause: slidePause)
    }

    /// **A slider's run, as something that can be turned back** — a door that meets someone reverses.
    /// Waits, goes out eased, waits, comes back eased, as ``slideOffset(at:)`` does; told it has pinned
    /// someone (`CharacterController.pinnedBy`), it turns back from wherever it is, easing home over the
    /// share of the travel time that the way back is of the whole run.
    public struct SlideRun: Sendable, Equatable {
        public enum Leg: Sendable, Equatable { case waiting, out, waitingOut, back }
        public private(set) var leg = Leg.waiting
        public private(set) var offset: Float = 0
        /// Seconds into the current leg, and — going back — where it started from and how long it takes.
        private var t: Float = 0
        private var from: Float = 0
        private var duration: Float = SampleLevel.slideTravel
        /// How many times it has been turned back.
        public private(set) var reversals = 0

        public init() {}

        /// A step on. Returns how far it moved along its facing.
        public mutating func advance(by dt: Float) -> Float {
            let before = offset
            let pause = SampleLevel.slidePause, travel = SampleLevel.slideTravel, distance = SampleLevel.slideDistance
            func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
            t += dt
            // A leg whose time is up hands what is left of the step to the next one.
            legs: while true {
                switch leg {
                case .waiting:
                    guard t >= pause else { break legs }
                    leg = .out; t -= pause
                case .out:
                    offset = distance * ease(t / travel)
                    guard t >= travel else { break legs }
                    leg = .waitingOut; t -= travel
                case .waitingOut:
                    guard t >= pause else { break legs }
                    leg = .back; t -= pause; from = offset; duration = travel
                case .back:
                    offset = from * (1 - ease(t / duration))
                    guard t >= duration else { break legs }
                    leg = .waiting; t -= duration; offset = 0
                }
            }
            return offset - before
        }

        /// It has pinned someone: back the way it came, now. Only going out — a slider coming home is
        /// moving away from whoever it could pin.
        public mutating func turnBack() {
            guard leg == .out, offset > 0 else { return }
            leg = .back
            from = offset
            duration = SampleLevel.slideTravel * offset / SampleLevel.slideDistance
            t = 0
            reversals += 1
        }
    }

    /// **The sample's piston** — a `"piston"` tag — which, unlike the slider, **does not ease**: out at
    /// 1.5 m/s, a dead stop, three seconds' wait, back. A trap, and the jolt is its point. The ruins' one
    /// runs 2.125 m from its rest on the landing to 5 cm past the landing's south edge, which is where it
    /// shoves anyone standing in front of it off — at its full speed, so what they keep is plain.
    public static let pistonSpeed: Float = 1.5, pistonRun: Float = 2.125, pistonPause: Float = 3
    public static var pistonCycle: Float { 2 * (pistonRun / pistonSpeed + pistonPause) }

    /// How far along its facing from where the level put it a piston stands, `t` seconds into its cycle.
    public static func pistonOffset(at t: Float) -> Float {
        let travel = pistonRun / pistonSpeed, p = pistonPause
        if t < p { return 0 }
        if t < p + travel { return pistonSpeed * (t - p) }
        if t < 2 * p + travel { return pistonRun }
        return max(0, pistonRun - pistonSpeed * (t - 2 * p - travel))
    }

    /// Wait, go `distance` eased over `travel`, wait, come back: the lift's shape and the slider's.
    static func shuttle(at t: Float, distance: Float, travel: Float, pause p: Float) -> Float {
        func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
        if t < p { return 0 }
        if t < p + travel { return distance * ease((t - p) / travel) }
        if t < 2 * p + travel { return distance }
        return distance * (1 - ease((t - 2 * p - travel) / travel))
    }

    public static func fileName(_ index: Int) -> String {
        names[min(max(index, 0), names.count - 1)]
    }

    /// The level as shipped, from this target's bundle.
    ///
    /// **From a bundle and never from a path**, which is the engine's distribution rule: the sample
    /// has to run sandboxed or not, so it may not assume it can read wherever it likes.
    public static func bundled(_ index: Int) throws -> Level {
        try Level.load(named: fileName(index), bundle: .module)
    }

    /// Where the editor saves. A bundle is read-only in every arrangement that matters, so an edited
    /// level goes to the user's Application Support — the one place a sandboxed *or* unsandboxed app
    /// can always write.
    ///
    /// **`in:` exists so a test never writes to the real one.** The same lesson as `SaveStore`: a
    /// suite that reaches into the user's Application Support clobbers the level they were editing,
    /// and two tests running in parallel clobber each other.
    public static func writableURL(_ index: Int, in directory: URL? = nil) -> URL {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindageSample", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(fileName(index)).json")
    }

    /// Which of the two files a load actually used.
    public enum Origin: Equatable {
        /// The file in the repository, compiled into the bundle.
        case shipped
        /// A copy the in-game editor has saved. **It shadows the shipped level from then on.**
        case edited
    }

    public struct Loaded {
        public let level: Level
        public let origin: Origin
        /// The file that was read, for printing.
        public let path: String
        /// The file that was *not* read. **Reported on purpose**: a reader who edits the shipped
        /// level, sees nothing change and has no idea an edited copy is shadowing it has been given
        /// a puzzle rather than a lesson.
        public let shadowedPath: String?

        /// One line for the console: which file the level came from, and what it is shadowing.
        public var report: String {
            guard origin == .edited else { return path }
            guard let shadowedPath else { return "\(path) (your edited copy)" }
            return "\(path) (your edited copy — shadowing \(shadowedPath))"
        }
    }

    /// Load a level: the copy the editor saved, or the one this repository ships.
    ///
    /// **Nothing is written here.** An earlier version copied the built-in level out to Application
    /// Support on first run, which meant the file the player edited and the file the repository
    /// shipped were different objects — and an install made before a level changed kept the old one
    /// silently, for ever, with nothing to say so.
    public static func load(_ index: Int, savedIn directory: URL? = nil) -> Loaded {
        let url = writableURL(index, in: directory)
        if let data = try? Data(contentsOf: url), let level = try? Level.decode(from: data) {
            let shipped = Bundle.module.url(forResource: fileName(index), withExtension: "json")
            return Loaded(level: level, origin: .edited, path: url.path, shadowedPath: shipped?.path)
        }
        do {
            let level = try bundled(index)
            let shipped = Bundle.module.url(forResource: fileName(index), withExtension: "json")
            return Loaded(level: level, origin: .shipped,
                          path: shipped?.path ?? fileName(index), shadowedPath: nil)
        } catch {
            // **Loud, and empty rather than wrong.** A level that failed to load must not look like
            // a level somebody authored with nothing in it.
            print("\(Engine.name): FAILED to load \(fileName(index)).json — \(error)")
            return Loaded(level: Level(name: "MISSING"), origin: .shipped,
                          path: fileName(index), shadowedPath: nil)
        }
    }

    /// Delete the editor's copy, so the shipped level is next in line again.
    @discardableResult
    public static func discardEdits(_ index: Int, in directory: URL? = nil) -> Bool {
        (try? FileManager.default.removeItem(at: writableURL(index, in: directory))) != nil
    }
}
