//
//  SaveStore.swift
//  WindageEngine
//

import Foundation

/// Somewhere to keep what a game remembers between runs.
///
/// ### Why the engine owns this and not each title
///
/// **The engine's distribution rule says it may never assume a writable location outside its
/// container** — it has to run sandboxed or not, because the *title* is what gets distributed and it
/// may go to the App Store. That rule is easy to state and easy to break: the natural thing to write
/// is a path, and a path beside the executable works right up until someone sandboxes the app.
///
/// So there is one place that knows where a game may write, and it is here. `Application Support`
/// resolves correctly under a sandbox *and* outside one, which is the whole requirement.
///
/// ### Atomic, because a crash mid-write is a corrupted save
///
/// Writing over the live file leaves a truncated one if the process dies partway. `Data.write` with
/// `.atomic` writes a temporary and renames, and rename is atomic on APFS — so the save is either
/// the old one or the new one, never half of either.
public nonisolated struct SaveStore<Value: Codable & Sendable>: Sendable {

    /// The folder everything for this game goes in — named, so two games on one machine do not
    /// collide and so a person can find and delete it.
    public let container: String

    /// The file's name inside that folder, without extension.
    public let name: String

    public init(container: String, name: String) {
        self.container = container
        self.name = name
    }

    /// Where the file lives. **Only a path**: asking for it creates nothing — ``save(_:)`` makes the
    /// folder when it first writes.
    public var url: URL {
        folder.appendingPathComponent("\(name).json")
    }

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
    }

    /// What was saved, or `nil` if nothing has been.
    ///
    /// **Throws for a file that is there and will not read or decode** — written by an older build, or
    /// truncated — so a game can say so. A save that will not load must still not stop the game
    /// starting: losing a high score is a disappointment, refusing to launch is a bug report. So the
    /// usual call is `(try? store.load()) ?? fallback`, with a log of the error where it is worth one.
    public func load() throws -> Value? {
        let url = self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the file, if there is one. Used by "reset progress", and by tests that must not leave one
    /// behind. **Throws only when a file that is there cannot be removed.**
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
