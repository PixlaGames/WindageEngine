//
//  AppFocusWatch.swift
//  WindageEngine
//

import AppKit

/// **Whether the application is the front app, as it changes** — for sound that goes quiet while a player is
/// looking at something else. **Application active, not window key**: a game's own Settings window, or a
/// purchase sheet, takes key status from the game window, and reacting to those would be a bug.
///
/// Its observers go when it does.
final class AppFocusWatch {
    // Unsafe only in name: removing an observer is safe from any thread, and the deinit is the last use.
    nonisolated(unsafe) private let tokens: [NSObjectProtocol]

    /// - Parameter changed: called on the main thread with `true` when the application goes to the
    ///   background and `false` when it comes back.
    init(_ changed: @escaping @MainActor (_ inBackground: Bool) -> Void) {
        let centre = NotificationCenter.default
        tokens = [(NSApplication.didResignActiveNotification, true),
                  (NSApplication.didBecomeActiveNotification, false)].map { name, background in
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed(background) }
            }
        }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
