import Foundation
import ReaderCore

/// Encodes a `ProcessedBook` as JSON compressed with LZFSE (Apple-only; the watch decodes with the same API).
enum BookCodec {
    enum CodecError: Error { case decompressionFailed }

    static func encode(_ book: ProcessedBook) throws -> Data {
        let json = try JSONEncoder().encode(book)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) throws -> ProcessedBook {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else {
            throw CodecError.decompressionFailed
        }
        return try JSONDecoder().decode(ProcessedBook.self, from: json)
    }
}
