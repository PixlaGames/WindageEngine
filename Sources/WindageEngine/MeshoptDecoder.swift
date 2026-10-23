//
//  MeshoptDecoder.swift
//  WindageEngine
//

import Foundation

/// Decodes meshopt-compressed glTF buffer views — `EXT_meshopt_compression` and its Khronos successor
/// `KHR_meshopt_compression` — in Swift.
///
/// **Written from the two extension specifications and checked line by line against the reference
/// decoder** (meshoptimizer's `vertexcodec.cpp`, `indexcodec.cpp` and `vertexfilter.cpp`, MIT), which
/// settles the two points the prose leaves to interpretation: a literal byte plane holds exactly one
/// byte per element, and a 4-byte XOR channel is rotated by `32 - r` before it is applied. The tests
/// hold it to files written by `gltfpack`, meshoptimizer's own encoder.
///
/// Every read is bounds-checked: a damaged file is refused, never read past.
nonisolated enum MeshoptDecoder {

    enum Mode: String { case attributes = "ATTRIBUTES", triangles = "TRIANGLES", indices = "INDICES" }
    enum Filter: String { case none = "NONE", octahedral = "OCTAHEDRAL", quaternion = "QUATERNION",
                          exponential = "EXPONENTIAL", color = "COLOR" }

    struct Invalid: Error {}

    /// A compressed buffer view, decoded to `count × stride` bytes laid out as the parent view says.
    static func decode(_ source: Data, count: Int, stride: Int, mode: Mode, filter: Filter) throws -> Data {
        let bytes = [UInt8](source)
        var out: [UInt8]
        switch mode {
        case .attributes:
            guard stride > 0, stride <= 256, stride % 4 == 0 else { throw Invalid() }
            out = try vertexBuffer(bytes, count: count, stride: stride)
            try apply(filter, to: &out, count: count, stride: stride)
        case .triangles:
            guard stride == 2 || stride == 4, count % 3 == 0, filter == .none else { throw Invalid() }
            out = pack(try triangles(bytes, count: count), stride: stride)
        case .indices:
            guard stride == 2 || stride == 4, filter == .none else { throw Invalid() }
            out = pack(try sequence(bytes, count: count), stride: stride)
        }
        return Data(out)
    }

    private static func pack(_ indices: [UInt32], stride: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: indices.count * stride)
        for (i, v) in indices.enumerated() {
            out[i * stride] = UInt8(truncatingIfNeeded: v)
            out[i * stride + 1] = UInt8(truncatingIfNeeded: v >> 8)
            if stride == 4 {
                out[i * stride + 2] = UInt8(truncatingIfNeeded: v >> 16)
                out[i * stride + 3] = UInt8(truncatingIfNeeded: v >> 24)
            }
        }
        return out
    }

    // MARK: Mode 0: attributes

    private static func vertexBuffer(_ data: [UInt8], count: Int, stride: Int) throws -> [UInt8] {
        guard !data.isEmpty, data[0] & 0xF0 == 0xA0 else { throw Invalid() }
        let version = Int(data[0] & 0x0F)
        guard version <= 1 else { throw Invalid() }

        let tailSize = stride + (version == 0 ? 0 : stride / 4)
        let tailPadded = max(tailSize, version == 0 ? 32 : 24)
        guard data.count - 1 >= tailPadded else { throw Invalid() }
        let tail = data.count - tailSize
        var last = Array(data[tail..<tail + stride])
        let channels = version == 0 ? [] : Array(data[(tail + stride)..<(tail + tailSize)])
        let end = data.count - tailPadded   // where the attribute blocks must stop

        let blockMax = min((8192 / stride) & ~15, 256)
        var out = [UInt8](repeating: 0, count: count * stride)
        var at = 1
        var start = 0
        while start < count {
            let n = min(blockMax, count - start)
            try vertexBlock(data, at: &at, end: end, into: &out, first: start, count: n, stride: stride,
                            last: &last, channels: channels, version: version)
            start += n
        }
        guard at == end else { throw Invalid() }
        return out
    }

    private static func vertexBlock(_ data: [UInt8], at: inout Int, end: Int, into out: inout [UInt8],
                                    first: Int, count: Int, stride: Int, last: inout [UInt8],
                                    channels: [UInt8], version: Int) throws {
        let aligned = (count + 15) & ~15
        let controlSize = version == 0 ? 0 : stride / 4
        guard end - at >= controlSize else { throw Invalid() }
        let control = Array(data[at..<at + controlSize])
        at += controlSize

        for k in Swift.stride(from: 0, to: stride, by: 4) {
            let controlByte = version == 0 ? 0 : control[k / 4]
            // The four byte planes of this channel: one delta per element, byte by byte.
            var planes = [[UInt8]](repeating: [], count: 4)
            for j in 0..<4 {
                let ctrl = Int(controlByte >> (j * 2)) & 3
                switch ctrl {
                case 3:   // literal: one byte per element, no header
                    guard end - at >= count else { throw Invalid() }
                    planes[j] = Array(data[at..<at + count])
                    at += count
                case 2:   // every delta zero
                    planes[j] = [UInt8](repeating: 0, count: count)
                default:
                    let bits = version == 0 ? [0, 2, 4, 8] : (ctrl == 0 ? [0, 1, 2, 4] : [1, 2, 4, 8])
                    planes[j] = try bytes(data, at: &at, end: end, count: aligned, bits: bits)
                }
            }

            let channel = version == 0 ? 0 : Int(channels[k / 4])
            switch channel & 3 {
            case 0:   // byte deltas, zigzagged
                for j in 0..<4 {
                    var p = last[k + j]
                    for i in 0..<count {
                        let d = planes[j][i]
                        p = p &+ ((d & 1) != 0 ? ~(d >> 1) : (d >> 1))
                        out[(first + i) * stride + k + j] = p
                    }
                }
            case 1:   // 16-bit deltas, zigzagged, little-endian
                for h in [0, 2] {
                    var p = UInt16(last[k + h]) | UInt16(last[k + h + 1]) << 8
                    for i in 0..<count {
                        let d = UInt16(planes[h][i]) | UInt16(planes[h + 1][i]) << 8
                        p = p &+ ((d & 1) != 0 ? ~(d >> 1) : (d >> 1))
                        out[(first + i) * stride + k + h] = UInt8(truncatingIfNeeded: p)
                        out[(first + i) * stride + k + h + 1] = UInt8(truncatingIfNeeded: p >> 8)
                    }
                }
            case 2:   // 32-bit XOR deltas, rotated
                let r = UInt32((32 - (channel >> 4)) & 31)
                var p = (0..<4).reduce(UInt32(0)) { $0 | UInt32(last[k + $1]) << (8 * UInt32($1)) }
                for i in 0..<count {
                    let v = (0..<4).reduce(UInt32(0)) { $0 | UInt32(planes[$1][i]) << (8 * UInt32($1)) }
                    p = ((v << r) | (v >> ((32 - r) & 31))) ^ p
                    for j in 0..<4 { out[(first + i) * stride + k + j] = UInt8(truncatingIfNeeded: p >> (8 * UInt32(j))) }
                }
            default:
                throw Invalid()
            }
        }
        let lastElement = (first + count - 1) * stride
        last = Array(out[lastElement..<lastElement + stride])
    }

    /// One byte plane: two header bits per group of sixteen, then each group's deltas.
    private static func bytes(_ data: [UInt8], at: inout Int, end: Int, count: Int, bits: [Int]) throws -> [UInt8] {
        let groups = count / 16
        let headerSize = (groups + 3) / 4
        guard end - at >= headerSize else { throw Invalid() }
        let header = at
        at += headerSize
        var out = [UInt8](repeating: 0, count: count)
        for g in 0..<groups {
            let width = bits[Int(data[header + g / 4] >> ((g % 4) * 2)) & 3]
            try group(data, at: &at, end: end, into: &out, offset: g * 16, bits: width)
        }
        return out
    }

    /// Sixteen deltas at a bit width, with an all-ones value meaning "the real byte follows".
    private static func group(_ data: [UInt8], at: inout Int, end: Int, into out: inout [UInt8],
                              offset: Int, bits: Int) throws {
        switch bits {
        case 0:
            return
        case 8:
            guard end - at >= 16 else { throw Invalid() }
            for i in 0..<16 { out[offset + i] = data[at + i] }
            at += 16
        default:
            let packed = 16 * bits / 8
            guard end - at >= packed else { throw Invalid() }
            var extra = at + packed
            let sentinel = UInt8((1 << bits) - 1)
            for i in 0..<16 {
                let byte = data[at + i * bits / 8]
                // 1-bit values run from the least significant bit; 2- and 4-bit from the most.
                let shift = bits == 1 ? i % 8 : 8 - bits - (i * bits) % 8
                let value = (byte >> UInt8(shift)) & sentinel
                if value == sentinel {
                    guard extra < end else { throw Invalid() }
                    out[offset + i] = data[extra]
                    extra += 1
                } else {
                    out[offset + i] = value
                }
            }
            at = extra
        }
    }

    // MARK: Mode 1: triangles

    private static func triangles(_ data: [UInt8], count: Int) throws -> [UInt32] {
        guard data.count >= 1 + count / 3 + 16, data[0] & 0xF0 == 0xE0 else { throw Invalid() }
        let version = Int(data[0] & 0x0F)
        guard version <= 1 else { throw Invalid() }
        let fecMax = version >= 1 ? 13 : 15

        var edges = [(UInt32, UInt32)](repeating: (0, 0), count: 16), edgeAt = 0
        var vertices = [UInt32](repeating: 0, count: 16), vertexAt = 0
        func pushEdge(_ a: UInt32, _ b: UInt32) { edges[edgeAt] = (a, b); edgeAt = (edgeAt + 1) & 15 }
        func pushVertex(_ v: UInt32, _ cond: Bool = true) { vertices[vertexAt] = v; if cond { vertexAt = (vertexAt + 1) & 15 } }

        var next: UInt32 = 0, last: UInt32 = 0
        let codeEnd = 1 + count / 3
        var at = codeEnd
        let safeEnd = data.count - 16
        let aux = Array(data[safeEnd...])
        func index() throws -> UInt32 {
            let v = try varint(data, at: &at, end: safeEnd)
            last = last &+ ((v >> 1) ^ (0 &- (v & 1)))
            return last
        }

        var out: [UInt32] = []
        out.reserveCapacity(count)
        for code in data[1..<codeEnd] {
            if code < 0xF0 {
                let (a, b) = edges[(edgeAt - 1 - Int(code >> 4)) & 15]
                let fec = Int(code & 15)
                let c: UInt32
                if fec < fecMax {
                    if fec == 0 { c = next; next &+= 1 } else { c = vertices[(vertexAt - 1 - fec) & 15] }
                    pushVertex(c, fec == 0)
                } else {
                    guard at <= safeEnd else { throw Invalid() }
                    // 13 and 14 are one either side of the last index; 15 is a free-standing one.
                    if fec != 15 { last = last &+ UInt32(bitPattern: Int32(fec * 2 - 27)); c = last } else { c = try index() }
                    pushVertex(c)
                }
                pushEdge(c, b)
                pushEdge(a, c)
                out += [a, b, c]
            } else if code < 0xFE {
                let codeaux = aux[Int(code & 15)]
                let feb = Int(codeaux >> 4), fec = Int(codeaux & 15)
                let a = next; next &+= 1
                let b: UInt32 = feb == 0 ? next : vertices[(vertexAt - feb) & 15]
                if feb == 0 { next &+= 1 }
                let c: UInt32 = fec == 0 ? next : vertices[(vertexAt - fec) & 15]
                if fec == 0 { next &+= 1 }
                out += [a, b, c]
                pushVertex(a); pushVertex(b, feb == 0); pushVertex(c, fec == 0)
                pushEdge(b, a); pushEdge(c, b); pushEdge(a, c)
            } else {
                guard at < safeEnd else { throw Invalid() }
                let codeaux = data[at]; at += 1
                let fea = code == 0xFE ? 0 : 15, feb = Int(codeaux >> 4), fec = Int(codeaux & 15)
                if codeaux == 0 { next = 0 }
                var a: UInt32 = 0
                if fea == 0 { a = next; next &+= 1 }
                var b: UInt32 = 0
                if feb == 0 { b = next; next &+= 1 } else { b = vertices[(vertexAt - feb) & 15] }
                var c: UInt32 = 0
                if fec == 0 { c = next; next &+= 1 } else { c = vertices[(vertexAt - fec) & 15] }
                if fea == 15 { a = try index() }
                if feb == 15 { b = try index() }
                if fec == 15 { c = try index() }
                out += [a, b, c]
                pushVertex(a); pushVertex(b, feb == 0 || feb == 15); pushVertex(c, fec == 0 || fec == 15)
                pushEdge(b, a); pushEdge(c, b); pushEdge(a, c)
            }
        }
        guard at == safeEnd else { throw Invalid() }
        return out
    }

    // MARK: Mode 2: indices

    private static func sequence(_ data: [UInt8], count: Int) throws -> [UInt32] {
        guard data.count >= 1 + count + 4, data[0] & 0xF0 == 0xD0, data[0] & 0x0F <= 1 else { throw Invalid() }
        let safeEnd = data.count - 4
        var at = 1
        var last: [UInt32] = [0, 0]
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard at < safeEnd else { throw Invalid() }
            var v = try varint(data, at: &at, end: data.count)
            let baseline = Int(v & 1)
            v >>= 1
            last[baseline] = last[baseline] &+ ((v >> 1) ^ (0 &- (v & 1)))
            out.append(last[baseline])
        }
        guard at == safeEnd else { throw Invalid() }
        return out
    }

    /// Unsigned LEB128, up to five bytes.
    private static func varint(_ data: [UInt8], at: inout Int, end: Int) throws -> UInt32 {
        var result: UInt32 = 0, shift: UInt32 = 0
        for _ in 0..<5 {
            guard at < end else { throw Invalid() }
            let byte = data[at]; at += 1
            result |= UInt32(byte & 127) << shift
            if byte < 128 { return result }
            shift += 7
        }
        return result
    }

    // MARK: Filters

    private static func apply(_ filter: Filter, to data: inout [UInt8], count: Int, stride: Int) throws {
        switch filter {
        case .none:
            return
        case .octahedral:
            guard stride == 4 || stride == 8 else { throw Invalid() }
            let wide = stride == 8
            let maximum = Float(wide ? 32767 : 127)
            for i in 0..<count {
                let base = i * stride
                func get(_ c: Int) -> Float { wide ? Float(int16(data, base + c * 2)) : Float(Int8(bitPattern: data[base + c])) }
                func set(_ c: Int, _ v: Int) {
                    if wide { put16(&data, base + c * 2, UInt16(bitPattern: Int16(truncatingIfNeeded: v))) }
                    else { data[base + c] = UInt8(bitPattern: Int8(truncatingIfNeeded: v)) }
                }
                var x = get(0), y = get(1)
                let z = get(2) - abs(x) - abs(y)
                let t = z >= 0 ? 0 : z
                x += x >= 0 ? t : -t
                y += y >= 0 ? t : -t
                let s = maximum / (x * x + y * y + z * z).squareRoot()
                set(0, rounded(x * s)); set(1, rounded(y * s)); set(2, rounded(z * s))
            }
        case .quaternion:
            guard stride == 8 else { throw Invalid() }
            let scale = Float(32767) / Float(2).squareRoot()
            for i in 0..<count {
                let base = i * 8
                let w3 = int16(data, base + 6)
                let s = Float(Int32(w3) | 3)
                let x = Float(int16(data, base)), y = Float(int16(data, base + 2)), z = Float(int16(data, base + 4))
                let ww = s * s * 2 - x * x - y * y - z * z
                let w = (ww >= 0 ? ww : 0).squareRoot()
                let ss = scale / s
                let qc = Int(w3 & 3)
                let values = [rounded(x * ss), rounded(y * ss), rounded(z * ss), Int(w * ss + 0.5)]
                for (offset, value) in zip([1, 2, 3, 0], values) {
                    put16(&data, base + ((qc + offset) & 3) * 2, UInt16(bitPattern: Int16(truncatingIfNeeded: value)))
                }
            }
        case .exponential:
            guard stride % 4 == 0 else { throw Invalid() }
            for i in 0..<(count * stride / 4) {
                let o = i * 4
                let v = UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
                let m = Int32(bitPattern: v << 8) >> 8
                let e = Int32(bitPattern: v) >> 24
                let f = Float(sign: .plus, exponent: Int(e), significand: 1) * Float(m)
                let bits = f.bitPattern
                for j in 0..<4 { data[o + j] = UInt8(truncatingIfNeeded: bits >> (8 * UInt32(j))) }
            }
        case .color:
            guard stride == 4 || stride == 8 else { throw Invalid() }
            let wide = stride == 8
            let maximum = Float(wide ? 65535 : 255)
            for i in 0..<count {
                let base = i * stride
                func get(_ c: Int) -> Int { wide ? Int(uint16(data, base + c * 2)) : Int(data[base + c]) }
                func signed(_ c: Int) -> Int { wide ? Int(int16(data, base + c * 2)) : Int(Int8(bitPattern: data[base + c])) }
                func set(_ c: Int, _ v: Int) {
                    if wide { put16(&data, base + c * 2, UInt16(truncatingIfNeeded: v)) } else { data[base + c] = UInt8(truncatingIfNeeded: v) }
                }
                var scale = get(3)
                scale |= scale >> 1; scale |= scale >> 2; scale |= scale >> 4; scale |= scale >> 8
                guard scale > 0 else { continue }
                let y = get(0), co = signed(1), cg = signed(2)
                let r = y + co - cg, g = y + cg, b = y - co - cg
                let a = ((get(3) << 1) & scale) | (get(3) & 1)
                let ss = maximum / Float(scale)
                set(0, Int(Float(r) * ss + 0.5)); set(1, Int(Float(g) * ss + 0.5))
                set(2, Int(Float(b) * ss + 0.5)); set(3, Int(Float(a) * ss + 0.5))
            }
        }
    }

    /// Rounded half away from zero, as the reference decoder rounds.
    private static func rounded(_ v: Float) -> Int { Int(v + (v >= 0 ? 0.5 : -0.5)) }

    private static func uint16(_ d: [UInt8], _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private static func int16(_ d: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: uint16(d, o)) }
    private static func put16(_ d: inout [UInt8], _ o: Int, _ v: UInt16) {
        d[o] = UInt8(truncatingIfNeeded: v)
        d[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
}
