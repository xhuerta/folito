import Foundation
import Crypto
import ZIPFoundation

/// StarDict (as downloaded, usually a ZIP) -> compact dictionary file. Runs on the iPhone; the watch only
/// receives the result.
public enum StarDictConverter {
    /// Largest StarDict member accepted from a ZIP (guards against archive bombs).
    public static let maxMemberSize: UInt64 = 2 << 30

    /// Extracts the StarDict files of `zip` into `workDirectory` (CRC-checked by ZIPFoundation) and
    /// converts them. `workDirectory` is created if needed and may be deleted afterwards.
    public static func convert(zip: URL, template: CompactDictionaryInfo, to output: URL, workDirectory: URL,
                               progress: ((Double) -> Void)? = nil,
                               isCancelled: () -> Bool = { false }) throws -> CompactDictionaryInfo {
        let archive: Archive
        do { archive = try Archive(url: zip, accessMode: .read) } catch { throw DictionaryImportError.notAStarDict }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        // Only the first file of each kind is used; names on disk are fixed, so ZIP paths never matter.
        let kinds = [".ifo", ".idx", ".dict.dz", ".dict", ".syn"]
        var found: Set<String> = []
        for entry in archive where entry.type == .file {
            let name = entry.path.lowercased()
            guard let kind = kinds.first(where: { name.hasSuffix($0) }), !found.contains(kind) else { continue }
            guard entry.uncompressedSize <= maxMemberSize else { throw DictionaryImportError.corrupt("member size") }
            let target = workDirectory.appendingPathComponent("source" + kind)
            try? FileManager.default.removeItem(at: target)
            do { _ = try archive.extract(entry, to: target) } catch { throw DictionaryImportError.corrupt("zip") }
            found.insert(kind)
            if isCancelled() { throw CancellationError() }
        }
        return try convert(directory: workDirectory, template: template, to: output, workDirectory: workDirectory,
                           progress: progress, isCancelled: isCancelled)
    }

    /// Converts the StarDict dictionary in `directory` (one `.ifo` with its `.idx`, `.dict` or `.dict.dz`
    /// and optional `.syn`).
    public static func convert(directory: URL, template: CompactDictionaryInfo, to output: URL, workDirectory: URL,
                               progress: ((Double) -> Void)? = nil,
                               isCancelled: () -> Bool = { false }) throws -> CompactDictionaryInfo {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let ifo = files.first(where: { $0.pathExtension.lowercased() == "ifo" }) else {
            throw DictionaryImportError.notAStarDict
        }
        let base = ifo.deletingPathExtension().lastPathComponent
        func file(_ ext: String) -> URL? {
            files.first { $0.lastPathComponent.lowercased() == (base + ext).lowercased() }
        }
        guard let ifoText = String(data: try Data(contentsOf: ifo), encoding: .utf8) else { throw DictionaryImportError.notAStarDict }
        let ifoInfo = try StarDictInfo.parse(ifoText)
        guard let idxURL = file(".idx") else { throw DictionaryImportError.notAStarDict }
        let idxData = try Data(contentsOf: idxURL)
        guard idxData.count == ifoInfo.idxFileSize else { throw DictionaryImportError.corrupt("idx size") }
        let items = try StarDictIndex.parseIdx(idxData, offsetBits: ifoInfo.idxOffsetBits)
        guard items.count == ifoInfo.wordCount else { throw DictionaryImportError.corrupt("idx count") }

        let dictURL: URL
        if let dz = file(".dict.dz") {
            try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            dictURL = workDirectory.appendingPathComponent("inflated.dict")
            try Gzip.decompress(dz, to: dictURL)
        } else if let plain = file(".dict") {
            dictURL = plain
        } else {
            throw DictionaryImportError.notAStarDict
        }
        defer { if dictURL.lastPathComponent == "inflated.dict" { try? fm.removeItem(at: dictURL) } }
        let dict = try Data(contentsOf: dictURL, options: .alwaysMapped)
        if isCancelled() { throw CancellationError() }

        let fixedType = ifoInfo.sameTypeSequence.first
        let writer = try CompactDictionaryWriter(url: output)
        var refs = [CompactEntryRef?](repeating: nil, count: items.count)
        var headwords = 0
        let step = max(items.count / 200, 1)
        for (n, item) in items.enumerated() {
            if n % step == 0 {
                if isCancelled() { throw CancellationError() }
                progress?(0.9 * Double(n) / Double(max(items.count, 1)))
            }
            let start = Int(item.offset), end = start + Int(item.size)
            guard end <= dict.count else { throw DictionaryImportError.corrupt("definition offset") }
            var bytes = dict.subdata(in: start..<end)
            var type = fixedType ?? "h"
            if fixedType == nil {
                // No sametypesequence: each record is a type letter + NUL-terminated data (first field only).
                guard let t = bytes.first else { continue }
                type = Character(UnicodeScalar(t))
                bytes = bytes.dropFirst().prefix(while: { $0 != 0 })
            }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let entry = StarDictDefinition.parse(text, word: item.word, language: template.language,
                                                       source: template.source, type: type) else { continue }
            let ref = try writer.add(entry)
            refs[n] = ref
            writer.addKey(item.word, ref: ref)
            headwords += 1
        }
        if let synURL = file(".syn") {
            for syn in try StarDictIndex.parseSyn(try Data(contentsOf: synURL)) {
                guard syn.index >= 0, syn.index < refs.count, let ref = refs[syn.index] else { continue }
                writer.addKey(syn.word, ref: ref, isHeadword: false)
            }
        }
        if isCancelled() { throw CancellationError() }
        progress?(0.95)
        var info = template
        info.headwordCount = headwords
        if info.sourceVersion.isEmpty { info.sourceVersion = ifoInfo.date ?? "" }
        let result = try writer.finish(info: info)
        progress?(1)
        // Read back the footer: what goes to the watch must open.
        guard (try? CompactDictionary.readInfo(at: output)) == result else { throw DictionaryImportError.invalidCompactFile }
        return result
    }
}

/// Integrity checks for downloaded and transferred files.
public enum FileDigest {
    /// Lower-case hex SHA-256 of a file, read in 1 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Throws `checksumMismatch` unless the file has the expected size and SHA-256 (each check only when
    /// an expected value is given).
    public static func verify(_ url: URL, size: Int64?, sha256 expected: String?) throws {
        if let size, self.size(of: url) != size { throw DictionaryImportError.checksumMismatch }
        if let expected, try sha256(of: url) != expected.lowercased() { throw DictionaryImportError.checksumMismatch }
    }
}
