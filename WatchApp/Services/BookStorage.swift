import Foundation
import ReaderCore

struct LibraryEntry: Codable, Identifiable, Equatable {
    var documentHash: String
    var title: String
    var author: String
    var totalCharacters: Int
    var addedAt: Date
    /// A cover thumbnail from the iPhone is stored next to the book. Optional: older indexes decode unchanged.
    var hasCover: Bool? = nil
    /// Read status ("Finished") with the time it was set, synced with the iPhone (last writer wins). Optional:
    /// older indexes decode unchanged.
    var readStatus: ReadStatusMark? = nil
    /// True from the moment the book arrives from the iPhone until it is first opened on the watch: the Library row
    /// shows a "New" badge (#156). Optional: indexes saved before this existed decode as nil, which counts as
    /// opened, so books already on the watch are never shown as new.
    var unopened: Bool? = nil
    var id: String { documentHash }
    var isFinished: Bool { readStatus?.isFinished == true }
    var isNew: Bool { unopened == true }

    /// Whether a book that just arrived from the iPhone is new: a book the watch did not have is; a book sent again
    /// (already in the library) keeps its state, so re-sending a book the user has opened does not mark it new.
    static func arrivesUnopened(previous: LibraryEntry?) -> Bool {
        previous.map(\.isNew) ?? true
    }
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
            .appendingPathComponent("Folito", isDirectory: true)
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

    /// Validates the received file, stores it and returns its library entry. The book's pictures (#71) go to files
    /// of their own (`imageDirectory`) and the book is stored without them, so opening it never decodes them.
    func importBook(from url: URL) throws -> LibraryEntry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let book = try Self.decode(compressed: data)
        let dest = fileURL(book.documentHash)
        try? fm.removeItem(at: dest)
        try? fm.removeItem(at: imageDirectory(book.documentHash))
        if book.images?.isEmpty == false {
            try storeSplittingImages(book, to: dest)
        } else {
            try data.write(to: dest, options: .atomic)
        }
        return LibraryEntry(documentHash: book.documentHash,
                            title: book.metadata.title,
                            author: book.metadata.authors.joined(separator: ", "),
                            totalCharacters: book.totalCharacters,
                            addedAt: Date())
    }

    // MARK: Covers

    /// The cover thumbnail (JPEG from the iPhone) of a book.
    func coverURL(_ hash: String) -> URL {
        directory.appendingPathComponent(Self.safeName(hash)).appendingPathExtension("cover.jpg")
    }

    /// Stores a received cover; refuses anything that is not a small image (the phone sends 2–6 KB).
    @discardableResult
    func saveCover(_ data: Data, documentHash: String) -> Bool {
        guard !data.isEmpty, data.count <= Self.maxCoverBytes else { return false }
        return (try? data.write(to: coverURL(documentHash), options: .atomic)) != nil
    }

    static let maxCoverBytes = 64 * 1024

    func load(documentHash: String) throws -> ProcessedBook {
        let book = try Self.decode(compressed: Data(contentsOf: fileURL(documentHash), options: .mappedIfSafe))
        // Stored by a watch build from before images (#71), which kept them inside the book: split them out now.
        guard book.images?.isEmpty == false else { return book }
        try? storeSplittingImages(book, to: fileURL(documentHash))
        var stripped = book
        stripped.images = nil
        return stripped
    }

    // MARK: Images (#71)

    /// The folder that holds a book's pictures, one file per `BookImage.id`.
    func imageDirectory(_ hash: String) -> URL {
        directory.appendingPathComponent(Self.safeName(hash) + ".images", isDirectory: true)
    }

    /// The files of a book's pictures.
    func imageFiles(_ hash: String) -> BookImageFiles {
        BookImageFiles(directory: imageDirectory(hash))
    }

    /// Writes the pictures to `imageDirectory`, then the book without them to `dest`.
    private func storeSplittingImages(_ book: ProcessedBook, to dest: URL) throws {
        let folder = imageDirectory(book.documentHash)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = BookImageFiles(directory: folder)
        for image in book.images ?? [] {
            guard let url = files.url(for: image.id) else { continue }
            try image.data.write(to: url, options: .atomic)
        }
        var stripped = book
        stripped.images = nil
        let json = try JSONEncoder().encode(stripped)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: dest, options: .atomic)
    }

    func delete(documentHash: String) {
        try? fm.removeItem(at: fileURL(documentHash))
        try? fm.removeItem(at: coverURL(documentHash))
        try? fm.removeItem(at: imageDirectory(documentHash))
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
