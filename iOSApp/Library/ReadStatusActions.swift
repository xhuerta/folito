import Foundation
import ReaderCore

/// "Mark as Finished" / "Mark as Unread" from the Library row and the book details (issue #113).
@MainActor
enum ReadStatusActions {
    /// The status the Library shows for a local book: its own mark, or the paired Readest row's when newer.
    static func mark(of entry: LibraryEntry, cloud: ReadestCloudBook?) -> ReadStatusMark? {
        ReadStatusMerge.newer(entry.readStatus, cloud?.readStatusMark)
    }

    /// Sets a local book's status (stamped newer than what is shown), sends it to the watch through
    /// `LibraryStore.onReadStatusChanged`, and writes it to the book's Readest row when it has one.
    static func set(_ status: ReadStatus, entry: LibraryEntry, cloud: ReadestCloudBook?,
                    library: LibraryStore, readest: ReadestLibraryModel?) {
        let newMark = ReadStatusRules.mark(status, now: Date(), replacing: mark(of: entry, cloud: cloud))
        guard library.setReadStatus(newMark, hash: entry.documentHash) else { return }
        Announcer.announce(ReadestLibraryModel.statusAnnouncement(status, title: entry.title))
        if cloud != nil, let readest {
            Task { await readest.reconcileReadStatus(in: library) }
        }
    }

    /// Title of the menu toggle: "Mark as Unread" for a finished book, else "Mark as Finished".
    static func toggleTitle(isFinished: Bool) -> String {
        isFinished
            ? String(localized: "Mark as Unread", comment: "Book action: clear the Finished status")
            : String(localized: "Mark as Finished", comment: "Book action: mark the book as read to the end")
    }

    static func toggleImage(isFinished: Bool) -> String {
        isFinished ? "circle" : "checkmark.circle"
    }
}
