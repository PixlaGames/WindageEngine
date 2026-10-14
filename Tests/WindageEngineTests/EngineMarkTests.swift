//
//  EngineMarkTests.swift
//  WindageEngineTests
//

import Foundation
import Testing
import simd
@testable import WindageEngine

/// **The mark in `Brand/` and the mark on screen are one drawing.**
///
/// Every file in `Brand/` that shows the mark is written from ``EngineMark/outline`` by the functions
/// below, and this suite fails if a file on disk and the outline disagree. Redraw the mark by changing
/// the construction in `EngineMark` and re-recording:
///
/// ```
/// WINDAGE_RECORD_MARK=1 swift test --filter EngineMarkTests
/// ```
///
/// The PNG exports in `Brand/exports` are rasterised from these files.
@Suite("The engine's mark")
struct EngineMarkTests {

    static var brand: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/WindageEngineTests/EngineMarkTests.swift
            .deletingLastPathComponent()          // …/Tests/WindageEngineTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/
            .appendingPathComponent("Brand")
    }

    /// A number as short as it can be written without changing it, so a re-recording diffs as a moved
    /// point and not as a reformatted file.
    static func number(_ value: Float) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// The outline placed in a square of `side` units, scaled by `share` about its centre.
    static func points(side: Float, share: Float = 1) -> String {
        EngineMark.outline
            .map { SIMD2(repeating: side / 2) + ($0 - 0.5) * side * share }
            .map { "\(number($0.x)),\(number($0.y))" }
            .joined(separator: " ")
    }

    static func header(_ side: Int, _ description: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(side) \(side)\" width=\"\(side)\" height=\"\(side)\""
            + " role=\"img\" aria-label=\"\(Engine.name)\">\n"
            + "  <title>\(Engine.name)</title>\n"
            + "  <desc>\(description) Generated from EngineMark.outline — see Brand/README.md.</desc>\n"
    }

    static func hex(_ color: InterfaceColor) -> String {
        let c = SIMD3(color.srgb.x, color.srgb.y, color.srgb.z) * 255
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    /// The mark alone, in one tone, filling its square.
    static func mark(_ tone: InterfaceColor) -> String {
        header(100, "The Drift W.") + "  <polygon fill=\"\(hex(tone))\" points=\"\(points(side: 100))\"/>\n</svg>\n"
    }

    /// The app icon on Apple's grid: a 1024 canvas, an 824 tile inset 100 with a 185.4 corner, the
    /// mark at 56% of the canvas.
    static var icon: String {
        header(1024, "App icon on the 1024 grid.")
            + "  <defs><linearGradient id=\"ground\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">"
            + "<stop offset=\"0\" stop-color=\"#2A2F37\"/><stop offset=\"1\" stop-color=\"#0C0E11\"/></linearGradient></defs>\n"
            + "  <rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185.4\" fill=\"url(#ground)\"/>\n"
            + "  <rect x=\"103\" y=\"103\" width=\"818\" height=\"818\" rx=\"182.4\" fill=\"none\" stroke=\"#FFFFFF\" stroke-opacity=\"0.07\" stroke-width=\"6\"/>\n"
            + "  <polygon fill=\"\(hex(EngineMark.display))\" points=\"\(points(side: 1024, share: 0.56))\"/>\n</svg>\n"
    }

    /// A browser tab: the tile fills the square, the mark at 76%.
    static var favicon: String {
        header(100, "Favicon.")
            + "  <rect width=\"100\" height=\"100\" rx=\"22\" fill=\"#16191E\"/>\n"
            + "  <polygon fill=\"\(hex(EngineMark.display))\" points=\"\(points(side: 100, share: 0.76))\"/>\n</svg>\n"
    }

    static let files: [(name: String, contents: String)] = [
        ("windage-engine.svg", mark(EngineMark.deep)),
        ("windage-engine-display.svg", mark(EngineMark.display)),
        ("windage-engine-icon.svg", icon),
        ("favicon.svg", favicon),
    ]

    @Test("Every mark in Brand/ is the mark in the code", arguments: files.map(\.name))
    func fileMatchesTheOutline(name: String) throws {
        let wanted = try #require(Self.files.first { $0.name == name }).contents
        let url = Self.brand.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["WINDAGE_RECORD_MARK"] != nil {
            try FileManager.default.createDirectory(at: Self.brand, withIntermediateDirectories: true)
            try wanted.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let complaint = "\(name) is not what EngineMark.outline draws. Re-record it: "
            + "WINDAGE_RECORD_MARK=1 swift test --filter EngineMarkTests"
        #expect(onDisk == wanted, "\(complaint)")
    }

    @Test("The outline stays inside its own square")
    func insideItsSquare() {
        for (index, point) in EngineMark.outline.enumerated() {
            #expect(point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1, "point \(index) is at \(point)")
        }
    }

    /// **What makes it a W and not two Vs**: the middle apex well below both shoulders. The first
    /// drawing of this mark was two Vs overlapping, whose middle peak reached as high as its outer
    /// tops, and it read as VV.
    @Test("The middle apex sits well below both shoulders")
    func itIsAW() {
        let o = EngineMark.outline
        let apex = o[3].y, leftShoulder = o[0].y, rightShoulder = o[6].y
        #expect(apex - max(leftShoulder, rightShoulder) > 0.2,
                "the apex is at \(apex), the shoulders at \(leftShoulder) and \(rightShoulder)")
        #expect(o[3].y == o[4].y, "the apex is not cut flat")
    }

    /// **The windage**: the right shoulder and the right valley both carried up by the offset, and
    /// nothing else moved.
    @Test("The right half is carried up by the offset, and only the right half")
    func theRightHalfIsCarried() {
        let o = EngineMark.outline, level = EngineMark.outline(offset: 0)
        #expect(abs((level[6].y - o[6].y) - EngineMark.offset) < 1e-5, "right shoulder")
        #expect(abs((level[8].y - o[8].y) - EngineMark.offset) < 1e-5, "right valley")
        for index in [0, 1, 11, 12] {
            #expect(simd_distance(o[index], level[index]) < 1e-5, "point \(index) on the left moved")
        }
        #expect(abs(o[0].y - o[6].y - EngineMark.offset) < 1e-5 && abs(o[12].y - o[8].y - EngineMark.offset) < 1e-5)
    }

    /// The fill rule depends on it: an outline that crosses itself triangulates short.
    @Test("The outline never crosses itself")
    func simple() {
        let o = EngineMark.outline, n = o.count
        func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
            func turn(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            return turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0
        }
        for i in 0..<n {
            for j in 0..<n where j != i && (j + 1) % n != i && (i + 1) % n != j {
                #expect(!crosses(o[i], o[(i + 1) % n], o[j], o[(j + 1) % n]), "edge \(i) crosses edge \(j)")
            }
        }
    }

    /// Filled, it covers exactly its outline: the triangles' areas add up to the polygon's.
    @Test("Its triangles cover exactly its outline")
    func trianglesCoverIt() {
        let o = EngineMark.outline
        let indices = HUDRenderer.triangulate(o)
        #expect(indices.count == (o.count - 2) * 3)
        #expect(abs(HUDTriangulationTests.area(of: indices, in: o) - HUDTriangulationTests.area(of: o)) < 1e-5)
    }

    /// The file's colour is the tone it is for, written out.
    @Test("Each one-tone file carries its own tone")
    func tones() {
        #expect(Self.files[0].contents.contains("fill=\"#1B2027\""))
        #expect(Self.files[1].contents.contains("fill=\"#F2F4F7\""))
    }
}
