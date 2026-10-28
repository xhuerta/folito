import Foundation
import ReaderCore

struct LibraryEntry: Codable, Identifiable, Equatable {
    var documentHash: String
    var title: String
    var author: String
    var totalCharacters: Int
    var addedAt: Date
    var id: String { documentHash }
}

enum BookStorageError: Error {
    case unreadable
    case unsupportedFormat(Int)
}

/// File-based storage of received books in Application Support. Books are kept in their
/// received (LZFSE-compressed JSON) form and decoded on demand. All methods are safe to call
/// from background threads.
final class BookStorage: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let fm = FileManager.default

    init(root: URL? = nil) {
        let base = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristReader", isDirectory: true)
        directory = base.appendingPathComponent("Books", isDirectory: true)
        indexURL = base.appendingPathComponent("library.json")
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Pure helpers

    /// Filesystem-safe file name for a document hash.
    static func safeName(_ hash: String) -> String {
        String(hash.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }

    static func decode(compressed: Data) throws -> ProcessedBook {
        let raw: Data
        do { raw = try (compressed as NSData).decompressed(using: .lzfse) as Data } catch { throw BookStorageError.unreadable }
        let book = try JSONDecoder().decode(ProcessedBook.self, from: raw)
        guard book.formatVersion <= ProcessedBook.currentFormatVersion else {
            throw BookStorageError.unsupportedFormat(book.formatVersion)
        }
        return book
    }

    // MARK: Books

    private func fileURL(_ hash: String) -> URL {
        directory.appendingPathComponent(Self.safeName(hash)).appendingPathExtension("book")
    }

    /// Validates the received file, stores it and returns its library entry.
    func importBook(from url: URL) throws -> LibraryEntry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let book = try Self.decode(compressed: data)
        let dest = fileURL(book.documentHash)
        try? fm.removeItem(at: dest)
        try data.write(to: dest, options: .atomic)
        return LibraryEntry(documentHash: book.documentHash,
                            title: book.metadata.title,
                            author: book.metadata.authors.joined(separator: ", "),
                            totalCharacters: book.totalCharacters,
                            addedAt: Date())
    }

    func load(documentHash: String) throws -> ProcessedBook {
        try Self.decode(compressed: Data(contentsOf: fileURL(documentHash), options: .mappedIfSafe))
    }

    func delete(documentHash: String) {
        try? fm.removeItem(at: fileURL(documentHash))
    }

    func deleteAll() {
        try? fm.removeItem(at: directory)
        try? fm.removeItem(at: indexURL)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Index

    func loadIndex() -> [LibraryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return [] }
        // Drop entries whose file vanished.
        return entries.filter { fm.fileExists(atPath: fileURL($0.documentHash).path) }
    }

    func saveIndex(_ entries: [LibraryEntry]) {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }
}
