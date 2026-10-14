//
//  ShaderLibrary.swift
//  WindageEngine
//

import Foundation
import Metal

/// Why ``ShaderLibrary`` could not supply a library. A failure to *compile* the source is Metal's own
/// error, thrown as it is.
public enum ShaderLibraryError: Error, CustomStringConvertible, Sendable {
    /// No compiled library in the bundle, and no `.metal` source to compile one from.
    case noSource(named: String, bundle: String)

    public var description: String {
        switch self {
        case .noSource(let name, let bundle):
            "no compiled Metal library and no \(name).metal in \(bundle) to compile from"
        }
    }
}

/// Gets a Metal library, whether or not anything compiled one at build time.
///
/// ### The problem this exists for, found by trying to be a consumer
///
/// **`swift build` does not compile Metal.** Xcode does — it compiles every `.metal` in a target
/// into a `default.metallib` beside the code — and `MTLDevice.makeDefaultLibrary(bundle:)` finds it.
/// SwiftPM's command-line build produces no metallib at all.
///
/// For this engine's first year that never showed, because its only consumer was an Xcode app. The
/// moment a **sample game** was built as a plain SwiftPM executable — which is how anybody cloning
/// this repo would first try to run it — the HUD failed to initialize with nothing on screen and
/// nothing useful in the log. An engine that can only be run from Xcode is not something other
/// people can build with, which is the entire reason the sample exists.
///
/// So: try the compiled library, and fall back to **compiling the `.metal` source at runtime**. The
/// source is shipped as a resource either way, so nothing new has to be packaged.
///
/// **`nonisolated`**, like the other loaders: compiling a library is work a game may well do off the main
/// thread, and nothing here touches shared state.
public nonisolated enum ShaderLibrary {

    /// - Parameters:
    ///   - sourceNamed: the `.metal` file's name, without extension, shipped in `bundle` as a
    ///     resource — declare it with `.copy(…)` so the *source* survives into the bundle, not
    ///     `.process(…)`, which may consume it.
    ///
    /// **Runtime compilation costs real milliseconds** and happens once at startup. A shipping build
    /// made by Xcode never pays it, because the first branch succeeds.
    public static func make(device: MTLDevice, bundle: Bundle, sourceNamed: String) throws -> MTLLibrary {
        if let compiled = try? device.makeDefaultLibrary(bundle: bundle) {
            return compiled
        }
        guard let url = bundle.url(forResource: sourceNamed, withExtension: "metal") else {
            throw ShaderLibraryError.noSource(named: sourceNamed, bundle: bundle.bundlePath)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }
}
