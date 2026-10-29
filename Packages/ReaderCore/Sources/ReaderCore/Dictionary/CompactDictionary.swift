import Foundation
import ZIPFoundation

/// Folito's on-watch dictionary format ("FOLIDIC1"): one file, read with small random-access reads so a
/// lookup never loads the dictionary into memory.
///
/// Layout (integers little-endian):
/// ```
/// "FOLIDIC1"
/// definition blocks      raw-deflate compressed; each holds whole encoded entries (~64 KiB uncompressed)
/// key buckets            sorted lookup keys, `bucketSize` per bucket, front-coded then raw-deflate
///                        compressed; each record is
///                        varint(shared prefix) varint(suffix length) suffix varint(block) varint(offset) varint(length)
/// block table            blockCount x (u64 file offset, u32 compressed size, u32 uncompressed size)
/// bucket table           bucketCount x (u64 file offset, u32 compressed size, u32 uncompressed size)
/// footer                 JSON `CompactDictionaryInfo`, u32 JSON length, "FOLIDIC1"
/// ```
/// A lookup binary-searches the buckets (inflating each probed bucket, ~2 KiB), scans one or two buckets
/// and inflates one definition block. Keys are `normalizedKey(_:)` of headwords and of their synonyms /
/// inflected forms; equal keys are kept (headwords first) so "Polish" and "polish" both come back.
public enum CompactDictionaryFormat {
    public static let magic = Array("FOLIDIC1".utf8)
    public static let version = 1
    public static let fileExtension = "folidict"
    static let bucketSize = 128
    static let maxKeyBytes = 200
    /// Records kept per key (headword hits first, then synonym hits).
    static let maxRefsPerKey = 4

    /// Lookup key: Unicode NFC, lower-cased, at most `maxKeyBytes` UTF-8 bytes.
    public static func normalizedKey(_ word: String) -> [UInt8] {
        let key = Array(word.precomposedStringWithCanonicalMapping.lowercased().utf8)
        return key.count > maxKeyBytes ? Array(key.prefix(maxKeyBytes)) : key
    }
}

/// Metadata stored in the footer of a compact dictionary, and shown in the app (credits).
public struct CompactDictionaryInfo: Codable, Equatable, Sendable {
    public var formatVersion: Int
    /// Catalog id ("readerdict-en").
    public var id: String
    public var name: String
    /// Primary language subtag of the headwords ("en").
    public var language: String
    /// Short attribution shown under every definition ("Wiktionary · reader.dict · CC BY-SA 4.0").
    public var source: String
    /// Where the definitions come from ("Wiktionary"); its contributors are the authors.
    public var dataSource: String
    /// Who compiled the downloaded file ("reader.dict").
    public var publisher: String
    public var license: String
    public var licenseURL: String
    /// Full credit line (authors, licence, changes made).
    public var attribution: String
    public var sourceURL: String
    /// Date or version of the source data, as published.
    public var sourceVersion: String
    public var headwordCount: Int
    public var keyCount: Int
    // Section offsets (filled in by the writer).
    public var blockCount: Int = 0
    public var bucketCount: Int = 0
    public var blockTableOffset: UInt64 = 0
    public var bucketTableOffset: UInt64 = 0

    public init(id: String, name: String, language: String, source: String, dataSource: String = "",
                publisher: String = "", license: String, licenseURL: String,
                attribution: String, sourceURL: String, sourceVersion: String,
                headwordCount: Int = 0, keyCount: Int = 0) {
        self.formatVersion = CompactDictionaryFormat.version
        self.id = id
        self.name = name
        self.language = language
        self.source = source
        self.dataSource = dataSource
        self.publisher = publisher
        self.license = license
        self.licenseURL = licenseURL
        self.attribution = attribution
        self.sourceURL = sourceURL
        self.sourceVersion = sourceVersion
        self.headwordCount = headwordCount
        self.keyCount = keyCount
    }
}

/// Where an encoded entry lives: block index, byte offset and length inside the inflated block.
public struct CompactEntryRef: Equatable, Hashable, Sendable {
    public var block: UInt32
    public var offset: UInt32
    public var length: UInt32
}

// MARK: - Binary helpers

enum Varint {
    static func append(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }

    static func read(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard p < b.count, shift < 64 else { throw DictionaryError.unreadable }
            let byte = b[p]; p += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }
}

enum LittleEndian {
    static func append<T: FixedWidthInteger>(_ value: T, to out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    static func read<T: FixedWidthInteger>(_ type: T.Type, _ b: [UInt8], at p: Int) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v |= T(b[p + i]) << (8 * i) }
        return v
    }
}

/// Compact binary encoding of a `DictionaryEntry` (strings are varint length + UTF-8). Language and
/// source are not stored per entry: they come from the dictionary's info.
enum EntryCodec {
    static func encode(_ e: DictionaryEntry) -> [UInt8] {
        var out: [UInt8] = []
        func str(_ s: String) { let u = Array(s.utf8); Varint.append(UInt64(u.count), to: &out); out += u }
        func count(_ n: Int) { Varint.append(UInt64(n), to: &out) }
        str(e.word)
        str(e.pronunciation ?? "")
        count(e.meanings.count)
        for m in e.meanings {
            str(m.partOfSpeech)
            count(m.senses.count)
            for s in m.senses {
                str(s.definition)
                count(s.examples.count); s.examples.forEach(str)
                count(s.subsenses.count); s.subsenses.forEach(str)
            }
        }
        return out
    }

    static func decode(_ bytes: ArraySlice<UInt8>, language: String, source: String) throws -> DictionaryEntry {
        let array = Array(bytes)
        return try array.withUnsafeBufferPointer { b in
            var p = 0
            func count() throws -> Int {
                let n = try Varint.read(b, &p)
                guard n <= UInt64(b.count) else { throw DictionaryError.unreadable }
                return Int(n)
            }
            func str() throws -> String {
                let n = try count()
                guard p + n <= b.count else { throw DictionaryError.unreadable }
                defer { p += n }
                return String(decoding: UnsafeBufferPointer(rebasing: b[p..<(p + n)]), as: UTF8.self)
            }
            let word = try str()
            let pron = try str()
            var meanings: [DictionaryMeaning] = []
            for _ in 0..<(try count()) {
                let pos = try str()
                var senses: [DictionarySense] = []
                for _ in 0..<(try count()) {
                    let def = try str()
                    var examples: [String] = []
                    for _ in 0..<(try count()) { examples.append(try str()) }
                    var subs: [String] = []
                    for _ in 0..<(try count()) { subs.append(try str()) }
                    senses.append(DictionarySense(definition: def, examples: examples, subsenses: subs))
                }
                meanings.append(DictionaryMeaning(partOfSpeech: pos, senses: senses))
            }
            return DictionaryEntry(word: word, language: language, pronunciation: pron.isEmpty ? nil : pron,
                                   meanings: meanings, source: source)
        }
    }
}

enum Deflate {
    /// ZIPFoundation's Linux inflater asks for full buffers past the end: clamp.
    private static func chunk(of data: Data, at position: Int64, size: Int) -> Data {
        let start = min(Int(position), data.count)
        return data.subdata(in: start..<min(start + size, data.count))
    }

    static func compress(_ bytes: [UInt8]) throws -> Data {
        let data = Data(bytes)
        var out = Data()
        _ = try Data.compress(size: Int64(data.count), bufferSize: max(data.count, 1), provider: { pos, size in
            chunk(of: data, at: pos, size: size)
        }, consumer: { out.append($0) })
        return out
    }

    static func decompress(_ data: Data, rawSize: Int) throws -> [UInt8] {
        var out = Data()
        out.reserveCapacity(rawSize)
        _ = try Data.decompress(size: Int64(data.count), bufferSize: max(rawSize, 1024), skipCRC32: true, provider: { pos, size in
            chunk(of: data, at: pos, size: size)
        }, consumer: { out.append($0) })
        guard out.count == rawSize else { throw DictionaryError.unreadable }
        return [UInt8](out)
    }
}

// MARK: - Writer

/// Builds a compact dictionary file. Entries are streamed to disk as blocks fill up; keys are collected
/// in one contiguous byte buffer (not one `String` each) and sorted at `finish`.
public final class CompactDictionaryWriter {
    private struct KeyRecord {
        var start: UInt32
        var length: UInt8
        var priority: UInt8
        var ref: CompactEntryRef
    }

    private let out: FileHandle
    private let url: URL
    private let blockSize: Int
    private var position: UInt64 = 0
    private var block: [UInt8] = []
    private var blockTable: [(offset: UInt64, compressed: UInt32, raw: UInt32)] = []
    private var keyBytes: [UInt8] = []
    private var keys: [KeyRecord] = []
    public private(set) var entryCount = 0

    public init(url: URL, blockSize: Int = 64 * 1024) throws {
        self.url = url
        self.blockSize = blockSize
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        out = try FileHandle(forWritingTo: url)
        write(CompactDictionaryFormat.magic)
    }

    deinit { try? out.close() }

    private func write(_ bytes: [UInt8]) {
        out.write(Data(bytes))
        position += UInt64(bytes.count)
    }

    /// Appends an entry and returns where it is stored.
    public func add(_ entry: DictionaryEntry) throws -> CompactEntryRef {
        let encoded = EntryCodec.encode(entry)
        if !block.isEmpty, block.count + encoded.count > blockSize { try flushBlock() }
        let ref = CompactEntryRef(block: UInt32(blockTable.count), offset: UInt32(block.count), length: UInt32(encoded.count))
        block += encoded
        entryCount += 1
        return ref
    }

    /// Adds a lookup key for an entry. `isHeadword == false` for synonyms / inflected forms, which rank
    /// after headwords with the same key.
    public func addKey(_ word: String, ref: CompactEntryRef, isHeadword: Bool = true) {
        let key = CompactDictionaryFormat.normalizedKey(word)
        guard !key.isEmpty else { return }
        keys.append(KeyRecord(start: UInt32(keyBytes.count), length: UInt8(key.count),
                              priority: isHeadword ? 0 : 1, ref: ref))
        keyBytes += key
    }

    private func flushBlock() throws {
        guard !block.isEmpty else { return }
        let compressed = try Deflate.compress(block)
        blockTable.append((position, UInt32(compressed.count), UInt32(block.count)))
        out.write(compressed)
        position += UInt64(compressed.count)
        block = []
    }

    /// Writes keys, tables and footer. `info`'s counts and offsets are filled in here.
    @discardableResult
    public func finish(info: CompactDictionaryInfo) throws -> CompactDictionaryInfo {
        try flushBlock()
        let sorted = sortedKeys()

        var bucketTable: [(offset: UInt64, compressed: UInt32, raw: UInt32)] = []
        var bucket: [UInt8] = []
        func flushBucket() throws {
            guard !bucket.isEmpty else { return }
            let compressed = try Deflate.compress(bucket)
            bucketTable.append((position, UInt32(compressed.count), UInt32(bucket.count)))
            write([UInt8](compressed))
            bucket = []
        }
        var previous: ArraySlice<UInt8> = []
        var keyCount = 0
        var inBucket = 0
        var refsForKey = 0
        var lastRef: CompactEntryRef?
        for record in sorted {
            let key = keyBytes[Int(record.start)..<(Int(record.start) + Int(record.length))]
            if key == previous {
                // Same key: keep a few distinct entries only.
                if record.ref == lastRef || refsForKey >= CompactDictionaryFormat.maxRefsPerKey { continue }
                refsForKey += 1
            } else {
                refsForKey = 1
            }
            if inBucket == CompactDictionaryFormat.bucketSize {
                try flushBucket(); inBucket = 0
            }
            if inBucket == 0 {
                previous = []
            }
            let shared = zip(previous, key).prefix(while: { $0 == $1 }).count
            Varint.append(UInt64(shared), to: &bucket)
            Varint.append(UInt64(key.count - shared), to: &bucket)
            bucket += key.dropFirst(shared)
            Varint.append(UInt64(record.ref.block), to: &bucket)
            Varint.append(UInt64(record.ref.offset), to: &bucket)
            Varint.append(UInt64(record.ref.length), to: &bucket)
            previous = key
            lastRef = record.ref
            inBucket += 1
            keyCount += 1
        }
        try flushBucket()

        var info = info
        info.formatVersion = CompactDictionaryFormat.version
        info.keyCount = keyCount
        info.blockCount = blockTable.count
        info.bucketCount = bucketTable.count
        info.blockTableOffset = position
        var table: [UInt8] = []
        for b in blockTable {
            LittleEndian.append(b.offset, to: &table)
            LittleEndian.append(b.compressed, to: &table)
            LittleEndian.append(b.raw, to: &table)
        }
        write(table)
        info.bucketTableOffset = position
        table = []
        for b in bucketTable {
            LittleEndian.append(b.offset, to: &table)
            LittleEndian.append(b.compressed, to: &table)
            LittleEndian.append(b.raw, to: &table)
        }
        write(table)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = [UInt8](try encoder.encode(info))
        var footer = json
        LittleEndian.append(UInt32(json.count), to: &footer)
        footer += CompactDictionaryFormat.magic
        write(footer)
        try out.synchronize()
        try out.close()
        keys = []; keyBytes = []
        return info
    }

    private func sortedKeys() -> [KeyRecord] {
        keyBytes.withUnsafeBufferPointer { bytes in
            keys.sorted { a, b in
                let la = Int(a.length), lb = Int(b.length)
                let c = memcmp(bytes.baseAddress! + Int(a.start), bytes.baseAddress! + Int(b.start), min(la, lb))
                if c != 0 { return c < 0 }
                if la != lb { return la < lb }
                if a.priority != b.priority { return a.priority < b.priority }
                if a.ref.block != b.ref.block { return a.ref.block < b.ref.block }
                return a.ref.offset < b.ref.offset
            }
        }
    }
}

// MARK: - Reader

/// Read-only access to a compact dictionary file. Thread-safe; keeps only the info, the file handle and
/// the last inflated block in memory.
public final class CompactDictionary: @unchecked Sendable {
    public let info: CompactDictionaryInfo
    public let url: URL
    private let handle: FileHandle
    private let fileSize: UInt64
    private let lock = NSLock()
    private var cachedBlock: (index: UInt32, bytes: [UInt8])?

    public init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DictionaryError.unreadable
        }
        do {
            fileSize = try handle.seekToEnd()
            let tailLength = 12
            guard fileSize > UInt64(CompactDictionaryFormat.magic.count + tailLength) else { throw DictionaryError.unreadable }
            try handle.seek(toOffset: 0)
            guard [UInt8](handle.readData(ofLength: 8)) == CompactDictionaryFormat.magic else { throw DictionaryError.unreadable }
            try handle.seek(toOffset: fileSize - UInt64(tailLength))
            let tail = [UInt8](handle.readData(ofLength: tailLength))
            guard tail.count == tailLength, Array(tail[4...]) == CompactDictionaryFormat.magic else { throw DictionaryError.unreadable }
            let jsonLength = UInt64(LittleEndian.read(UInt32.self, tail, at: 0))
            guard jsonLength > 0, jsonLength < fileSize - UInt64(tailLength) else { throw DictionaryError.unreadable }
            try handle.seek(toOffset: fileSize - UInt64(tailLength) - jsonLength)
            let decoded = try JSONDecoder().decode(CompactDictionaryInfo.self, from: handle.readData(ofLength: Int(jsonLength)))
            guard decoded.formatVersion == CompactDictionaryFormat.version,
                  decoded.bucketTableOffset + UInt64(decoded.bucketCount) * 16 <= fileSize,
                  decoded.blockTableOffset + UInt64(decoded.blockCount) * 16 <= decoded.bucketTableOffset else {
                throw DictionaryError.unreadable
            }
            info = decoded
        } catch {
            try? handle.close()
            throw DictionaryError.unreadable
        }
    }

    deinit { try? handle.close() }

    /// Reads just the footer of a file (for listing installed dictionaries).
    public static func readInfo(at url: URL) throws -> CompactDictionaryInfo {
        try CompactDictionary(url: url).info
    }

    /// Entries whose headword (or synonym / inflected form) has the same normalized key as `word`,
    /// headword matches first. Empty when the key is absent.
    public func entries(for word: String) throws -> [DictionaryEntry] {
        let key = CompactDictionaryFormat.normalizedKey(word)
        guard !key.isEmpty, info.bucketCount > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        let refs = try findRefs(key)
        var result: [DictionaryEntry] = []
        for ref in refs {
            let block = try blockBytes(ref.block)
            let end = Int(ref.offset) + Int(ref.length)
            guard end <= block.count else { throw DictionaryError.unreadable }
            let entry = try EntryCodec.decode(block[Int(ref.offset)..<end], language: info.language, source: info.source)
            if !result.contains(entry) { result.append(entry) }
        }
        return result
    }

    // MARK: Internals (call with the lock held)

    private func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset + UInt64(count) <= fileSize else { throw DictionaryError.unreadable }
        try handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: count)
        guard data.count == count else { throw DictionaryError.unreadable }
        return [UInt8](data)
    }

    /// Offset, compressed and uncompressed size of a block (`table` = block table) or bucket.
    private func tableRow(_ table: UInt64, _ i: Int) throws -> (offset: UInt64, compressed: Int, raw: Int) {
        let row = try read(at: table + UInt64(i) * 16, count: 16)
        let raw = Int(LittleEndian.read(UInt32.self, row, at: 12))
        guard raw <= 16 << 20 else { throw DictionaryError.unreadable }
        return (LittleEndian.read(UInt64.self, row, at: 0), Int(LittleEndian.read(UInt32.self, row, at: 8)), raw)
    }

    private func inflate(_ row: (offset: UInt64, compressed: Int, raw: Int)) throws -> [UInt8] {
        do {
            return try Deflate.decompress(Data(try read(at: row.offset, count: row.compressed)), rawSize: row.raw)
        } catch {
            throw DictionaryError.unreadable
        }
    }

    private struct Record { var key: [UInt8]; var ref: CompactEntryRef }

    private func records(inBucket i: Int, firstOnly: Bool = false) throws -> [Record] {
        let bytes = try inflate(try tableRow(info.bucketTableOffset, i))
        return try bytes.withUnsafeBufferPointer { b in
            var out: [Record] = []
            var p = 0
            var previous: [UInt8] = []
            while p < b.count {
                let shared = Int(try Varint.read(b, &p))
                let suffix = Int(try Varint.read(b, &p))
                guard shared <= previous.count, p + suffix <= b.count else { throw DictionaryError.unreadable }
                let key = Array(previous.prefix(shared)) + Array(b[p..<(p + suffix)])
                p += suffix
                let block = try Varint.read(b, &p), offset = try Varint.read(b, &p), len = try Varint.read(b, &p)
                guard block < UInt64(info.blockCount), offset <= UInt64(UInt32.max), len <= UInt64(UInt32.max) else {
                    throw DictionaryError.unreadable
                }
                out.append(Record(key: key, ref: CompactEntryRef(block: UInt32(block), offset: UInt32(offset), length: UInt32(len))))
                previous = key
                if firstOnly { break }
            }
            return out
        }
    }

    private func findRefs(_ key: [UInt8]) throws -> [CompactEntryRef] {
        // First bucket whose first key is >= key; matches may start in the bucket before it.
        var lo = 0, hi = info.bucketCount
        while lo < hi {
            let mid = (lo + hi) / 2
            guard let first = try records(inBucket: mid, firstOnly: true).first else { throw DictionaryError.unreadable }
            if first.key.lexicographicallyPrecedes(key) { lo = mid + 1 } else { hi = mid }
        }
        var refs: [CompactEntryRef] = []
        var bucket = max(lo - 1, 0)
        scan: while bucket < info.bucketCount {
            for record in try records(inBucket: bucket) {
                if record.key == key { refs.append(record.ref) }
                else if key.lexicographicallyPrecedes(record.key) { break scan }
            }
            bucket += 1
        }
        return refs
    }

    private func blockBytes(_ index: UInt32) throws -> [UInt8] {
        if let cached = cachedBlock, cached.index == index { return cached.bytes }
        guard Int(index) < info.blockCount else { throw DictionaryError.unreadable }
        let bytes = try inflate(try tableRow(info.blockTableOffset, Int(index)))
        cachedBlock = (index, bytes)
        return bytes
    }
}
