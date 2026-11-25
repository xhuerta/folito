import Foundation
import ReaderCore

/// Which book the "Continue Reading" App Intent (Siri, Shortcuts, the Action button, Smart Stack suggestions)
/// opens, and how the "Open Book" intent finds books (#68). Pure logic: the intents themselves live in
/// `WatchApp/Intents/`, which only reads the stores and hands the result to `IntentRouter`.
enum ContinueReadingResolver {
    /// The book to continue.
    ///
    /// - `snapshot`: the reader's own complication snapshot, i.e. the book last read on this watch.
    /// - `entries`: the watch library (any order).
    /// - `progress`: the locally saved fraction read of a book (nil: never opened).
    ///
    /// The snapshot's book wins while it is still in the library (also when it is marked Finished: it is what the
    /// complications show and what a tap on them opens). Without one (first launch after an update, the book was
    /// deleted, Settings › Reset), the newest book that was started and is not finished. Nil when nothing qualifies.
    static func book(snapshot: ReadingSnapshot?, entries: [LibraryEntry],
                     progress: (String) -> Double?) -> LibraryEntry? {
        if let id = snapshot?.bookID, let entry = entries.first(where: { $0.documentHash == id }) {
            return entry
        }
        return entries
            .sorted { $0.addedAt > $1.addedAt }
            .first { !$0.isFinished && (progress($0.documentHash) ?? 0) > 0 }
    }

    /// The deep link the intent opens: the book (at its saved position, like a complication tap), or the library.
    static func deepLink(for entry: LibraryEntry?) -> FolitoDeepLink {
        guard let entry, FolitoDeepLink.isValidBookID(entry.documentHash) else { return .library }
        return .book(id: entry.documentHash)
    }
}

/// The books the "Open Book" intent offers and finds (its `EntityStringQuery`).
enum BookEntityLookup {
    /// Suggested books: the Library order (newest first, finished books last).
    static func suggested(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        ReadStatusRules.finishedLast(entries.sorted { $0.addedAt > $1.addedAt }) { $0.isFinished }
    }

    /// The books with these ids, in the order asked; unknown ids (a deleted book) are dropped.
    static func entries(for identifiers: [String], in entries: [LibraryEntry]) -> [LibraryEntry] {
        identifiers.compactMap { id in entries.first { $0.documentHash == id } }
    }

    /// Books whose title or author contains every word of `query`, ignoring case, diacritics and width
    /// ("bronte" finds "Jane Eyre" by Charlotte Brontë). An empty query matches every book. Library order.
    static func matching(_ query: String, in entries: [LibraryEntry]) -> [LibraryEntry] {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard !words.isEmpty else { return suggested(entries) }
        return suggested(entries).filter { entry in
            let haystack = "\(entry.title) \(entry.author)"
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }
}

/// Hands deep links from App Intents to the app's UI (`AppEnvironment.deepLink`, consumed by `LibraryView`, the
/// same path as a complication tap). An intent can run while the app is still launching, before the environment
/// exists: the link waits here until `attach` is called.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()

    private var handler: ((FolitoDeepLink) -> Void)?
    /// The latest link sent before a handler was attached (only the last one matters).
    private(set) var pending: FolitoDeepLink?

    func open(_ link: FolitoDeepLink) {
        if let handler {
            handler(link)
        } else {
            pending = link
        }
    }

    /// Installs the receiver and delivers a link that arrived before it.
    func attach(_ handler: @escaping (FolitoDeepLink) -> Void) {
        self.handler = handler
        if let link = pending {
            pending = nil
            handler(link)
        }
    }
}
