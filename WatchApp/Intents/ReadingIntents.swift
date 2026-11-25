import AppIntents
import Foundation

// App Intents of the watch app (#68): "Continue Reading" and "Open Book", for Siri, the Shortcuts app, the Action
// button on Apple Watch Ultra and Smart Stack suggestions. Both open the app and go through the complications'
// deep links (`FolitoDeepLink`), so the book opens at its saved position exactly as after a complication tap.
// Nothing here leaves the watch: the library and the snapshot are read from this watch's own storage.

/// What the intents read: the library index and the book last read on this watch. Read from disk on each call,
/// so it works while the app is launching (an intent may run before `AppEnvironment` exists).
struct IntentLibrary {
    var entries: [LibraryEntry]
    var snapshot: ReadingSnapshot?
    var progress: (String) -> Double?

    static func load() -> IntentLibrary {
        let positions = PositionStore()
        return IntentLibrary(entries: BookStorage().loadIndex(),
                             snapshot: ComplicationPublisher.storedLocalSnapshot(),
                             progress: { positions.load($0)?.percentage })
    }

    var continueTarget: LibraryEntry? {
        ContinueReadingResolver.book(snapshot: snapshot, entries: entries, progress: progress)
    }
}

/// "Continue reading in Folito": opens the current book at its saved position, or the library (with a short
/// explanation) when no book is in progress.
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription("Opens the book you are reading at your saved position.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = IntentLibrary.load()
        let entry = library.continueTarget
        IntentRouter.shared.open(ContinueReadingResolver.deepLink(for: entry))
        guard let entry else {
            let answer = library.entries.isEmpty
                ? LocalizedStringResource("There are no books on this watch yet. Add books in the Folito app on your iPhone.",
                                          comment: "Siri / Shortcuts answer to Continue Reading when the watch library is empty")
                : LocalizedStringResource("No book in progress. Choose one in your library.",
                                          comment: "Siri / Shortcuts answer to Continue Reading when no book has been started; the library opens")
            return .result(dialog: IntentDialog(answer))
        }
        let answer = LocalizedStringResource("Opening \u{201C}\(entry.title)\u{201D}.",
                                             comment: "Siri / Shortcuts answer to Continue Reading while the book opens. The argument is the book title.")
        return .result(dialog: IntentDialog(answer))
    }
}

/// "Open <book> in Folito": opens a book of the watch library at its saved position.
struct OpenBookIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Book"
    static let description = IntentDescription("Opens a book from your library at its saved position.")

    @Parameter(title: "Book")
    var target: BookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = IntentLibrary.load()
        let entry = BookEntityLookup.entries(for: [target.id], in: library.entries).first
        IntentRouter.shared.open(ContinueReadingResolver.deepLink(for: entry))
        return .result()
    }
}

/// A book of the watch library, as Siri and the Shortcuts app see it.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static let defaultQuery = BookEntityQuery()

    /// The book's documentHash (the id of `folito://book/<id>`).
    let id: String
    let title: String
    let author: String

    init(_ entry: LibraryEntry) {
        id = entry.documentHash
        title = entry.title
        author = entry.author
    }

    // Book titles and authors are data, shown as they are (not looked up in the strings catalog).
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title),
                              subtitle: author.isEmpty ? nil : LocalizedStringResource(stringLiteral: author))
    }
}

struct BookEntityQuery: EntityStringQuery {
    func entities(for identifiers: [BookEntity.ID]) async throws -> [BookEntity] {
        BookEntityLookup.entries(for: identifiers, in: IntentLibrary.load().entries).map(BookEntity.init)
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        BookEntityLookup.matching(string, in: IntentLibrary.load().entries).map(BookEntity.init)
    }

    func suggestedEntities() async throws -> [BookEntity] {
        BookEntityLookup.suggested(IntentLibrary.load().entries).map(BookEntity.init)
    }
}

/// App Shortcuts: available in Siri and the Shortcuts app as soon as the app is installed, no setup needed.
/// The phrases are localized in `WatchApp/Resources/AppShortcuts.xcstrings`; every phrase names the app.
struct FolitoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueReadingIntent(),
                    phrases: ["Continue reading in \(.applicationName)",
                              "Resume my book in \(.applicationName)"],
                    shortTitle: "Continue Reading",
                    systemImageName: "book")
        AppShortcut(intent: OpenBookIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)",
                              "Read \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Book",
                    systemImageName: "books.vertical")
    }
}

/// Relevance hints (#68): the Smart Stack and Siri Suggestions learn from donations when "Continue Reading" is
/// useful (for example the time of day the user usually reads). The reading-progress widget adds its own
/// timeline relevance (`SmartStackRelevance`). Donations stay on the device.
enum ReadingIntentSignals {
    /// A book was opened in the reader.
    static func bookOpened() {
        Task {
            _ = try? await IntentDonationManager.shared.donate(intent: ContinueReadingIntent())
        }
    }

    /// The library changed: Siri re-reads the book titles the "Open <book>" phrases accept.
    static func libraryChanged() {
        FolitoShortcuts.updateAppShortcutParameters()
    }
}
