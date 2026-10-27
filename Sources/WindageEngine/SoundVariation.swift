//
//  SoundVariation.swift
//  WindageEngine
//

import Foundation

/// **Which take of a sound to play, and how to vary it.**
///
/// One take played five hundred times is the commonest way game audio grates. The ear catches a repeated
/// sample long before it catches a repeated animation, so every play picks a take that is not the one just
/// heard and nudges its pitch and loudness a little — ``AudioEngine/play(_:volume:pan:rate:)`` takes both.
///
/// A sound is named by a string — a game keeps its own list of what it plays. Taken from a game's combat
/// audio (2026-10-27).
public nonisolated struct SoundVariation: Sendable {

    /// ± this share of playback rate. **Past about 8% a take stops sounding like the same thing.**
    public var pitchSpread: Float
    /// ± this many decibels. Enough that two hits are not identical; not enough that one reads as another.
    public var gainSpreadDecibels: Float

    private var last: [String: Int] = [:]

    public init(pitchSpread: Float = 0.05, gainSpreadDecibels: Float = 1.5) {
        self.pitchSpread = max(pitchSpread, 0)
        self.gainSpreadDecibels = max(gainSpreadDecibels, 0)
    }

    /// A take for `sound` out of `count`, never the one played last for it when there is a choice.
    public mutating func take<G: RandomNumberGenerator>(for sound: String, among count: Int,
                                                         using generator: inout G) -> Int {
        guard count > 1 else { return 0 }
        var chosen = Int.random(in: 0..<(count - 1), using: &generator)
        if let previous = last[sound], chosen >= previous { chosen += 1 }
        last[sound] = chosen
        return chosen
    }

    /// A playback rate and a linear gain to play one take at.
    public func jitter<G: RandomNumberGenerator>(using generator: inout G) -> (rate: Float, gain: Float) {
        let rate = 1 + Float.random(in: -pitchSpread...pitchSpread, using: &generator)
        let decibels = Float.random(in: -gainSpreadDecibels...gainSpreadDecibels, using: &generator)
        return (rate, Float(pow(10, Double(decibels) / 20)))
    }

    /// The take a file belongs to, from its name: `hit_wood_02` is take 2 of `hit_wood`. **Takes are found by
    /// name, not listed**, so a library replaces placeholders by dropping files in. Nil for a name with no
    /// numbered suffix.
    public static func sound(ofTake name: String) -> String? {
        guard let cut = name.lastIndex(of: "_") else { return nil }
        let number = name[name.index(after: cut)...]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return String(name[..<cut])
    }
}
