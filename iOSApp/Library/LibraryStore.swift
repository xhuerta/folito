import Foundation
import ReaderCore

/// Owns the on-disk library (Application Support/Folito) and the import pipeline.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var isImporting = false
    /// The last import problem, presented as an alert by the Library screen.
    @Published var importError: UserFacingError?
    /// The most recent successful import, so a screen that started one (the welcome tour) can show its result.
    @Published private(set) var lastImported: LibraryEntry?

    private let parser: EPUBParsing
    private let fm = FileManager.default
    let booksDirectory: URL
    private let indexURL: URL

    /// Called after a successful import so the app can auto-send to the watch.
    var onImported: ((LibraryEntry) -> Void)?
    var onDeleted: ((LibraryEntry) -> Void)?
    /// Called when a book imported before covers existed gained a cover (`fillMissingCovers`).
    var onCoverAdded: ((LibraryEntry) -> Void)?
    /// Called when a book took its Readest row's id (`relink`): the old copy is gone from the library (and
    /// `onDeleted` has run for it); `wasOnWatch` says whether the old copy had been sent to the watch.
    var onRelinked: ((_ entry: LibraryEntry, _ wasOnWatch: Bool) -> Void)?
    /// Called when an Open Library cover was removed again (*Remove Online Details*), so the watch can drop it.
    var onCoverRemoved: ((LibraryEntry) -> Void)?
    private var isFillingCovers = false

    init(parser: EPUBParsing = EPUBParser(), rootDirectory: URL? = nil) {
        self.parser = parser
        let root = rootDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folito", isDirectory: true))
        booksDirectory = root.appendingPathComponent("Books", isDirectory: true)
        indexURL = root.appendingPathComponent("library.json")
        try? fm.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for entry: LibraryEntry) -> URL { booksDirectory.appendingPathComponent(entry.fileName) }

    /// The original EPUB of the entry, or nil for books imported before originals were kept.
    func originalFileURL(for entry: LibraryEntry) -> URL? {
        let url = booksDirectory.appendingPathComponent(LibraryEntry.originalFileName(forHash: entry.documentHash))
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Import

    /// Accepts a URL from fileImporter / onOpenURL / share sheet. Copies it into the sandbox first.
    /// `sampleLanguage` marks a bundled sample book (see `SampleBooks`); it goes through the same pipeline.
    func importEPUB(from url: URL, sampleLanguage: String? = nil) {
        guard let temp = copyToTemporary(url) else { return }
        Task { await runImport(temp: temp, name: url.lastPathComponent, sampleLanguage: sampleLanguage) }
    }

    /// A book downloaded from Readest: the same pipeline as any import (and sent to the watch), awaited so the
    /// Library can show the download until the book is in place. The book takes the id of the Readest row it came
    /// from (`identity`), not the hash of the downloaded bytes: Readest's `book_hash` is not always the partial MD5
    /// of the file it serves, and every link to Readest (the Library row, the reading position) goes by that id.
    func importDownloaded(from url: URL, fileName: String, identity: BookIdentityOverride? = nil) async -> LibraryEntry? {
        guard let temp = copyToTemporary(url, displayName: fileName) else { return nil }
        return await runImport(temp: temp, name: fileName, sampleLanguage: nil, identity: identity)
    }

    /// Gives a book the id of the Readest row the Library paired it with by metadata (a copy downloaded before
    /// downloads kept Readest's id): its kept original EPUB is processed again under that id, the old copy is
    /// removed (from the watch too) and the new one takes its place, keeping its import date and online details.
    /// Its reading position then syncs with the Readest row. Returns nil when there is nothing to do or no original.
    @discardableResult
    func relink(_ entry: LibraryEntry, to identity: BookIdentityOverride) async -> LibraryEntry? {
        guard entry.documentHash != identity.documentHash,
              !entries.contains(where: { $0.documentHash == identity.documentHash }),
              let original = originalFileURL(for: entry),
              let temp = copyToTemporary(original, displayName: entry.title) else { return nil }
        let parser = self.parser
        let dir = booksDirectory
        let name = "\(entry.title).epub"
        let processed = await Task.detached(priority: .utility) { () -> LibraryEntry? in
            defer { try? FileManager.default.removeItem(at: temp) }
            return try? LibraryStore.process(epub: temp, originalName: name, parser: parser, into: dir, identity: identity)
        }.value
        guard var relinked = processed,
              let old = entries.firstIndex(where: { $0.documentHash == entry.documentHash }) else { return nil }
        relinked.importedAt = entry.importedAt
        relinked.sampleLanguage = entry.sampleLanguage
        relinked.online = entry.online
        relinked.onlineLookupAt = entry.onlineLookupAt
        relinked.removedOnWatch = entry.removedOnWatch
        if entry.online?.hasCover == true {
            // The accepted Open Library cover lives next to the book under its id.
            let names: [(String) -> String] = [CoverStore.coverFileName(forHash:), CoverStore.watchFileName(forHash:)]
            for fileName in names {
                let to = dir.appendingPathComponent(fileName(relinked.documentHash))
                try? fm.removeItem(at: to)
                try? fm.copyItem(at: dir.appendingPathComponent(fileName(entry.documentHash)), to: to)
            }
            relinked.hasCover = true
        }
        try? fm.removeItem(at: fileURL(for: entry))
        try? fm.removeItem(at: original)
        CoverStore.removeCovers(hash: entry.documentHash, in: dir)
        CoverImages.shared.invalidate(hash: entry.documentHash)
        CoverImages.shared.invalidate(hash: relinked.documentHash)
        entries[old] = relinked
        save()
        onDeleted?(entry)
        onRelinked?(relinked, entry.sentToWatch)
        return relinked
    }

    private func copyToTemporary(_ url: URL, displayName: String? = nil) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        do {
            try fm.copyItem(at: url, to: temp)
            removeInboxCopy(url)
            return temp
        } catch {
            importError = .fileUnreadable(fileName: displayName ?? url.lastPathComponent)
            return nil
        }
    }

    /// Files opened from other apps arrive as a copy in Documents/Inbox (documents are not opened in place).
    /// The import keeps its own copy, so the Inbox one is removed to avoid keeping every book twice.
    private func removeInboxCopy(_ url: URL) {
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(inbox) else { return }
        try? fm.removeItem(at: url)
    }

    @discardableResult
    private func runImport(temp: URL, name: String, sampleLanguage: String?,
                           identity: BookIdentityOverride? = nil) async -> LibraryEntry? {
        isImporting = true
        let parser = self.parser
        let dir = booksDirectory
        let outcome: Result<LibraryEntry, Error> = await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                return .success(try LibraryStore.process(epub: temp, originalName: name, parser: parser, into: dir,
                                                         identity: identity))
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(var result):
            result.sampleLanguage = sampleLanguage
            CoverImages.shared.invalidate(hash: result.documentHash)
            finishImport(result)
            return result
        case .failure(let error):
            failImport(error, fileName: name)
            return nil
        }
    }

    /// Pure(ish) pipeline, runs off the main thread: parse -> JSON -> LZFSE -> file.
    /// `identity` replaces the ids computed from the file (a book downloaded from Readest keeps the row's ids).
    nonisolated static func process(epub: URL, originalName: String, parser: EPUBParsing, into dir: URL,
                                    identity: BookIdentityOverride? = nil) throws -> LibraryEntry {
        var book = try parser.process(epubAt: epub)
        if let identity {
            book.documentHash = identity.documentHash
            if let meta = identity.metaHash, !meta.isEmpty { book.metaHash = meta }
        }
        let data = try BookCodec.encode(book)
        let fileName = LibraryEntry.fileName(forHash: book.documentHash)
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        // Keep the original file (same bytes, same partial MD5) so the book can be uploaded to Readest.
        let original = dir.appendingPathComponent(LibraryEntry.originalFileName(forHash: book.documentHash))
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.copyItem(at: epub, to: original)
        let extras = readExtras(epub: epub, hash: book.documentHash, into: dir)
        return LibraryEntry(
            documentHash: book.documentHash,
            title: BookDisplay.title(book.metadata.title, fallbackFileName: originalName),
            author: BookDisplay.author(from: extras.details?.authors ?? book.metadata.authors),
            fileName: fileName, size: data.count, importedAt: Date(), sentToWatch: false,
            metaHash: book.metaHash, hasCover: extras.hasCover, details: extras.details)
    }

    /// Cover thumbnails and descriptive metadata of an EPUB (local only). A book whose metadata cannot be read
    /// still imports; it just has no details and gets a placeholder cover.
    nonisolated static func readExtras(epub: URL, hash: String, into dir: URL) -> (hasCover: Bool, details: EPUBDetails?) {
        guard let read = try? EPUBMetadataReader.read(epubAt: epub) else {
            CoverStore.removeCovers(hash: hash, in: dir)
            return (false, nil)
        }
        return (CoverStore.storeCover(read.cover, hash: hash, in: dir), read.details)
    }

    // MARK: Covers of older books

    /// Books imported before covers existed get their cover and details from the kept original EPUB, once,
    /// in the background. Books without an original get the placeholder. `onCoverAdded` reports each book
    /// that gained a real cover (so the watch can get it too).
    func fillMissingCovers() {
        let pending = entries.filter { $0.hasCover == nil }
        guard !pending.isEmpty, !isFillingCovers else { return }
        isFillingCovers = true
        let dir = booksDirectory
        let work: [(hash: String, original: URL?)] = pending.map { ($0.documentHash, originalFileURL(for: $0)) }
        Task {
            var results: [String: (Bool, EPUBDetails?)] = [:]
            for item in work {
                let result: (Bool, EPUBDetails?) = await Task.detached(priority: .utility) {
                    guard let original = item.original else { return (false, nil) }
                    let extras = LibraryStore.readExtras(epub: original, hash: item.hash, into: dir)
                    return (extras.hasCover, extras.details)
                }.value
                results[item.hash] = result
            }
            var added: [LibraryEntry] = []
            for i in entries.indices {
                guard entries[i].hasCover == nil, let result = results[entries[i].documentHash] else { continue }
                let (hasCover, details) = result
                entries[i].hasCover = hasCover
                if entries[i].details == nil { entries[i].details = details }
                CoverImages.shared.invalidate(hash: entries[i].documentHash)
                if hasCover { added.append(entries[i]) }
            }
            save()
            isFillingCovers = false
            added.forEach { onCoverAdded?($0) }
        }
    }

    // MARK: Online details (docs/ONLINE_METADATA.md)

    /// Applies the chosen pieces of an Open Library match, filling only what the EPUB lacks. The EPUB file is
    /// never touched (same hash, same sync). `coverData` is the downloaded cover image, when the cover was chosen.
    /// Returns the pieces that were applied.
    @discardableResult
    func applyOnline(_ match: OnlineBookMatch, selection: OnlineFieldSelection, coverData: Data?,
                     to hash: String) async -> OnlineFieldSelection {
        guard let entry = entries.first(where: { $0.documentHash == hash }) else { return [] }
        let allowed = OnlineMetadataMerge.applicable(match, details: entry.details, hasEPUBCover: entry.hasEPUBCover,
                                                     online: entry.online).intersection(selection)
        guard !allowed.isEmpty else { return [] }
        var coverStored = false
        if allowed.contains(.cover), let coverData {
            let dir = booksDirectory
            coverStored = await Task.detached(priority: .userInitiated) {
                CoverStore.storeImage(coverData, hash: hash, in: dir)
            }.value
        }
        // The entry may have changed (or gone) while the cover was being stored.
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }) else { return [] }
        let before = entries[i].online
        guard let online = OnlineMetadataMerge.apply(match, selection: allowed, details: entries[i].details,
                                                     hasEPUBCover: entries[i].hasEPUBCover, online: before,
                                                     coverStored: coverStored) else { return [] }
        entries[i].online = online
        var applied = allowed
        if !coverStored { applied.remove(.cover) }
        if coverStored {
            entries[i].hasCover = true
            CoverImages.shared.invalidate(hash: hash)
        }
        save()
        if coverStored { onCoverAdded?(entries[i]) }
        return applied
    }

    /// Drops everything that came from Open Library: the book shows its EPUB-only data again and, if the cover
    /// was Open Library's, the generated placeholder.
    func removeOnlineDetails(hash: String) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }), let online = entries[i].online else { return }
        entries[i].online = nil
        if online.hasCover {
            CoverStore.removeCovers(hash: hash, in: booksDirectory)
            entries[i].hasCover = false
            CoverImages.shared.invalidate(hash: hash)
        }
        save()
        if online.hasCover { onCoverRemoved?(entries[i]) }
    }

    /// Records that the background lookup has tried this book.
    func markLookedUpOnline(hash: String) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }) else { return }
        entries[i].onlineLookupAt = Date()
        save()
    }

    /// The watch thumbnail (JPEG, a few KB) of a book, if it has a cover.
    func watchCover(for entry: LibraryEntry) -> Data? {
        guard entry.hasCover == true else { return nil }
        return try? Data(contentsOf: booksDirectory.appendingPathComponent(CoverStore.watchFileName(forHash: entry.documentHash)))
    }

    private func finishImport(_ entry: LibraryEntry) {
        isImporting = false
        entries.removeAll { $0.documentHash == entry.documentHash }
        entries.insert(entry, at: 0)
        save()
        lastImported = entry
        onImported?(entry)
    }

    private func failImport(_ error: Error, fileName: String) {
        isImporting = false
        importError = .importFailed(fileName: fileName, error: error)
    }

    #if DEBUG
    /// UI testing only (see UITestingSupport): adds an already-converted book without the import pipeline.
    /// `coverPNG` is stored like an EPUB's cover; nil gives the placeholder.
    func addForUITesting(_ book: ProcessedBook, fileName: String, coverPNG: Data? = nil, details: EPUBDetails? = nil,
                         sentToWatch: Bool = false) throws {
        let data = try BookCodec.encode(book)
        let payload = LibraryEntry.fileName(forHash: book.documentHash)
        try data.write(to: booksDirectory.appendingPathComponent(payload), options: .atomic)
        let cover = coverPNG.map { EPUBCover(data: $0, mediaType: "image/png", path: "cover.png", source: .coverImageProperty) }
        let hasCover = CoverStore.storeCover(cover, hash: book.documentHash, in: booksDirectory)
        let entry = LibraryEntry(documentHash: book.documentHash,
                                 title: BookDisplay.title(book.metadata.title, fallbackFileName: fileName),
                                 author: BookDisplay.author(from: book.metadata.authors),
                                 fileName: payload, size: data.count, importedAt: Date(), sentToWatch: sentToWatch,
                                 metaHash: book.metaHash, hasCover: hasCover, details: details)
        entries.removeAll { $0.documentHash == entry.documentHash }
        entries.insert(entry, at: 0)
        save()
    }
    #endif

    // MARK: Sample books

    /// The library entry imported from the sample book in `language`, if it is in the library.
    func sampleEntry(language: String) -> LibraryEntry? {
        entries.first { $0.sampleLanguage == language }
    }

    /// Imports the bundled sample book for `language` through the normal import pipeline (so it is sent to the
    /// watch like any book). Returns false when this build has no such sample.
    @discardableResult
    func addSample(language: String, bundle: Bundle = .main) -> Bool {
        guard let url = SampleBooks.url(for: language, in: bundle) else { return false }
        importEPUB(from: url, sampleLanguage: language)
        return true
    }

    // MARK: Mutations

    /// Removes the book from this iPhone (payload and original EPUB) and, through `onDeleted`, from the watch.
    /// A copy in Readest is not touched.
    func delete(_ entry: LibraryEntry) {
        try? fm.removeItem(at: fileURL(for: entry))
        try? fm.removeItem(at: booksDirectory.appendingPathComponent(LibraryEntry.originalFileName(forHash: entry.documentHash)))
        CoverStore.removeCovers(hash: entry.documentHash, in: booksDirectory)
        CoverImages.shared.invalidate(hash: entry.documentHash)
        entries.removeAll { $0.id == entry.id }
        save()
        onDeleted?(entry)
    }

    func markSent(hash: String, sent: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }) else { return }
        entries[i].sentToWatch = sent
        if sent { entries[i].removedOnWatch = nil }
        save()
    }

    /// The user deleted the book on the watch (`book_removed` message or the `removed` list of its library
    /// report): it is no longer sent automatically. `watchID` is the reporting watch app's installation id.
    func markRemovedOnWatch(hash: String, watchID: String?) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }) else { return }
        let flag = watchID ?? ""
        guard entries[i].sentToWatch || entries[i].removedOnWatch != flag else { return }
        entries[i].sentToWatch = false
        entries[i].removedOnWatch = flag
        save()
    }

    /// "Send to Apple Watch": the user wants the book there again, so it is sent automatically from now on.
    func clearRemovedOnWatch(hash: String) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }), entries[i].removedOnWatch != nil else { return }
        entries[i].removedOnWatch = nil
        save()
    }

    /// Aligns `sentToWatch` with what the watch reports it stores (it may have been reinstalled, or a
    /// transfer was lost). Books whose transfer is still in flight are left untouched.
    /// Only an explicit deletion on the watch marks a book "removed there": `removed` (the hashes the user deleted
    /// on that watch) or a `book_removed` message. A book that is merely missing is sent again, so a reset or
    /// re-paired watch gets the whole library; a report from another watch installation (`watchID`) also clears
    /// the "removed" mark of books deleted on the previous one.
    func reconcile(watchHashes: Set<String>, removed: Set<String> = [], watchID: String? = nil, inFlight: Set<String>) {
        var changed = false
        for i in entries.indices where !inFlight.contains(entries[i].documentHash) {
            let hash = entries[i].documentHash
            let onWatch = watchHashes.contains(hash)
            var flag = entries[i].removedOnWatch
            if onWatch {
                flag = nil
            } else if removed.contains(hash) {
                flag = watchID ?? flag ?? ""
            } else if let watchID, let current = flag, current != watchID {
                flag = nil
            }
            if entries[i].sentToWatch != onWatch { entries[i].sentToWatch = onWatch; changed = true }
            if entries[i].removedOnWatch != flag { entries[i].removedOnWatch = flag; changed = true }
        }
        if changed { save() }
    }

    /// Books the watch has not confirmed, with their payload files. Books the user deleted on the watch are left
    /// out until they are sent explicitly.
    var unsentBooks: [(entry: LibraryEntry, fileURL: URL)] {
        entries.filter { !$0.sentToWatch && !$0.isRemovedOnWatch }.map { ($0, fileURL(for: $0)) }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return }
        entries = decoded.filter { fm.fileExists(atPath: booksDirectory.appendingPathComponent($0.fileName).path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

/// The ids a book takes instead of the ones computed from its file: those of the Readest row it came from.
struct BookIdentityOverride: Sendable, Equatable {
    var documentHash: String
    var metaHash: String?

    init(documentHash: String, metaHash: String?) {
        self.documentHash = documentHash
        self.metaHash = metaHash
    }

    init(_ book: ReadestCloudBook) { self.init(documentHash: book.hash, metaHash: book.metaHash) }
}
