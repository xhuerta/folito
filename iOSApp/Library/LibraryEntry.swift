import Foundation
import ReaderCore

/// One imported book as listed in the library. Persisted as `library.json`.
struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String { documentHash }
    var documentHash: String
    var title: String
    var author: String
    /// File name (inside the books directory) of the compressed ProcessedBook.
    var fileName: String
    /// Size in bytes of the compressed payload.
    var size: Int
    var importedAt: Date
    var sentToWatch: Bool
    /// Language of the bundled sample book this entry was imported from (see `SampleBooks`), nil for the
    /// user's own books. The library shows a "Sample" badge for these; otherwise they are ordinary books.
    /// Optional, so libraries saved before samples existed decode unchanged.
    var sampleLanguage: String? = nil
    /// Readest `meta_hash` of the book (sent when the book is uploaded to Readest). Optional: entries saved
    /// before the Readest library existed decode unchanged.
    var metaHash: String? = nil
    /// Whether the EPUB has a usable cover (stored by `CoverStore`); nil until the book has been checked, which
    /// happens at import, or lazily for books imported before covers existed (`LibraryStore.fillMissingCovers`).
    var hasCover: Bool? = nil
    /// Descriptive metadata read from the EPUB (description, series, publisher, …); nil when unknown.
    var details: EPUBDetails? = nil

    var isSample: Bool { sampleLanguage != nil }

    static func fileName(forHash hash: String) -> String { "\(hash).wrbook" }
    /// The original EPUB, kept next to the payload so the book can be uploaded to Readest byte for byte.
    static func originalFileName(forHash hash: String) -> String { "\(hash).epub" }
}

/// Pure helpers for presenting metadata.
enum BookDisplay {
    static func author(from authors: [String]) -> String {
        let cleaned = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return String(localized: "Unknown author", comment: "Shown when an EPUB lists no author")
        }
        return cleaned.joined(separator: ", ")
    }

    static func title(_ raw: String, fallbackFileName: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return (fallbackFileName as NSString).deletingPathExtension
    }
}
