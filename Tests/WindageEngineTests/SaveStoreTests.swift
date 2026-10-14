import Testing
import Foundation
@testable import WindageEngine

struct SaveStoreTests {

    private struct Progress: Codable, Equatable, Sendable {
        var bestSeconds: Double
        var runs: Int
    }

    private func store() -> SaveStore<Progress> {
        SaveStore(container: "WindageEngineTests", name: "progress-\(UUID().uuidString)")
    }

    @Test("Nothing saved reads as nothing, not as a failure")
    func emptyLoad() throws {
        let store = self.store()
        #expect(try store.load() == nil)
        try store.clear()
    }

    /// The URL is a path and nothing more: asking for it used to create the folder.
    @Test("Asking where the file is creates nothing")
    func urlIsPure() {
        let store = SaveStore<Progress>(container: "WindageEngineTests-\(UUID().uuidString)", name: "p")
        _ = store.url
        #expect(!FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path))
    }

    @Test("What goes in comes out")
    func roundTrip() throws {
        let store = self.store()
        defer { try? store.clear() }
        let progress = Progress(bestSeconds: 42.5, runs: 3)
        try store.save(progress)
        #expect(try store.load() == progress)
    }

    @Test("Saving again replaces")
    func overwrite() throws {
        let store = self.store()
        defer { try? store.clear() }
        try store.save(Progress(bestSeconds: 10, runs: 1))
        try store.save(Progress(bestSeconds: 9, runs: 2))
        #expect(try store.load() == Progress(bestSeconds: 9, runs: 2))
    }

    /// **A save that will not decode says so**, rather than reading as nothing — the game decides
    /// whether to carry on, and a corrupt save is worth a line in the log on its way to a fresh start.
    @Test("A corrupt save throws, and `try?` reads it as nothing")
    func corruptSave() throws {
        let store = self.store()
        defer { try? store.clear() }
        try store.save(Progress(bestSeconds: 1, runs: 1))
        try Data("this is not json".utf8).write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect((try? store.load()) == nil)
    }

    @Test("Clearing removes the file")
    func clearing() throws {
        let store = self.store()
        try store.save(Progress(bestSeconds: 1, runs: 1))
        #expect(FileManager.default.fileExists(atPath: store.url.path))
        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        try store.clear()   // clearing nothing is not an error
    }

    /// The container is what keeps two games on one machine from overwriting each other.
    @Test("Different containers are different files")
    func containersAreSeparate() throws {
        // Both under one container the suite cleans up, rather than two it leaves behind — a test
        // that litters Application Support is a test that changes the machine it runs on.
        let a = SaveStore<Progress>(container: "WindageEngineTests/a", name: "p")
        let b = SaveStore<Progress>(container: "WindageEngineTests/b", name: "p")
        defer { try? a.clear(); try? b.clear() }
        try a.save(Progress(bestSeconds: 1, runs: 1))
        try b.save(Progress(bestSeconds: 2, runs: 2))
        #expect(try a.load()?.bestSeconds == 1)
        #expect(try b.load()?.bestSeconds == 2)
        #expect(a.url != b.url)
    }
}
