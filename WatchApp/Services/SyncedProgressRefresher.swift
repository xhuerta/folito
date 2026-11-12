import Foundation
import ReaderCore

/// Keeps the complications, the Smart Stack and the watch Library current when the book is read elsewhere
/// (#132). On launch, on foreground and in watchOS background refresh it asks the active sync service for the
/// position of the book the complications show (one GET, only while sync is on). A position ahead of the
/// local one, not this watch's own and not declined, is stored as the synced position and shown; the reader
/// is not moved: opening the book still offers "Continue where you left off?".
@MainActor
final class SyncedProgressRefresher {
    /// Identifier of the scheduled background refresh (`.backgroundTask(.appRefresh(...))`).
    static let taskID = "folito.syncedProgress"
    /// How long after a refresh the next one is asked for. watchOS allows a few per hour for an app with a
    /// complication on the face and decides the actual time.
    static let backgroundInterval: TimeInterval = 20 * 60
    /// Launch and foreground arrive together: refreshes closer than this are skipped.
    static let minInterval: TimeInterval = 60

    private let sync: SyncCoordinator
    private let complications: ComplicationPublisher
    private let positions: PositionStore
    /// Places a Readest CFI in the book (loads it); called only when the row carries a CFI.
    private let resolveCFI: @MainActor (String, ReadingPosition) async -> ReadingPosition
    /// Called after the synced position of a book changed (the Library re-reads its percentages).
    var onChange: (() -> Void)?
    private let now: () -> Date
    private var lastRefresh: Date?
    private var running = false

    init(sync: SyncCoordinator, complications: ComplicationPublisher, positions: PositionStore,
         resolveCFI: @escaping @MainActor (String, ReadingPosition) async -> ReadingPosition = { $1 },
         now: @escaping () -> Date = { Date() }) {
        self.sync = sync
        self.complications = complications
        self.positions = positions
        self.resolveCFI = resolveCFI
        self.now = now
    }

    /// Fetches and applies the remote position of the complications' book. Returns nil when nothing was
    /// asked (no book shown, a refresh just ran or is running). `force` skips the `minInterval` check
    /// (background refresh: the system already spaces them).
    @discardableResult
    func refresh(force: Bool = false) async -> SyncCoordinator.SyncedRefresh? {
        guard !running, let shown = complications.local else { return nil }
        if !force, let last = lastRefresh, now().timeIntervalSince(last) < Self.minInterval { return nil }
        running = true
        lastRefresh = now()
        defer { running = false }
        let bookID = shown.bookID
        let book = sync.remoteMemory.identity(for: bookID) ?? BookIdentity(partialMD5: bookID, title: shown.title)
        let localFraction = positions.load(bookID)?.percentage ?? shown.fraction
        let local = ReadingPosition(xpointer: "", percentage: localFraction)
        let resolveCFI = self.resolveCFI
        let result = await sync.refreshSynced(book: book, local: local, resolveRemote: { raw in
            raw.cfi == nil ? raw : await resolveCFI(bookID, raw)
        })
        switch result {
        case .ahead(let synced):
            complications.showSynced(synced, bookID: bookID)
        case .nothing, .off:
            complications.showSynced(nil, bookID: bookID)
        case .failed:
            break
        }
        if result != .failed { onChange?() }
        return result
    }
}
