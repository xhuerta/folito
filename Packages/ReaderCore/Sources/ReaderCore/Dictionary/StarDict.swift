import Foundation
import ZIPFoundation

/// Errors of the dictionary conversion pipeline (iPhone side).
public enum DictionaryImportError: Error, Equatable, Sendable {
    /// The download is not a ZIP, or holds no StarDict dictionary (.ifo + .idx + .dict[.dz]).
    case notAStarDict
    /// A StarDict file contradicts its .ifo, or a definition points outside the .dict data.
    case corrupt(String)
    /// A feature of the StarDict format this converter does not read (e.g. 64-bit offsets with no .dict).
    case unsupported(String)
    /// The downloaded file's size or checksum is not the published one.
    case checksumMismatch
    /// The converted file is not a dictionary this app can read.
    case invalidCompactFile
}

/// The `.ifo` file of a StarDict dictionary (`key=value` lines after a fixed first line).
public struct StarDictInfo: Equatable, Sendable {
    public var bookName: String
    public var wordCount: Int
    public var synWordCount: Int
    public var idxFileSize: Int
    /// 32 (default) or 64.
    public var idxOffsetBits: Int
    /// `sametypesequence` ("h" = HTML, "m" = plain text, ...); empty when every record carries its own types.
    public var sameTypeSequence: String
    public var website: String?
    public var date: String?
    public var description: String?

    public static func parse(_ text: String) throws -> StarDictInfo {
        var lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("StarDict's dict ifo file") else {
            throw DictionaryImportError.notAStarDict
        }
        lines.removeFirst()
        var map: [String: String] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            map[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
        }
        guard let words = map["wordcount"].flatMap({ Int($0) }), words >= 0,
              let idxSize = map["idxfilesize"].flatMap({ Int($0) }), idxSize >= 0 else {
            throw DictionaryImportError.corrupt("ifo")
        }
        let bits = map["idxoffsetbits"].flatMap { Int($0) } ?? 32
        guard bits == 32 || bits == 64 else { throw DictionaryImportError.unsupported("idxoffsetbits=\(bits)") }
        return StarDictInfo(bookName: map["bookname"] ?? "", wordCount: words,
                            synWordCount: map["synwordcount"].flatMap { Int($0) } ?? 0,
                            idxFileSize: idxSize, idxOffsetBits: bits,
                            sameTypeSequence: map["sametypesequence"] ?? "",
                            website: map["website"], date: map["date"], description: map["description"])
    }
}

/// Parsers for the binary StarDict index files. Both are sequences of NUL-terminated UTF-8 words followed
/// by big-endian integers.
public enum StarDictIndex {
    public struct Item: Equatable, Sendable {
        public var word: String
        public var offset: UInt64
        public var size: UInt32
    }

    /// `.idx`: word, offset (32 or 64 bits), size (32 bits).
    public static func parseIdx(_ data: Data, offsetBits: Int = 32) throws -> [Item] {
        var items: [Item] = []
        let offsetBytes = offsetBits == 64 ? 8 : 4
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                guard let nul = (i..<b.count).first(where: { b[$0] == 0 }) else { throw DictionaryImportError.corrupt("idx") }
                guard nul + 1 + offsetBytes + 4 <= b.count else { throw DictionaryImportError.corrupt("idx") }
                let word = String(decoding: UnsafeBufferPointer(rebasing: b[i..<nul]), as: UTF8.self)
                var p = nul + 1
                var offset: UInt64 = 0
                for _ in 0..<offsetBytes { offset = offset << 8 | UInt64(b[p]); p += 1 }
                var size: UInt32 = 0
                for _ in 0..<4 { size = size << 8 | UInt32(b[p]); p += 1 }
                items.append(Item(word: word, offset: offset, size: size))
                i = p
            }
        }
        return items
    }

    /// `.syn`: word, index into the `.idx` items (32 bits). Synonyms and inflected forms.
    public static func parseSyn(_ data: Data) throws -> [(word: String, index: Int)] {
        var items: [(word: String, index: Int)] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                guard let nul = (i..<b.count).first(where: { b[$0] == 0 }), nul + 5 <= b.count else {
                    throw DictionaryImportError.corrupt("syn")
                }
                let word = String(decoding: UnsafeBufferPointer(rebasing: b[i..<nul]), as: UTF8.self)
                var index: UInt32 = 0
                for p in (nul + 1)...(nul + 4) { index = index << 8 | UInt32(b[p]) }
                items.append((word, Int(index)))
                i = nul + 5
            }
        }
        return items
    }
}

/// gzip (RFC 1952) reader for `.dict.dz` files. dictzip is plain gzip with an extra header field, so the
/// whole file inflates as one deflate stream; it is streamed to a file to keep memory flat.
public enum Gzip {
    /// Length of the gzip header at the start of `data` (the raw deflate stream follows it).
    static func headerLength(_ data: Data) throws -> Int {
        // dictzip's FEXTRA holds a chunk table: several KB for large dictionaries (up to 64 KiB).
        let b = [UInt8](data.prefix(1 << 17))
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw DictionaryImportError.corrupt("gzip header") }
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 {                        // FEXTRA (dictzip chunk table)
            guard p + 2 <= b.count else { throw DictionaryImportError.corrupt("gzip header") }
            p += 2 + (Int(b[p]) | (Int(b[p + 1]) << 8))
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT: NUL-terminated
            while p < b.count, b[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 }                // FHCRC
        guard p < b.count else { throw DictionaryImportError.corrupt("gzip header") }
        return p
    }

    /// Inflates the gzip file at `source` into `destination` and checks the trailer (CRC-32 and size).
    public static func decompress(_ source: URL, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let total = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let header = try headerLength(handle.readData(ofLength: 1 << 17))
        guard total >= Int64(header + 8) else { throw DictionaryImportError.corrupt("gzip size") }
        try handle.seek(toOffset: UInt64(total - 8))
        let trailer = [UInt8](handle.readData(ofLength: 8))
        let expectedCRC = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let expectedSize = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var written: UInt64 = 0
        let deflated = total - Int64(header) - 8
        do {
            let crc = try Data.decompress(size: deflated, bufferSize: 64 * 1024, skipCRC32: false, provider: { position, size in
                try handle.seek(toOffset: UInt64(Int64(header) + position))
                return handle.readData(ofLength: size)
            }, consumer: { chunk in
                written += UInt64(chunk.count)
                out.write(chunk)
            })
            guard crc == expectedCRC, UInt32(truncatingIfNeeded: written) == expectedSize else {
                throw DictionaryImportError.corrupt("gzip checksum")
            }
        } catch let e as DictionaryImportError {
            throw e
        } catch {
            throw DictionaryImportError.corrupt("gzip data")
        }
    }
}
