import Foundation
import ZIPFoundation

/// Read-only access to the entries of an EPUB (ZIP) container with size and path guards.
/// Nothing is ever extracted to disk, so path traversal cannot write outside anywhere;
/// entries with unsafe names are still ignored so they cannot be referenced.
struct ZipReader {
    static let maxEntryCount = 20_000
    static let maxEntrySize: UInt64 = 64 * 1024 * 1024
    /// Cap on the sum of all decompressed bytes handed out by one reader (guards against many medium-sized bombs).
    static let maxTotalSize: UInt64 = 256 * 1024 * 1024

    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var used: UInt64 = 0
        func consume(_ n: UInt64, limit: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            used &+= n
            return used <= limit
        }
    }
    private let budget = Budget()
    private let maxTotalSize: UInt64

    private let archive: Archive
    private let entries: [String: Entry]
    private let lowercased: [String: String]

    private let maxEntrySize: UInt64

    init(url: URL, maxEntrySize: UInt64 = ZipReader.maxEntrySize, maxTotalSize: UInt64 = ZipReader.maxTotalSize) throws {
        self.maxEntrySize = maxEntrySize
        self.maxTotalSize = maxTotalSize
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBError.invalidArchive
        }
        var map: [String: Entry] = [:]
        var lower: [String: String] = [:]
        var count = 0
        for entry in archive {
            count += 1
            if count > Self.maxEntryCount { throw EPUBError.invalidArchive }
            guard entry.type == .file, let name = Self.normalize(entry.path) else { continue }
            map[name] = entry
            lower[name.lowercased()] = lower[name.lowercased()] ?? name
        }
        guard !map.isEmpty else { throw EPUBError.invalidArchive }
        self.archive = archive
        self.entries = map
        self.lowercased = lower
    }

    /// Normalises an entry name; returns nil for absolute paths or ones escaping the root (zip-slip).
    static func normalize(_ path: String) -> String? {
        if path.hasPrefix("/") || path.contains("\\") || path.contains("\0") { return nil }
        var parts: [String] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if parts.isEmpty { return nil }
                parts.removeLast()
            } else {
                parts.append(String(comp))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    func contains(_ path: String) -> Bool { resolve(path) != nil }

    private func resolve(_ path: String) -> Entry? {
        if let e = entries[path] { return e }
        if let real = lowercased[path.lowercased()] { return entries[real] }
        return nil
    }

    func data(at path: String) throws -> Data {
        guard let entry = resolve(path) else { throw EPUBError.missingResource(path) }
        guard entry.uncompressedSize <= maxEntrySize else { throw EPUBError.entryTooLarge(path) }
        var out = Data()
        out.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                out.append(chunk)
                if UInt64(out.count) > maxEntrySize { throw EPUBError.entryTooLarge(path) }
            }
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.invalidArchive
        }
        guard budget.consume(UInt64(out.count), limit: maxTotalSize) else { throw EPUBError.archiveTooLarge }
        return out
    }
}
