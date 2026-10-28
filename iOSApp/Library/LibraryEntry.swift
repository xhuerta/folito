import Foundation

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

    static func fileName(forHash hash: String) -> String { "\(hash).wrbook" }
}

/// Pure helpers for presenting metadata.
enum BookDisplay {
    static func author(from authors: [String]) -> String {
        let cleaned = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? "Unknown author" : cleaned.joined(separator: ", ")
    }

    static func title(_ raw: String, fallbackFileName: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return (fallbackFileName as NSString).deletingPathExtension
    }
}
