//
//  VersionTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
@testable import WindageEngine

@MainActor
struct SemanticVersionTests {

    @Test("A version formats and parses back")
    func roundTrip() {
        let version = SemanticVersion(major: 1, minor: 12, patch: 3)
        #expect(version.description == "1.12.3")
        #expect(SemanticVersion("1.12.3") == version)
    }

    /// `v1.0.0` is a common habit and it is not what SwiftPM resolves, so it is rejected here rather
    /// than parsed leniently and disagreeing with the tag it came from.
    @Test("Anything that is not major.minor.patch is refused")
    func badVersionsAreRefused() {
        for text in ["v1.0.0", "1.0", "1.0.0.0", "1.0.x", "", "-1.0.0", "1.0.0-beta"] {
            #expect(SemanticVersion(text) == nil, "'\(text)' should not have parsed")
        }
    }

    @Test("A version is a key and a lossless string")
    func hashableAndLossless() {
        let versions: Set<SemanticVersion> = [SemanticVersion(major: 0, minor: 9, patch: 0),
                                              SemanticVersion(major: 0, minor: 9, patch: 0),
                                              SemanticVersion(major: 1, minor: 0, patch: 0)]
        #expect(versions.count == 2)
        func roundTrip<T: LosslessStringConvertible & Equatable>(_ value: T) -> Bool { T(value.description) == value }
        #expect(roundTrip(Engine.semanticVersion))
    }

    @Test("Ordering is by major, then minor, then patch")
    func ordering() {
        #expect(SemanticVersion("0.1.0")! < SemanticVersion("0.2.0")!)
        #expect(SemanticVersion("0.9.9")! < SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("1.0.1")! > SemanticVersion("1.0.0")!)
    }
}

/// Ties the version in code to the changelog that explains it.
///
/// **A changelog that is allowed to fall behind is worse than none**, because a consumer reads it
/// and believes it. Nothing else in a release process forces the entry to be written — the build
/// does not care — so this test is the thing that does.
@MainActor
struct ChangelogTests {

    /// Found relative to this source file rather than through a bundle: the changelog is a document
    /// at the root of the repository, not a resource anything ships.
    private var changelog: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // WindageEngineTests
                .deletingLastPathComponent()      // Tests
                .deletingLastPathComponent()      // the repository root
            return try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"),
                              encoding: .utf8)
        }
    }

    /// Every released version in the file, newest first.
    private func releases(in text: String) -> [SemanticVersion] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("## ["), let close = line.firstIndex(of: "]") else { return nil }
            let name = line[line.index(line.startIndex, offsetBy: 4)..<close]
            return SemanticVersion(String(name))
        }
    }

    /// Before the first release there is nothing to match, and the version is the one that release will be.
    @Test("The newest release in the changelog is the version the engine reports")
    func changelogMatchesTheVersion() throws {
        let listed = releases(in: try changelog)
        guard let newest = listed.first else {
            #expect(Engine.semanticVersion == SemanticVersion(major: 1, minor: 0, patch: 0),
                    "nothing is released yet, so the engine should report 1.0.0, not \(Engine.version)")
            return
        }
        #expect(newest == Engine.semanticVersion,
                "CHANGELOG.md's newest entry is \(newest) but Engine.version is \(Engine.version)")
    }

    @Test("Releases are listed newest first")
    func releasesAreOrdered() throws {
        let listed = releases(in: try changelog)
        #expect(listed == listed.sorted(by: >), "the changelog is out of order")
    }

    /// An Unreleased section is where a change lands before it has a number. It is there only while it holds
    /// something — an empty heading tells a reader nothing — and it sits above every release.
    @Test("Unreleased, when there is one, holds notes and comes first")
    func unreleasedHoldsNotes() throws {
        let lines = try changelog.split(separator: "\n", omittingEmptySubsequences: false)
        guard let heading = lines.firstIndex(of: "## [Unreleased]") else { return }
        let firstRelease = lines.firstIndex { $0.hasPrefix("## [") && $0 != "## [Unreleased]" } ?? lines.endIndex
        #expect(heading < firstRelease, "Unreleased is below a release")
        let notes = lines[(heading + 1)..<firstRelease].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(!notes.isEmpty, "Unreleased is empty")
    }

    /// Each version in a heading is a link to its release, as Keep a Changelog has it.
    @Test("Every release links to its page")
    func releasesAreLinked() throws {
        let text = try changelog
        for version in releases(in: text) {
            #expect(text.contains("\n[\(version)]: https://"), "\(version) has no link")
        }
    }
}
