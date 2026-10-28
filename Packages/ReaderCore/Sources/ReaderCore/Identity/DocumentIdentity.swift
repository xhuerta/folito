import Foundation
import Crypto

public enum IdentityError: Error, Equatable {
    case notImplemented
    case unreadableFile
}

/// Document identifiers used by KOReader and Readest.
public protocol DocumentIdentifying: Sendable {
    /// KOReader `util.partialMD5` of the file contents, lowercase hex.
    func partialMD5(fileAt url: URL) throws -> String
    /// Same algorithm over in-memory data.
    func partialMD5(of data: Data) -> String
    /// Readest `generateMetadataHash`: md5("title|authors|identifier"), lowercase hex.
    func metaHash(for metadata: BookMetadata) -> String
}

public struct DocumentIdentity: DocumentIdentifying {
    public init() {}

    // MARK: partialMD5
    //
    // Verbatim from koreader/koreader frontend/util.lua (`local lshift = bit.lshift`, LuaJIT):
    //
    //   function util.partialMD5(filepath)
    //       if not filepath then return end
    //       local file = io.open(filepath, "rb")
    //       if not file then return end
    //       local step, size = 1024, 1024
    //       local update = md5()
    //       for i = -1, 10 do
    //           file:seek("set", lshift(step, 2*i))
    //           local sample = file:read(size)
    //           if sample then
    //               update(sample)
    //           else
    //               break
    //           end
    //       end
    //       file:close()
    //       return update()
    //   end
    //
    // NOTE (discrepancy, see docs/DISCREPANCIES.md): for i = -1 the shift count is -2. LuaJIT's
    // bit.lshift (and JS `<<` in Readest's md5.ts) masks the count to 5 bits, so it becomes 30 and
    // 1024 << 30 overflows 32 bits to 0. The first sample is therefore at offset 0, NOT 256.
    // Subsequent offsets are 1024 << (2*i) = 1024 * 4^i for i = 0...10.
    // Offsets above 2^32 never occur (max is 1024 * 4^10 = 2^30), so 32-bit masking is irrelevant there.

    static let partialOffsets: [UInt64] = [0] + (0...10).map { UInt64(1024) << UInt64(2 * $0) }
    static let sampleSize = 1024

    public func partialMD5(fileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw IdentityError.unreadableFile }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        do {
            for offset in Self.partialOffsets {
                try handle.seek(toOffset: offset)
                guard let sample = try handle.read(upToCount: Self.sampleSize), !sample.isEmpty else { break }
                hasher.update(data: sample)
            }
        } catch {
            throw IdentityError.unreadableFile
        }
        return Self.hex(hasher.finalize())
    }

    public func partialMD5(of data: Data) -> String {
        var hasher = Insecure.MD5()
        for offset in Self.partialOffsets {
            guard offset < UInt64(data.count) else { break }
            let start = data.startIndex + Int(offset)
            let end = min(data.endIndex, start + Self.sampleSize)
            hasher.update(data: data[start..<end])
        }
        return Self.hex(hasher.finalize())
    }

    // MARK: metaHash
    //
    // Mirrors readest-app/src/utils/book.ts `getMetadataHashInfo` (canonical, wire format) and
    // apps/readest.koplugin/readest_syncconfig.lua `computeMetadataHashInfo`:
    //   hashSource = "\(title)|\(authors.joined(","))|\(identifiers.joined(","))"
    //   metaHash   = md5(hashSource.normalize('NFC'))
    // Identifier priority (getPreferredIdentifier): scheme "uuid" > "calibre" > "isbn"; the first
    // identifier matching the best scheme wins and is the only one hashed. If none matches, all
    // normalized non-empty identifiers are joined with ",".
    // normalizeIdentifier: contains "urn:" -> text after the LAST ':'; else contains ':' -> text
    // after the FIRST ':'; otherwise unchanged.

    public func metaHash(for metadata: BookMetadata) -> String {
        var hasher = Insecure.MD5()
        hasher.update(data: Data(hashSource(for: metadata).precomposedStringWithCanonicalMapping.utf8))
        return Self.hex(hasher.finalize())
    }

    /// The string that gets hashed (before NFC normalization); exposed internally for tests.
    func hashSource(for metadata: BookMetadata) -> String {
        // Authors: the KOReader plugin trims whitespace per author, Readest TS does not (it only
        // drops empty ones). We trim and drop empties (identical for already-clean metadata).
        let authors = metadata.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let identifiers = Self.identifierList(metadata.identifiers)
        return "\(metadata.title)|\(authors.joined(separator: ","))|\(identifiers.joined(separator: ","))"
    }

    static func normalizeIdentifier(_ id: String) -> String {
        if id.contains("urn:") {
            // /[^:]+$/ : the trailing run of non-colon characters ("" if id ends with ':').
            return String(id[(id.lastIndex(of: ":").map { id.index(after: $0) } ?? id.startIndex)...])
        } else if let colon = id.firstIndex(of: ":") {
            // /^[^:]+:(.+)$/ : requires a non-empty scheme and a non-empty rest, else "".
            let head = id[..<colon], rest = id[id.index(after: colon)...]
            return (head.isEmpty || rest.isEmpty) ? "" : String(rest)
        }
        return id
    }

    static func identifierList(_ identifiers: [BookIdentifier]) -> [String] {
        // getPreferredIdentifier. A BookIdentifier with a scheme behaves like Readest's
        // `Identifier` object (scheme equality, raw value); without scheme like a plain string
        // (substring match on the whole string, then normalizeIdentifier).
        for scheme in ["uuid", "calibre", "isbn"] {
            let found = identifiers.first { id in
                if let s = id.scheme { return s.lowercased() == scheme }
                return id.value.lowercased().contains(scheme)
            }
            if let found {
                let value = found.scheme != nil ? found.value : normalizeIdentifier(found.value)
                if !value.isEmpty { return [value] }  // JS: `if (preferred)` is falsy for ""
                break
            }
        }
        return identifiers
            .map { $0.scheme != nil ? $0.value : normalizeIdentifier($0.value) }
            .filter { !$0.isEmpty }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
