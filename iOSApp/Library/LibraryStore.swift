import Foundation
import ReaderCore

/// Owns the on-disk library (Application Support/WristReader) and the import pipeline.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    private let parser: EPUBParsing
    private let fm = FileManager.default
    let booksDirectory: URL
    private let indexURL: URL

    /// Called after a successful import so the app can auto-send to the watch.
    var onImported: ((LibraryEntry) -> Void)?
    var onDeleted: ((LibraryEntry) -> Void)?

    init(parser: EPUBParsing = EPUBParser(), rootDirectory: URL? = nil) {
        self.parser = parser
        let root = rootDirectory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristReader", isDirectory: true))
        booksDirectory = root.appendingPathComponent("Books", isDirectory: true)
        indexURL = root.appendingPathComponent("library.json")
        try? fm.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for entry: LibraryEntry) -> URL { booksDirectory.appendingPathComponent(entry.fileName) }

    // MARK: Import

    /// Accepts a URL from fileImporter / onOpenURL / share sheet. Copies it into the sandbox first.
    func importEPUB(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        do {
            try fm.copyItem(at: url, to: temp)
        } catch {
            errorMessage = "Could not read the file: \(error.localizedDescription)"
            return
        }
        let name = url.lastPathComponent
        isImporting = true
        let parser = self.parser
        let dir = booksDirectory
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let result = try LibraryStore.process(epub: temp, originalName: name, parser: parser, into: dir)
                await self.finishImport(result)
            } catch {
                await self.failImport(error)
            }
        }
    }

    /// Pure(ish) pipeline, runs off the main thread: parse -> JSON -> LZFSE -> file.
    nonisolated static func process(epub: URL, originalName: String, parser: EPUBParsing, into dir: URL) throws -> LibraryEntry {
        let book = try parser.process(epubAt: epub)
        let data = try BookCodec.encode(book)
        let fileName = LibraryEntry.fileName(forHash: book.documentHash)
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        return LibraryEntry(
            documentHash: book.documentHash,
            title: BookDisplay.title(book.metadata.title, fallbackFileName: originalName),
            author: BookDisplay.author(from: book.metadata.authors),
            fileName: fileName, size: data.count, importedAt: Date(), sentToWatch: false)
    }

    private func finishImport(_ entry: LibraryEntry) {
        isImporting = false
        entries.removeAll { $0.documentHash == entry.documentHash }
        entries.insert(entry, at: 0)
        save()
        onImported?(entry)
    }

    private func failImport(_ error: Error) {
        isImporting = false
        errorMessage = "Import failed: \(error.localizedDescription)"
    }

    // MARK: Mutations

    func delete(_ entry: LibraryEntry) {
        try? fm.removeItem(at: fileURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        save()
        onDeleted?(entry)
    }

    func markSent(hash: String, sent: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.documentHash == hash }) else { return }
        entries[i].sentToWatch = sent
        save()
    }

    /// Aligns `sentToWatch` with what the watch reports it stores (it may have been reinstalled, or the
    /// user deleted a book there). Books whose transfer is still in flight are left untouched.
    func reconcile(watchHashes: Set<String>, inFlight: Set<String>) {
        var changed = false
        for i in entries.indices where !inFlight.contains(entries[i].documentHash) {
            let onWatch = watchHashes.contains(entries[i].documentHash)
            if entries[i].sentToWatch != onWatch { entries[i].sentToWatch = onWatch; changed = true }
        }
        if changed { save() }
    }

    /// Books the watch has not confirmed, with their payload files.
    var unsentBooks: [(entry: LibraryEntry, fileURL: URL)] {
        entries.filter { !$0.sentToWatch }.map { ($0, fileURL(for: $0)) }
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
