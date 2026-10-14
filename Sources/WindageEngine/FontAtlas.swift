//
//  FontAtlas.swift
//  WindageEngine
//

import AppKit
import CoreText
import Metal
import simd

/// Why a ``FontAtlas`` could not be built.
public enum FontAtlasError: Error, CustomStringConvertible, Sendable {
    /// The characters asked for do not fit on one 1024 × 1024 sheet at the raster height.
    case tooManyCharacters(Int)
    /// CoreGraphics or the device would not create what the sheet is drawn into or uploaded to.
    case couldNotCreate(String)

    public var description: String {
        switch self {
        case .tooManyCharacters(let count): "\(count) characters do not fit on one glyph sheet"
        case .couldNotCreate(let what): "could not create the font atlas's \(what)"
        }
    }
}

/// A rasterized glyph sheet, built at launch from an installed font.
///
/// **Why rasterize at runtime rather than ship an atlas file.** A baked atlas is another asset to
/// generate, version, and keep in step with the metrics that describe it — three things that drift
/// apart. Rasterizing at launch costs a few milliseconds once and cannot fall out of sync with
/// itself.
///
/// **Why a bitmap and not signed distance fields.** SDF scales to any size from one sheet and is the
/// right answer eventually. It is also a materially bigger piece of work, and a HUD drawn at a
/// handful of sizes does not need it. Rasterizing generously and scaling *down* covers the range a
/// HUD actually uses; scaling up is what looks bad, and this deliberately avoids it.
public final class FontAtlas {

    /// Height the glyphs are rasterized at. Drawing smaller than this is a clean downscale; drawing
    /// much larger will soften.
    public static let rasterHeight: CGFloat = 64

    /// Gap between glyphs in the sheet, so linear filtering cannot pull in a neighbor's edge.
    private static let padding: CGFloat = 4

    struct Glyph: Sendable {
        /// Position in the sheet, normalized.
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        /// Size and offset in raster pixels, relative to the text origin and baseline.
        let size: SIMD2<Float>
        let bearing: SIMD2<Float>
        let advance: Float
    }

    /// The sheet. ``HUDRenderer/allocations`` carries it to the residency set.
    let texture: MTLTexture
    /// A fully opaque texel, so solid rectangles and text can share one pipeline and one draw call.
    let whiteTexelUV: SIMD2<Float>
    /// Ascent, descent and leading at ``rasterHeight``.
    private let rasterLineHeight: Float

    private var glyphs: [Character: Glyph] = [:]

    /// Characters the sheet could not include, because the font has no glyph for them.
    ///
    /// **Reported rather than silently dropped.** A character with no glyph draws nothing at all,
    /// which is invisible in exactly the way a missing HUD element must not be: it cost this engine
    /// a `×` that vanished out of a scope readout and a whole row of keyboard symbols that vanished
    /// out of the sample's hints, and in both cases the text simply looked oddly spaced.
    public private(set) var unavailableCharacters: Set<Character> = []

    /// - Parameter additionalCharacters: anything beyond printable ASCII the game intends to draw.
    ///   **ASCII is the default and not a limit** — a HUD that wants `×`, `·` or `⌘` asks for it
    ///   here, and finds out at load whether the font can supply it.
    /// - Throws: ``FontAtlasError``.
    public init(device: MTLDevice,
                 font: NSFont = .monospacedSystemFont(ofSize: FontAtlas.rasterHeight, weight: .medium),
                 additionalCharacters: Set<Character> = []) throws {
        let ctFont = font as CTFont
        let ascii = (32...126).map { Character(UnicodeScalar($0)!) }
        let characters = ascii + additionalCharacters.subtracting(ascii).sorted()

        // Measure everything first, then lay it out in rows.
        var measured: [(Character: Character, glyph: CGGlyph, rect: CGRect, advance: CGFloat)] = []
        for character in characters {
            let utf16 = Array(String(character).utf16)
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyph, 1) else {
                unavailableCharacters.insert(character)
                continue
            }

            var rect = CGRect.zero
            var advance = CGSize.zero
            withUnsafePointer(to: glyph) { pointer in
                _ = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, pointer, &rect, 1)
                _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, pointer, &advance, 1)
            }
            measured.append((character, glyph, rect, advance.width))
        }

        // A square sheet wide enough for the widest row.
        let cellHeight = ceil(FontAtlas.rasterHeight * 1.5) + FontAtlas.padding
        let widest = measured.map { ceil($0.rect.width) + FontAtlas.padding }.max() ?? 1
        let columns = max(1, Int((1024 / widest).rounded(.down)))
        let rows = Int(ceil(Double(measured.count + 1) / Double(columns)))
        let sheetSize = 1024
        guard Double(rows) * Double(cellHeight) <= Double(sheetSize) else {
            throw FontAtlasError.tooManyCharacters(measured.count)
        }

        guard let context = CGContext(
            data: nil, width: sheetSize, height: sheetSize,
            bitsPerComponent: 8, bytesPerRow: sheetSize,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw FontAtlasError.couldNotCreate("drawing context") }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sheetSize, height: sheetSize))
        context.setFillColor(gray: 1, alpha: 1)

        // The white texel lives in the very first cell, where nothing else is drawn.
        //
        // **Note the V coordinate.** CoreGraphics puts its origin at the bottom-left, while row 0 of
        // the uploaded texture is the *top*. So a rect drawn at CG y=0 ends up at the bottom of the
        // texture, near v = 1. Getting this backwards samples empty sheet, which reads as coverage 0
        // — and since solid shapes sample this same texel, the entire interface silently vanishes.
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        whiteTexelUV = SIMD2(2.0 / Float(sheetSize), (Float(sheetSize) - 2.0) / Float(sheetSize))

        var cursor = CGPoint(x: 8, y: 0)
        var rowHeight = cellHeight

        for entry in measured {
            let width = ceil(entry.rect.width) + FontAtlas.padding
            if cursor.x + width > CGFloat(sheetSize) {
                cursor.x = 0
                cursor.y += rowHeight
                rowHeight = cellHeight
            }

            // CoreGraphics origin is bottom-left; place the glyph so its bounding box sits inside
            // the cell with the padding as a margin.
            let drawX = cursor.x - entry.rect.minX + FontAtlas.padding / 2
            let drawY = cursor.y - entry.rect.minY + FontAtlas.padding / 2
            var position = CGPoint(x: drawX, y: drawY)
            var glyph = entry.glyph
            CTFontDrawGlyphs(ctFont, &glyph, &position, 1, context)

            let originX = cursor.x + FontAtlas.padding / 2
            let originY = cursor.y + FontAtlas.padding / 2
            // CG y (up from the bottom) to texture v (down from the top). `uvOrigin` is the
            // glyph's TOP-left corner in texture space.
            let topInTexture = CGFloat(sheetSize) - (originY + entry.rect.height)
            glyphs[entry.Character] = Glyph(
                uvOrigin: SIMD2(Float(originX) / Float(sheetSize), Float(topInTexture) / Float(sheetSize)),
                uvSize: SIMD2(Float(entry.rect.width) / Float(sheetSize), Float(entry.rect.height) / Float(sheetSize)),
                size: SIMD2(Float(entry.rect.width), Float(entry.rect.height)),
                bearing: SIMD2(Float(entry.rect.minX), Float(entry.rect.minY)),
                advance: Float(entry.advance))

            cursor.x += width
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: sheetSize, height: sheetSize, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else {
            throw FontAtlasError.couldNotCreate("texture")
        }
        texture.label = "FontAtlas"
        texture.replace(region: MTLRegionMake2D(0, 0, sheetSize, sheetSize),
                        mipmapLevel: 0, withBytes: data, bytesPerRow: sheetSize)
        self.texture = texture
        self.rasterLineHeight = Float(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
    }

    func glyph(for character: Character) -> Glyph? { glyphs[character] }

    /// The distance from one baseline to the next when drawn at `pointSize`, in the same units.
    public func lineHeight(pointSize: Float) -> Float {
        rasterLineHeight * pointSize / Float(FontAtlas.rasterHeight)
    }

    /// Width of a string when drawn at `pointSize`, in the same units.
    public func width(of text: String, pointSize: Float) -> Float {
        let scale = pointSize / Float(FontAtlas.rasterHeight)
        return text.reduce(Float(0)) { $0 + (glyph(for: $1)?.advance ?? 0) * scale }
    }
}
