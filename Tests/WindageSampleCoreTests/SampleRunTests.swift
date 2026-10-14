import Testing
import Foundation
import simd
import WindageEngine
@testable import WindageSampleCore

/// **The sample's game loop, tested with no window.**
///
/// This is the reason the sample is split into a library and a thin app at all — the same split the
/// studio requires of a title. A win condition, a clock, a pause and a save are exactly the things
/// that go wrong quietly, and none of them need a drawable to check.
struct SampleRunTests {

    /// **Each test gets its own store.** Swift Testing runs tests in parallel and they all wrote one
    /// shared file, so results depended on which finished first — which is also why `SampleRun` takes
    /// its store rather than reaching for a global one.
    private func store() -> SaveStore<SampleRun.Progress> {
        SaveStore(container: "WindageSampleCoreTests", name: "progress-\(UUID().uuidString)")
    }

    private func run(objectives: Int = 3,
                     store: SaveStore<SampleRun.Progress>? = nil) -> SampleRun {
        SampleRun(objectives: (0..<objectives).map { SIMD3(Float($0) * 20, 0, 0) },
                  store: store ?? self.store())
    }

    @Test("A run starts playing with nothing found and the whole clock")
    func start() {
        let run = self.run()
        #expect(run.mode == .playing)
        #expect(run.found == 0)
        #expect(run.remaining == SampleRun.timeLimit)
        #expect(!run.isOver)
    }

    @Test("Walking onto an objective collects it, once")
    func collecting() {
        var run = self.run()
        run.step(deltaTime: 0.1, playerAt: SIMD3(0, 1.7, 0))
        #expect(run.found == 1)
        run.step(deltaTime: 0.1, playerAt: SIMD3(0, 1.7, 0))
        #expect(run.found == 1, "standing there should not collect the same crate twice")
    }

    /// The player's eye is 1.7 m up and a crate sits on the floor, so reach is measured in the ground
    /// plane — a 3D distance would need a larger number for the same feel and would then let you
    /// collect things from a storey above.
    @Test("Reach is measured on the ground, not through the air")
    func reachIgnoresHeight() {
        var run = self.run(objectives: 1)
        run.step(deltaTime: 0.1, playerAt: SIMD3(0, 40, 0))
        #expect(run.found == 1)
    }

    @Test("Collecting the last one wins, and records the time")
    func winning() {
        var run = self.run(objectives: 2)
        run.step(deltaTime: 1, playerAt: SIMD3(0, 0, 0))
        #expect(run.mode == .playing, "one of two is not a win")
        run.step(deltaTime: 2, playerAt: SIMD3(20, 0, 0))
        #expect(run.mode == .won(seconds: 3))
        #expect(run.isOver)
        #expect(run.progress.wins == 1)
        #expect(run.best == 3)
    }

    @Test("Running out of time loses")
    func losing() {
        var run = self.run()
        run.step(deltaTime: SampleRun.timeLimit + 1, playerAt: SIMD3(0, 0, -500))
        #expect(run.mode == .lost)
        #expect(run.remaining == 0)
        #expect(run.progress.wins == 0)
        #expect(run.progress.runs == 1)
    }

    /// **A pause is "do not advance", not "stop the loop".** The clock must not move and nothing must
    /// be collectable, but the frame loop keeps running — which is why this is the game's job.
    @Test("Pause freezes the clock and collection")
    func pausing() {
        var run = self.run()
        run.step(deltaTime: 5, playerAt: SIMD3(0, 0, -500))
        run.togglePause()
        let frozen = run.remaining
        run.step(deltaTime: 10, playerAt: SIMD3(0, 0, 0))
        #expect(run.remaining == frozen, "the clock ran while paused")
        #expect(run.found == 0, "a crate was collected while paused")
        run.togglePause()
        run.step(deltaTime: 1, playerAt: SIMD3(0, 0, 0))
        #expect(run.found == 1)
    }

    /// A finished run has nothing to pause — and a paused game-over screen you cannot leave is a
    /// hang with a label on it.
    @Test("A finished run cannot be paused")
    func pausingAfterTheEnd() {
        var run = self.run(objectives: 1)
        run.step(deltaTime: 1, playerAt: SIMD3(0, 0, 0))
        #expect(run.isOver)
        run.togglePause()
        #expect(run.mode != .paused)
    }

    @Test("Restart clears the run but keeps what was learned")
    func restarting() {
        var run = self.run(objectives: 1)
        run.step(deltaTime: 4, playerAt: SIMD3(0, 0, 0))
        #expect(run.progress.wins == 1)
        run.restart()
        #expect(run.mode == .playing)
        #expect(run.found == 0)
        #expect(run.remaining == SampleRun.timeLimit)
        #expect(run.progress.wins == 1, "restarting a run must not forget previous ones")
    }

    /// **The point of the save.** A second run in a new process sees the first one's best time.
    @Test("Progress survives into a new run")
    func progressPersists() {
        let store = self.store()
        defer { try? store.clear() }
        var first = SampleRun(objectives: [SIMD3(0, 0, 0)], store: store)
        first.step(deltaTime: 7, playerAt: SIMD3(0, 0, 0))
        #expect(first.best == 7)

        // A fresh value, as a relaunch would build.
        let second = SampleRun(objectives: [SIMD3(0, 0, 0)], store: store)
        #expect(second.best == 7)
        #expect(second.progress.runs == 1)
    }

    @Test("Only a faster run replaces the best")
    func bestOnlyImproves() {
        let store = self.store()
        defer { try? store.clear() }
        var run = SampleRun(objectives: [SIMD3(0, 0, 0)], store: store)
        run.step(deltaTime: 5, playerAt: SIMD3(0, 0, 0))
        run.restart()
        run.step(deltaTime: 30, playerAt: SIMD3(0, 0, 0))
        #expect(run.best == 5, "a slower run overwrote the best time")
        run.restart()
        run.step(deltaTime: 2, playerAt: SIMD3(0, 0, 0))
        #expect(run.best == 2)
    }

    /// A level with no objectives must not win instantly — `allSatisfy` on an empty array is `true`,
    /// which is the classic way an empty level reports itself complete.
    @Test("A level with no objectives does not win itself")
    func emptyLevel() {
        var run = SampleRun(objectives: [], store: self.store())
        run.step(deltaTime: 1, playerAt: .zero)
        #expect(run.mode == .playing)
    }

    /// **Every level, not just the first.** A crate with no marker cannot be collected, and a marker
    /// with no crate is an objective the player cannot see.
    @Test("Every level's crates and objective markers agree", arguments: 0..<SampleLevel.names.count)
    func levelIsConsistent(index: Int) throws {
        let level = try SampleLevel.bundled(index)
        let markers = level.markers(ofKind: "objective")
        let crates = level.placements(tagged: "objective")
        #expect(!markers.isEmpty, "\(level.name) has no objectives, so it wins itself")
        #expect(crates.count == markers.count, "a crate with no marker cannot be collected")
        for (marker, crate) in zip(markers, crates) {
            #expect(marker.position.x == crate.position.x)
            #expect(marker.position.z == crate.position.z)
        }
    }
}

/// **What a step reports back**, which is how the game knows to make a noise without the run knowing
/// anything about sound.
struct SampleRunEventTests {

    private func store() -> SaveStore<SampleRun.Progress> {
        SaveStore(container: "WindageSampleCoreTests", name: "events-\(UUID().uuidString)")
    }

    @Test("A quiet step reports nothing")
    func quietStep() {
        let store = self.store(); defer { try? store.clear() }
        var run = SampleRun(objectives: [SIMD3(100, 0, 0)], store: store)
        #expect(run.step(deltaTime: 0.1, playerAt: .zero).isEmpty)
    }

    /// The position comes back with the event, because the sound has to come from the crate — a
    /// bare "something was collected" would leave the caller guessing which one.
    @Test("Collecting reports where it happened")
    func collectReportsPosition() {
        let store = self.store(); defer { try? store.clear() }
        var run = SampleRun(objectives: [SIMD3(1, 0, 1), SIMD3(90, 0, 0)], store: store)
        let events = run.step(deltaTime: 0.1, playerAt: .zero)
        #expect(events.collected == [SIMD3(1, 0, 1)])
        #expect(!events.won)
    }

    @Test("Winning and losing are each reported once")
    func endingsAreReportedOnce() {
        let winStore = self.store(); defer { try? winStore.clear() }
        var win = SampleRun(objectives: [SIMD3(0, 0, 0)], store: winStore)
        #expect(win.step(deltaTime: 1, playerAt: .zero).won)
        #expect(win.step(deltaTime: 1, playerAt: .zero).isEmpty, "a finished run kept reporting")

        let loseStore = self.store(); defer { try? loseStore.clear() }
        var lose = SampleRun(objectives: [SIMD3(500, 0, 0)], store: loseStore)
        #expect(lose.step(deltaTime: SampleRun.timeLimit + 1, playerAt: .zero).lost)
        #expect(lose.step(deltaTime: 1, playerAt: .zero).isEmpty)
    }

    @Test("A paused step reports nothing")
    func pausedIsSilent() {
        let store = self.store(); defer { try? store.clear() }
        var run = SampleRun(objectives: [SIMD3(0, 0, 0)], store: store)
        run.togglePause()
        #expect(run.step(deltaTime: 1, playerAt: .zero).isEmpty)
    }
}

/// **Two levels is where the assumptions live.** A second copy of the first level would have found
/// none of this; a second level that *differs* found all of it.
struct SecondLevelTests {

    private func store() -> SaveStore<SampleRun.Progress> {
        SaveStore(container: "WindageSampleCoreTests", name: "levels-\(UUID().uuidString)")
    }

    @Test("The sample ships more than one level, and they are not the same")
    func theLevelsDiffer() throws {
        #expect(SampleLevel.names.count >= 2)
        let first = try SampleLevel.bundled(0), second = try SampleLevel.bundled(1)
        #expect(first.name != second.name)
        #expect(first.markers(ofKind: "objective").count != second.markers(ofKind: "objective").count,
                "a run sized from one level must visibly not fit the other")
        #expect(first.markers(ofKind: "spawn").first?.position
                != second.markers(ofKind: "spawn").first?.position)
        // **The skies, not two entries in `settings`.** They differ in more than the sun's angle
        // now — one is a bright afternoon and the other a low, dim, overcast one — and a level that
        // could only say where the sun was could not have expressed that.
        #expect(first.resolvedSky.sunYawDegrees != second.resolvedSky.sunYawDegrees)
        #expect(first.resolvedSky.zenith != second.resolvedSky.zenith,
                "both levels are under the same sky, so nothing tests that a level owns one")
        #expect(first.resolvedSky.sunIrradiance.x > second.resolvedSky.sunIrradiance.x * 2,
                "the overcast level's sun is not meaningfully dimmer than the clear one's")
    }

    /// **A level written before there was a sky still means what it said.** Any level a player edited
    /// and saved lives in Application Support and cannot be rewritten from here, so the two settings
    /// keys that used to carry the sun have to keep working.
    @Test("A level with the old sun settings and no sky still gets that sun")
    func legacySunSettingsStillWork() {
        let legacy = Level(name: "OLD", settings: ["sunPitch": 20, "sunYaw": 100])
        #expect(legacy.sky == nil)
        #expect(abs(legacy.resolvedSky.sunPitchDegrees - 20) < 1e-3)
        #expect(abs(legacy.resolvedSky.sunYawDegrees - 100) < 1e-3)
    }

    /// And a level that says nothing at all still gets a sky rather than a black void.
    @Test("A level with no sky and no settings still gets one")
    func noSkyStillLights() {
        let bare = Level(name: "BARE")
        #expect(bare.resolvedSky.sunIrradiance.x > 0)
        #expect(bare.resolvedSky.zenith == ProceduralSky().zenith)
    }

    /// **The one that actually bit.** Meshes were loaded once at startup from the first level's list,
    /// so anything new in the second drew nothing at all.
    @Test("The second level uses a mesh the first does not")
    func theSecondLevelNeedsANewMesh() throws {
        let first = try Set(SampleLevel.bundled(0).placements.map(\.mesh))
        let second = try Set(SampleLevel.bundled(1).placements.map(\.mesh))
        #expect(!second.subtracting(first).isEmpty,
                "both levels use the same meshes, so loading meshes once would never be caught")
    }

    @Test("Each level keeps its own best time")
    func bestTimesArePerLevel() {
        let store = self.store(); defer { try? store.clear() }
        var one = SampleRun(objectives: [SIMD3(0, 0, 0)], levelName: "COURTYARD", store: store)
        one.step(deltaTime: 5, playerAt: .zero)
        var two = SampleRun(objectives: [SIMD3(0, 0, 0)], levelName: "RUINS", store: store)
        two.step(deltaTime: 40, playerAt: .zero)
        #expect(two.best == 40)
        #expect(two.progress.best["COURTYARD"] == 5, "the second level overwrote the first's record")
    }

    /// **A version field earns its keep exactly once.** A v1 save has one time and no level; it
    /// belonged to the only level that existed, and it must survive rather than being thrown away.
    @Test("A version 1 save migrates instead of being lost")
    func v1Migrates() throws {
        let store = self.store(); defer { try? store.clear() }
        let old = """
        {"version":1,"bestSeconds":12.5,"runs":4,"wins":2}
        """
        try Data(old.utf8).write(to: store.url)
        let progress = try #require(try store.load())
        #expect(progress.version == SampleRun.Progress.currentVersion)
        #expect(progress.best["COURTYARD"] == 12.5)
        #expect(progress.runs == 4)
        #expect(progress.wins == 2)
    }

    /// And a save written now is v2 — migration runs one way.
    @Test("Saving never writes the old shape back")
    func migrationIsOneWay() throws {
        let store = self.store(); defer { try? store.clear() }
        var progress = SampleRun.Progress()
        progress.best["RUINS"] = 30
        try store.save(progress)
        let json = String(data: try Data(contentsOf: store.url), encoding: .utf8)!
        #expect(!json.contains("bestSeconds"))
        #expect(json.contains("\"version\" : 2"))
    }
}

/// The levels are files now, not functions. These pin the part of that which can go wrong quietly.
@Suite("Levels are files")
struct SampleLevelFileTests {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindageSampleLevelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **The failure this replaces was silent.** When the levels were built in code there was
    /// nothing to ship and nothing to miss; a resource, by contrast, is one `Package.swift` line
    /// away from not being in the bundle at all, and the game would simply start on an empty world.
    @Test("Every level named actually ships", arguments: 0..<SampleLevel.names.count)
    func everyLevelShips(index: Int) throws {
        let level = try SampleLevel.bundled(index)
        #expect(!level.placements.isEmpty, "\(SampleLevel.fileName(index)).json is not in the bundle")
        #expect(level.formatVersion <= Level.currentVersion)
    }

    /// **An index out of range is a real level, not a missing one.** The names clamp, so there is
    /// no way through this API to ask for a file that does not exist — worth pinning, because the
    /// alternative reads as "loading is fault-tolerant" when it is the *index* that is.
    @Test("An out-of-range index clamps to a level that exists")
    func indicesClamp() {
        let loaded = SampleLevel.load(99, savedIn: scratch())
        #expect(loaded.level.name != "MISSING")
        #expect(SampleLevel.fileName(99) == SampleLevel.names.last)
        #expect(SampleLevel.fileName(-3) == SampleLevel.names.first)
    }

    @Test("With no edited copy, the shipped level is what loads")
    func shippedByDefault() {
        let loaded = SampleLevel.load(0, savedIn: scratch())
        #expect(loaded.origin == .shipped)
        #expect(loaded.shadowedPath == nil)
        #expect(loaded.report == loaded.path)
    }

    /// **And it says what it is shadowing.** A reader who edits the repository's `courtyard.json`,
    /// sees nothing change, and is told nothing has been handed a puzzle instead of a lesson.
    @Test("An edited copy shadows the shipped level, and says so")
    func editedShadowsShipped() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var level = try SampleLevel.bundled(0)
        level.name = "EDITED"
        try level.encoded().write(to: SampleLevel.writableURL(0, in: directory))

        let loaded = SampleLevel.load(0, savedIn: directory)
        #expect(loaded.origin == .edited)
        #expect(loaded.level.name == "EDITED")
        #expect(loaded.shadowedPath != nil, "it must name the file it is shadowing")
        #expect(loaded.report.contains("shadowing"))
    }

    @Test("Discarding the edit puts the shipped level back")
    func discardingRestoresShipped() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var level = try SampleLevel.bundled(1)
        level.name = "EDITED"
        try level.encoded().write(to: SampleLevel.writableURL(1, in: directory))
        #expect(SampleLevel.load(1, savedIn: directory).origin == .edited)

        #expect(SampleLevel.discardEdits(1, in: directory))
        #expect(SampleLevel.load(1, savedIn: directory).origin == .shipped)
    }

    /// **Loading must not write.** The old version copied the built-in level out on first run, so
    /// the file the player edited and the file the repository shipped were different objects — and
    /// an install made before a level changed kept the stale one for ever with nothing to say so.
    @Test("Loading a level writes nothing")
    func loadingWritesNothing() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = SampleLevel.load(0, savedIn: directory)
        _ = SampleLevel.load(1, savedIn: directory)

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written.isEmpty, "loading left \(written) behind")
    }

    /// The format round-trips through the file the game actually ships, not through one a test made.
    @Test("A shipped level survives a save and a reload", arguments: 0..<SampleLevel.names.count)
    func shippedLevelsRoundTrip(index: Int) throws {
        let level = try SampleLevel.bundled(index)
        let again = try Level.decode(from: level.encoded())
        #expect(again.name == level.name)
        #expect(again.placements.count == level.placements.count)
        #expect(again.markers.count == level.markers.count)
        #expect(again.settings == level.settings)
    }
}
