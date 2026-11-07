import Foundation

#if canImport(Compression)
import Compression
#endif

/// gzip (RFC 1952) around a raw deflate stream. On Apple platforms the deflate comes from the system's Compression
/// framework (`COMPRESSION_ZLIB` is raw deflate, level 5); elsewhere (the Linux test runs) the stream is made of
/// stored blocks, valid gzip that any server inflates.
enum Gzip {
    static func compress(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflate(data))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    static func deflate(_ data: Data) -> Data {
        #if canImport(Compression)
        if !data.isEmpty {
            let capacity = data.count + data.count / 10 + 64
            var buffer = [UInt8](repeating: 0, count: capacity)
            let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(&buffer, capacity, base, data.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 { return Data(buffer[0..<n]) }
        }
        #endif
        return stored(data)
    }

    /// Deflate stored blocks (BTYPE 00), ≤ 65 535 bytes each.
    static func stored(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        repeat {
            let n = min(65_535, bytes.count - i)
            let last: UInt8 = i + n >= bytes.count ? 1 : 0
            out.append(last)
            out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        } while i < bytes.count
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
