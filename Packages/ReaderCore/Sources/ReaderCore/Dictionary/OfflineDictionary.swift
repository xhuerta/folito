import Foundation

/// The compact dictionaries stored in one directory (`<id>.folidict` each). Thread-safe. Used by the
/// watch (lookups) and the iPhone (its copies, kept to resend them to the watch).
public final class InstalledDictionaries: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var open: [String: CompactDictionary] = [:]

    public init(directory: URL) {
        self.directory = directory
        reload()
    }

    public static func fileName(for id: String) -> String {
        // Ids come from the catalog or from transfer metadata: keep only safe characters.
        let safe = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return String(String.UnicodeScalarView(safe)) + "." + CompactDictionaryFormat.fileExtension
    }

    public func url(for id: String) -> URL { directory.appendingPathComponent(Self.fileName(for: id)) }

    /// Re-scans the directory. Files that do not open (damaged, or from a newer app) are skipped.
    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: CompactDictionary] = [:]
        for url in files where url.pathExtension == CompactDictionaryFormat.fileExtension {
            if let dict = try? CompactDictionary(url: url), url.lastPathComponent == Self.fileName(for: dict.info.id) {
                found[dict.info.id] = dict
            }
        }
        lock.lock(); open = found; lock.unlock()
    }

    /// Installed dictionaries, sorted by language then id.
    public var all: [CompactDictionary] {
        lock.lock(); defer { lock.unlock() }
        return open.values.sorted { ($0.info.language, $0.info.id) < ($1.info.language, $1.info.id) }
    }

    public var infos: [CompactDictionaryInfo] { all.map(\.info) }

    public func dictionary(id: String) -> CompactDictionary? {
        lock.lock(); defer { lock.unlock() }
        return open[id]
    }

    /// Moves a verified compact file into place (replacing an older copy of the same id) and opens it.
    /// `size` / `sha256` are checked when given.
    @discardableResult
    public func install(fileAt source: URL, size: Int64? = nil, sha256: String? = nil) throws -> CompactDictionaryInfo {
        try FileDigest.verify(source, size: size, sha256: sha256)
        let info: CompactDictionaryInfo
        do { info = try CompactDictionary.readInfo(at: source) } catch { throw DictionaryImportError.invalidCompactFile }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: info.id)
        lock.lock(); open[info.id] = nil; lock.unlock()
        // Stage next to the target first (a move; a copy if the source is on another volume), then swap it in.
        let staged = directory.appendingPathComponent(".incoming-" + UUID().uuidString)
        if (try? fm.moveItem(at: source, to: staged)) == nil { try fm.copyItem(at: source, to: staged) }
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: staged, to: target) } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: source)
        let dict = try CompactDictionary(url: target)
        lock.lock(); open[info.id] = dict; lock.unlock()
        return info
    }

    public func remove(id: String) {
        lock.lock(); open[id] = nil; lock.unlock()
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func removeAll() {
        for info in infos { remove(id: info.id) }
    }

    /// Bytes used by the installed files.
    public var totalSize: Int64 {
        all.reduce(0) { $0 + (FileDigest.size(of: $1.url) ?? 0) }
    }
}

/// Looks words up in the installed dictionaries, fully offline: the dictionary of the book's language
/// first, then the other installed ones. Each dictionary is tried with the `WordNormalizer` candidates
/// for its own language (cleaned form, lower case, simple de-inflections); synonyms and inflected forms
/// listed by the source (StarDict `.syn`) are part of the index, so "ran" finds "run".
public struct OfflineDictionaryService: DictionaryProviding {
    private let installed: InstalledDictionaries

    public init(installed: InstalledDictionaries) {
        self.installed = installed
    }

    /// Dictionaries in lookup order for a book language (nil = unknown: English first).
    public static func ordered(_ dictionaries: [CompactDictionary], language: String?) -> [CompactDictionary] {
        let lang = WordNormalizer.primaryLanguage(language)
        return dictionaries.filter { $0.info.language == lang } + dictionaries.filter { $0.info.language != lang }
    }

    public func lookup(_ word: String, language: String?) async throws -> DictionaryEntry {
        try Self.lookup(word, language: language, in: installed.all)
    }

    public static func lookup(_ word: String, language: String?, in dictionaries: [CompactDictionary]) throws -> DictionaryEntry {
        guard !dictionaries.isEmpty else { throw DictionaryError.noDictionary }
        var unreadable = false
        for dict in ordered(dictionaries, language: language) {
            var tried: Set<[UInt8]> = []
            for candidate in WordNormalizer.candidates(for: word, language: dict.info.language, limit: 8) {
                guard tried.insert(CompactDictionaryFormat.normalizedKey(candidate)).inserted else { continue }
                do {
                    let entries = try dict.entries(for: candidate)
                    if let merged = merge(entries, preferring: candidate) { return merged }
                } catch {
                    unreadable = true
                    break
                }
            }
        }
        throw unreadable ? DictionaryError.unreadable : DictionaryError.notFound
    }

    /// One result from the entries sharing a key, best first, the others' meanings appended (within
    /// `DictionaryLimits`). Order: the exact headword; the lower-case headword ("The" at the start of a
    /// sentence -> "the"); base forms the source lists for an inflected form ("maisons" -> "maison"),
    /// lower-case ones first; last, capitalised headwords for a lower-case word ("Maisons", a place name).
    static func merge(_ entries: [DictionaryEntry], preferring word: String) -> DictionaryEntry? {
        guard !entries.isEmpty else { return nil }
        let key = CompactDictionaryFormat.normalizedKey(word)
        let wordIsLower = word == word.lowercased()
        func rank(_ e: DictionaryEntry) -> Int {
            if e.word == word { return 0 }
            let entryIsLower = e.word == e.word.lowercased()
            if CompactDictionaryFormat.normalizedKey(e.word) == key { return entryIsLower ? 1 : 4 }
            return entryIsLower || !wordIsLower ? 2 : 3
        }
        let ordered = Array(entries.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .prefix(DictionaryLimits.entriesPerLookup))
        var result = ordered[0]
        for other in ordered.dropFirst() {
            for meaning in other.meanings where result.meanings.count < DictionaryLimits.meanings {
                result.meanings.append(meaning)
            }
        }
        return result
    }
}
