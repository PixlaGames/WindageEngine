import Foundation

/// Reads one file out of a `.usdz` package.
///
/// **A `.usdz` is a zip that never compresses** — the format requires every entry to be stored, aligned,
/// so a USD reader can map it in place. So an entry is a byte range of the file, found through the zip's
/// central directory, and nothing needs decompressing. A compressed entry is not a valid package and is
/// refused rather than read wrong.
///
/// Used by ``TextureStore`` for a texture packed inside a `.usdz`: Model I/O names it
/// `Prop.usdz[textures/x.png]` while its URL is the package itself (see `MDLMaterialProperty.textureSource`).
nonisolated enum USDZArchive {
    enum ReadError: Error, CustomStringConvertible {
        case notAZip
        case missing(String)
        case compressed(String)

        var description: String {
            switch self {
            case .notAZip: "not a zip package"
            case .missing(let name): "no entry named \(name) in the package"
            case .compressed(let name): "\(name) is compressed, which a .usdz may not be"
            }
        }
    }

    /// The bytes of the entry named `name` (its path inside the package).
    static func entry(_ name: String, in url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        // The end-of-central-directory record is the last thing in the file, followed by a comment of at most
        // 64 KB, so it is searched for backwards from the end.
        let minimum = 22
        guard data.count >= minimum else { throw ReadError.notAZip }
        var end = -1
        var i = data.count - minimum
        let floor = max(0, data.count - minimum - 0xFFFF)
        while i >= floor {
            if data.u32(i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ReadError.notAZip }

        let count = Int(data.u16(end + 10))
        var at = Int(data.u32(end + 16))
        for _ in 0..<count {
            guard at + 46 <= data.count, data.u32(at) == 0x0201_4B50 else { throw ReadError.notAZip }
            let method = data.u16(at + 10)
            let size = Int(data.u32(at + 20))
            let nameLength = Int(data.u16(at + 28))
            let extraLength = Int(data.u16(at + 30))
            let commentLength = Int(data.u16(at + 32))
            let localHeader = Int(data.u32(at + 42))
            // **The whole record must be in the file before any of it is read** — a damaged package from someone's
            // pack is refused, never read past its end, which would stop the app rather than the texture.
            guard at + 46 + nameLength + extraLength + commentLength <= data.count else { throw ReadError.notAZip }
            let entryName = String(decoding: data[(data.startIndex + at + 46)..<(data.startIndex + at + 46 + nameLength)],
                                   as: UTF8.self)
            if entryName == name {
                guard method == 0 else { throw ReadError.compressed(name) }
                // The local header has its own name and extra-field lengths; the extra field is where the
                // alignment padding goes, so it is usually not the central directory's.
                guard localHeader + 30 <= data.count, data.u32(localHeader) == 0x0403_4B50 else { throw ReadError.notAZip }
                let start = localHeader + 30 + Int(data.u16(localHeader + 26)) + Int(data.u16(localHeader + 28))
                guard start + size <= data.count else { throw ReadError.notAZip }
                return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + size))
            }
            at += 46 + nameLength + extraLength + commentLength
        }
        throw ReadError.missing(name)
    }
}

private nonisolated extension Data {
    /// Little-endian, as every zip field is.
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
