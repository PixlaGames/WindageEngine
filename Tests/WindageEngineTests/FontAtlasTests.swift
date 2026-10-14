//
//  FontAtlasTests.swift
//  WindageEngineTests
//

import Testing
import Metal
import simd
@testable import WindageEngine

/// Guards the glyph sheet's metrics — the half of text rendering that can be checked without
/// drawing anything.
@MainActor
struct FontAtlasTests {

    private func makeAtlas() throws -> FontAtlas {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try FontAtlas(device: device)
    }

    @Test("The sheet builds and covers printable ASCII")
    func coversPrintableASCII() throws {
        let atlas = try makeAtlas()
        for scalar in 33...126 {
            let character = Character(UnicodeScalar(scalar)!)
            #expect(atlas.glyph(for: character) != nil, "no glyph for \(character)")
        }
    }

    /// Solid shapes and text share a pipeline by sampling an opaque texel from this same sheet, so a
    /// wrong coordinate here takes the *entire* interface with it — which is exactly what happened
    /// when CoreGraphics' bottom-left origin was mistaken for the texture's top-left one.
    @Test("The white texel sits inside the sheet, in the bottom half")
    func whiteTexelIsWhereItWasDrawn() throws {
        let atlas = try makeAtlas()
        #expect(atlas.whiteTexelUV.x > 0 && atlas.whiteTexelUV.x < 1)
        #expect(atlas.whiteTexelUV.y > 0 && atlas.whiteTexelUV.y < 1)
        // Drawn at CoreGraphics y = 0, which is the bottom of the texture: v must be near 1.
        #expect(atlas.whiteTexelUV.y > 0.9)
    }

    @Test("Every glyph's sheet coordinates stay inside the sheet")
    func glyphsAreInBounds() throws {
        let atlas = try makeAtlas()
        for scalar in 33...126 {
            guard let glyph = atlas.glyph(for: Character(UnicodeScalar(scalar)!)) else { continue }
            #expect(glyph.uvOrigin.x >= 0 && glyph.uvOrigin.y >= 0)
            #expect(glyph.uvOrigin.x + glyph.uvSize.x <= 1.0001)
            #expect(glyph.uvOrigin.y + glyph.uvSize.y <= 1.0001)
        }
    }

    @Test("Advances are positive, and space has one")
    func advancesAreSane() throws {
        let atlas = try makeAtlas()
        #expect(try #require(atlas.glyph(for: "A")).advance > 0)
        // A space has no ink but must still move the pen, or words run together.
        #expect(try #require(atlas.glyph(for: " ")).advance > 0)
    }

    @Test("Measured width scales with point size and with length")
    func widthScales() throws {
        let atlas = try makeAtlas()
        let short = atlas.width(of: "RANGE", pointSize: 24)
        let long = atlas.width(of: "RANGE 812 m", pointSize: 24)
        #expect(long > short)

        let doubled = atlas.width(of: "RANGE", pointSize: 48)
        #expect(abs(doubled - short * 2) < 0.01)
    }

    /// Monospaced on purpose: a range ticking from 811 to 812 must not shift the characters around
    /// it. Proportional digits make a readout twitch every time it updates.
    @Test("Digits are all the same width")
    func digitsAreMonospaced() throws {
        let atlas = try makeAtlas()
        let widths = (0...9).map { atlas.width(of: String($0), pointSize: 24) }
        for width in widths {
            #expect(abs(width - widths[0]) < 0.001)
        }
    }
}

/// A line's height follows the point size it is drawn at, as a glyph's width does.
@MainActor @Test func lineHeightScalesWithPointSize() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = try FontAtlas(device: device)
    #expect(atlas.lineHeight(pointSize: 20) > 20)
    #expect(abs(atlas.lineHeight(pointSize: 40) - 2 * atlas.lineHeight(pointSize: 20)) < 1e-3)
}
