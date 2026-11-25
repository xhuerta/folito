import Foundation
import ReaderCore

/// What the Library's search, sort and browse (#114, `LibraryBrowsing` in ReaderCore) know about a row: a local
/// book (with its Readest row, if any) or a book only in Readest.
enum LibraryBrowseFacts {
    /// `readStatus` is the status the row shows (the newer of the local mark and the Readest row's).
    static func facts(_ item: MergedLibraryItem<LibraryEntry>, readStatus: ReadStatusMark?) -> LibraryBookFacts {
        let statusDate = readStatus.flatMap(date(of:))
        if let entry = item.local {
            return LibraryBookFacts(
                title: entry.title, authors: authors(of: entry),
                // The EPUB's series; a book whose EPUB has none takes its Readest row's.
                series: entry.details?.series ?? item.cloud?.series,
                addedAt: entry.importedAt,
                lastReadAt: newest([entry.lastReadAt, statusDate, item.cloud?.updatedAt]),
                isFinished: readStatus?.isFinished == true)
        }
        guard let book = item.cloud else { return LibraryBookFacts(title: "") }
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryBookFacts(
            title: book.title, authors: author.isEmpty ? [] : [author],
            series: book.series,
            addedAt: book.createdAt ?? book.uploadedAt,
            lastReadAt: newest([book.updatedAt, statusDate]),
            isFinished: readStatus?.isFinished == true)
    }

    /// The EPUB's authors; else the row's author line, unless it is the "Unknown author" placeholder.
    static func authors(of entry: LibraryEntry) -> [String] {
        let listed = (entry.details?.authors ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !listed.isEmpty { return listed }
        let line = entry.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty || line == BookDisplay.author(from: []) ? [] : [line]
    }

    /// When a status was set (nil for the stamp 0 of a status without a time).
    private static func date(of mark: ReadStatusMark) -> Date? {
        mark.stamp > 0 ? Date(timeIntervalSince1970: Double(mark.stamp) / 1000) : nil
    }

    private static func newest(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }
}
