//
//  InterfaceImage.swift
//  WindageEngine
//

import simd

/// **How an interface image is cut and how much of it is drawn** — the three things interface art is made for, beyond
/// being stretched over a rectangle:
///
/// - **Sliced** (nine-slice): the corners keep their size, the edges stretch along their length, the middle stretches
///   both ways — so one frame or bar sprite fits a panel of any size without its bezel smearing.
/// - **Filled**: a share of it drawn — from one side, for a bar; round from a start angle, for a dial or a hold.
/// - **Clipped**: only what lies inside a rectangle, for a strip that scrolls under a window (a compass).
///
/// What comes out is triangles, each corner a position and a texture coordinate, which ``HUDRenderer`` draws with the
/// image's texture. The geometry is worked out here, apart from drawing, so it can be checked without a GPU.
public nonisolated struct InterfaceImage: Sendable, Equatable {

    /// A share of an image drawn.
    public enum Fill: Sendable, Equatable {
        /// All of it.
        case whole
        /// `amount` of its width, from the left — or from the right.
        case horizontal(amount: Float, fromRight: Bool = false)
        /// `amount` of its height, from the bottom — or from the top.
        case vertical(amount: Float, fromTop: Bool = false)
        /// `amount` of a full turn about its centre, starting at `start` radians (0 points right, a quarter turn points
        /// up the screen) and sweeping clockwise on screen, or the other way.
        case radial(amount: Float, start: Float = .pi / 2, clockwise: Bool = true)
    }

    /// **The border, in texels**: how far in from its left, top, right and bottom edges the image's corners end.
    /// Zero everywhere draws it stretched whole.
    public var border: SIMD4<Float>
    /// Screen units a border texel covers — a 4K-authored bezel drawn on a 1080p screen is 0.5.
    public var borderScale: Float
    /// Whether the middle is drawn — off for a frame that is only a frame.
    public var fillsCentre: Bool
    public var fill: Fill

    public init(border: SIMD4<Float> = .zero, borderScale: Float = 1, fillsCentre: Bool = true, fill: Fill = .whole) {
        self.border = border
        self.borderScale = borderScale
        self.fillsCentre = fillsCentre
        self.fill = fill
    }

    /// One corner of a triangle: where on screen, and where in the texture (0…1, origin top-left).
    public struct Corner: Sendable, Equatable {
        public var position: SIMD2<Float>
        public var uv: SIMD2<Float>
        public init(_ position: SIMD2<Float>, _ uv: SIMD2<Float>) {
            self.position = position
            self.uv = uv
        }
    }

    /// **The triangles that draw it** over the rectangle at `origin` (its top-left) and `size`, unturned, for a texture
    /// `textureSize` texels across — three corners each.
    ///
    /// A border wider than the rectangle shrinks in proportion, as Unity's does, rather than overlapping itself. A
    /// fill applies to an unsliced image (interface packs fill bars and dials, not frames); with a border it is ignored.
    public func triangles(origin: SIMD2<Float>, size: SIMD2<Float>, textureSize: SIMD2<Float>) -> [Corner] {
        guard size.x > 0, size.y > 0, textureSize.x > 0, textureSize.y > 0 else { return [] }
        if border != .zero {
            return sliced(origin: origin, size: size, textureSize: textureSize)
        }
        switch fill {
        case .whole:
            return Self.quad(origin, origin + size, .zero, SIMD2(1, 1))
        case .horizontal(let amount, let fromRight):
            let a = min(max(amount, 0), 1)
            guard a > 0 else { return [] }
            return fromRight
                ? Self.quad(SIMD2(origin.x + size.x * (1 - a), origin.y), origin + size, SIMD2(1 - a, 0), SIMD2(1, 1))
                : Self.quad(origin, SIMD2(origin.x + size.x * a, origin.y + size.y), .zero, SIMD2(a, 1))
        case .vertical(let amount, let fromTop):
            let a = min(max(amount, 0), 1)
            guard a > 0 else { return [] }
            return fromTop
                ? Self.quad(origin, SIMD2(origin.x + size.x, origin.y + size.y * a), .zero, SIMD2(1, a))
                : Self.quad(SIMD2(origin.x, origin.y + size.y * (1 - a)), origin + size, SIMD2(0, 1 - a), SIMD2(1, 1))
        case .radial(let amount, let start, let clockwise):
            return radial(origin: origin, size: size, amount: amount, start: start, clockwise: clockwise)
        }
    }

    /// Nine pieces: the corners at the border's size, the edges stretched along, the middle both ways.
    private func sliced(origin: SIMD2<Float>, size: SIMD2<Float>, textureSize: SIMD2<Float>) -> [Corner] {
        // Left, top, right, bottom — on screen, shrunk together where the rectangle is too small for them.
        var left = border.x * borderScale, top = border.y * borderScale
        var right = border.z * borderScale, bottom = border.w * borderScale
        if left + right > size.x { let k = size.x / (left + right); left *= k; right *= k }
        if top + bottom > size.y { let k = size.y / (top + bottom); top *= k; bottom *= k }
        let xs = [origin.x, origin.x + left, origin.x + size.x - right, origin.x + size.x]
        let ys = [origin.y, origin.y + top, origin.y + size.y - bottom, origin.y + size.y]
        let us = [0, border.x / textureSize.x, 1 - border.z / textureSize.x, 1]
        let vs = [0, border.y / textureSize.y, 1 - border.w / textureSize.y, 1]
        var out: [Corner] = []
        for row in 0..<3 {
            for column in 0..<3 where fillsCentre || row != 1 || column != 1 {
                guard xs[column + 1] > xs[column], ys[row + 1] > ys[row] else { continue }
                out += Self.quad(SIMD2(xs[column], ys[row]), SIMD2(xs[column + 1], ys[row + 1]),
                                 SIMD2(us[column], vs[row]), SIMD2(us[column + 1], vs[row + 1]))
            }
        }
        return out
    }

    /// A fan from the centre over the swept share, each step's outer point on the rectangle's edge — so a full turn
    /// covers the whole rectangle, corners and all, and a texture maps across it unchanged.
    private func radial(origin: SIMD2<Float>, size: SIMD2<Float>, amount: Float, start: Float,
                        clockwise: Bool) -> [Corner] {
        let a = min(max(amount, 0), 1)
        guard a > 0 else { return [] }
        let centre = origin + size / 2
        let half = size / 2
        // Screen y runs down, so "up" is −y; clockwise on screen is a falling angle in these terms.
        func edge(_ angle: Float) -> SIMD2<Float> {
            let d = SIMD2(cos(angle), -sin(angle))
            let k = min(abs(d.x) > 1e-6 ? 1 / abs(d.x) : .infinity, abs(d.y) > 1e-6 ? 1 / abs(d.y) : .infinity)
            return d * k
        }
        func corner(_ unit: SIMD2<Float>) -> Corner { Corner(centre + unit * half, (unit + 1) / 2) }
        let sweep = 2 * Float.pi * a * (clockwise ? -1 : 1)
        // Fine enough that each wedge stays inside one side of the rectangle, as the corners need.
        let steps = max(4, Int((abs(sweep) / (.pi / 16)).rounded(.up)))
        var out: [Corner] = []
        let middle = Corner(centre, SIMD2(0.5, 0.5))
        for k in 0..<steps {
            let a0 = start + sweep * Float(k) / Float(steps)
            let a1 = start + sweep * Float(k + 1) / Float(steps)
            let p0 = edge(a0), p1 = edge(a1)
            // A wedge that spans a corner of the rectangle goes round it, so the fan fills the corner square.
            let corners = Self.cornersBetween(a0, a1)
            var previous = p0
            for c in corners + [p1] {
                out += [middle, corner(previous), corner(c)]
                previous = c
            }
        }
        return out
    }

    /// The rectangle's corners (as unit offsets) a sweep from `a0` to `a1` passes, in the order it passes them.
    private static func cornersBetween(_ a0: Float, _ a1: Float) -> [SIMD2<Float>] {
        let quarter = Float.pi / 2
        var out: [SIMD2<Float>] = []
        let lo = min(a0, a1), hi = max(a0, a1)
        var k = (lo / quarter - 0.5).rounded(.up)
        while (k + 0.5) * quarter < hi {
            let angle = (k + 0.5) * quarter
            if angle > lo { out.append(SIMD2(cos(angle) < 0 ? -1 : 1, -sin(angle) < 0 ? -1 : 1)) }
            k += 1
        }
        return a1 >= a0 ? out : out.reversed()
    }

    /// Two triangles over an axis-aligned rectangle, `uv0` at its top-left and `uv1` at its bottom-right.
    static func quad(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ uv0: SIMD2<Float>, _ uv1: SIMD2<Float>) -> [Corner] {
        let a = Corner(p0, uv0), b = Corner(SIMD2(p1.x, p0.y), SIMD2(uv1.x, uv0.y))
        let c = Corner(p1, uv1), d = Corner(SIMD2(p0.x, p1.y), SIMD2(uv0.x, uv1.y))
        return [a, b, c, a, c, d]
    }

    /// **Triangles cut to a rectangle** — each one clipped against its four sides, the texture coordinates carried
    /// along the cut edges, what is left fanned back into triangles. A triangle wholly inside comes back as it was.
    public static func clip(_ triangles: [Corner], to origin: SIMD2<Float>, size: SIMD2<Float>) -> [Corner] {
        let lo = origin, hi = origin + size
        var out: [Corner] = []
        out.reserveCapacity(triangles.count)
        var index = 0
        while index + 2 < triangles.count {
            let tri = Array(triangles[index..<index + 3])
            index += 3
            if tri.allSatisfy({ $0.position.x >= lo.x && $0.position.x <= hi.x && $0.position.y >= lo.y && $0.position.y <= hi.y }) {
                out += tri
                continue
            }
            var polygon = tri
            for (axis, bound, keepsBelow) in [(0, lo.x, false), (0, hi.x, true), (1, lo.y, false), (1, hi.y, true)] {
                guard !polygon.isEmpty else { break }
                var next: [Corner] = []
                for k in 0..<polygon.count {
                    let a = polygon[k], b = polygon[(k + 1) % polygon.count]
                    let av = a.position[axis], bv = b.position[axis]
                    let aIn = keepsBelow ? av <= bound : av >= bound
                    let bIn = keepsBelow ? bv <= bound : bv >= bound
                    if aIn { next.append(a) }
                    if aIn != bIn {
                        let t = (bound - av) / (bv - av)
                        next.append(Corner(a.position + (b.position - a.position) * t, a.uv + (b.uv - a.uv) * t))
                    }
                }
                polygon = next
            }
            guard polygon.count >= 3 else { continue }
            for k in 1..<(polygon.count - 1) { out += [polygon[0], polygon[k], polygon[k + 1]] }
        }
        return out
    }
}
