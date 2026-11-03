import Compression
import Foundation
import zlib

/// Minimal gzip (RFC 1952) encoder built on the system Compression framework.
/// Compression's COMPRESSION_ZLIB produces a raw DEFLATE stream; gzip is that
/// stream wrapped in a 10-byte header and a CRC32 + size trailer.
enum Gzip {
    static func compress(_ input: Data) -> Data {
        // header: magic, deflate method, no flags, no mtime, no extra flags, unknown OS
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        if input.isEmpty {
            out.append(contentsOf: [0x03, 0x00])  // empty final DEFLATE block
        } else {
            out.append(deflate(input))
        }
        withUnsafeBytes(of: crc32(input).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: input.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    private static func deflate(_ input: Data) -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            assertionFailure("compression_stream_init failed")
            return Data()
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data(capacity: input.count / 4 + 64)
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR {
                    assertionFailure("deflate failed")
                    break
                }
            }
        }
        return output
    }

    /// zlib's CRC-32 (hardware-accelerated); a byte loop in Swift took
    /// seconds per batch in debug builds.
    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, base, uInt(raw.count)))
        }
    }
}
