import Compression
import Foundation

/// Reads files out of a zip (sm64ex's resource pack, base.zip): stored or deflated entries, no zip64
struct ZipArchive {
    private let data: Data
    private var entries: [String: (method: UInt16, compressed: Int, size: Int, header: Int)] = [:]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 22 else { return nil }
        self.data = data
        // The end of central directory record, within the last 64 KB (its comment)
        var end = data.count - 22
        let lowest = max(0, data.count - 65_557)
        while end >= lowest, Self.u32(data, end) != 0x0605_4b50 { end -= 1 }
        guard end >= lowest else { return nil }
        let count = Int(Self.u16(data, end + 10))
        var at = Int(Self.u32(data, end + 16))
        for _ in 0..<count {
            guard at + 46 <= data.count, Self.u32(data, at) == 0x0201_4b50 else { return nil }
            let nameLength = Int(Self.u16(data, at + 28))
            let skip = nameLength + Int(Self.u16(data, at + 30)) + Int(Self.u16(data, at + 32))
            guard at + 46 + nameLength <= data.count else { return nil }
            let name = String(decoding: data[data.startIndex + at + 46 ..< data.startIndex + at + 46 + nameLength],
                              as: UTF8.self)
            entries[name] = (Self.u16(data, at + 10), Int(Self.u32(data, at + 20)), Int(Self.u32(data, at + 24)),
                             Int(Self.u32(data, at + 42)))
            at += 46 + skip
        }
    }

    func read(_ name: String) -> Data? {
        guard let entry = entries[name], entry.header + 30 <= data.count,
              Self.u32(data, entry.header) == 0x0403_4b50 else { return nil }
        let start = entry.header + 30 + Int(Self.u16(data, entry.header + 26)) + Int(Self.u16(data, entry.header + 28))
        guard start + entry.compressed <= data.count else { return nil }
        let bytes = data[data.startIndex + start ..< data.startIndex + start + entry.compressed]
        switch entry.method {
        case 0: return Data(bytes)
        case 8:  // (COMPRESSION_ZLIB is raw deflate, as zip has it)
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                bytes.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, entry.compressed,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? out : nil
        default: return nil
        }
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[d.startIndex + at]) | UInt16(d[d.startIndex + at + 1]) << 8
    }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16
    }
}
