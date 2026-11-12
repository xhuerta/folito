import Foundation
import WidgetKit
import ReaderCore

/// Writes the reading snapshot the complications show (App Group, `ReadingSnapshotStore`) and asks WidgetKit to
/// reload them. Called by the reader whenever it saves the reading position and when the book is closed, and
/// by `SyncedProgressRefresher` when the sync service holds a newer position for that book (#132).
///
/// The reader saves the position on every scroll step, so the timeline is reloaded only when something the
/// complication displays changed (whole percent, title, chapter, minutes left) or when the book is closed.
@MainActor
final class ComplicationPublisher {
    /// What the complications show (App Group).
    private let store: ReadingSnapshotStore
    /// The reader's own snapshot, kept so the complications can go back to it after a synced one.
    private let localStore: ReadingSnapshotStore
    private let reload: () -> Void
    private var lastReloaded: ReadingSnapshot?

    init(store: ReadingSnapshotStore,
         localStore: ReadingSnapshotStore = ReadingSnapshotStore(defaults: nil),
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: ComplicationKind.readingProgress) }) {
        self.store = store
        self.localStore = localStore
        self.reload = reload
        self.lastReloaded = store.load()
    }

    /// What the complications show now.
    var current: ReadingSnapshot? { store.load() }

    /// The reader's snapshot for the book the complications show (falls back to what they show).
    var local: ReadingSnapshot? { localStore.load() ?? store.load() }

    /// Stores the snapshot; reloads the complications if it looks different, or always with `force`.
    func publish(_ snapshot: ReadingSnapshot, force: Bool = false) {
        localStore.save(snapshot)
        show(snapshot, force: force)
    }

    private func show(_ snapshot: ReadingSnapshot, force: Bool) {
        store.save(snapshot)
        guard force || snapshot.differsVisibly(from: lastReloaded) else { return }
        lastReloaded = snapshot
        reload()
    }

    /// Shows `synced` (a remote position ahead of the local one) for `bookID`, or the reader's own snapshot
    /// when `synced` is nil or not ahead. No-op when the complications show another book.
    func showSynced(_ synced: ReadingPosition?, bookID: String) {
        guard let base = local, base.bookID == bookID else { return }
        let merged = Self.merged(base, synced: synced)
        guard merged != store.load() else { return }
        show(merged, force: false)
    }

    /// What the complications show for the reader's snapshot `local` and a synced position: the synced
    /// fraction when it is ahead by more than `tolerance` (the open-time offer's threshold), otherwise
    /// `local` unchanged. The synced snapshot carries the service's chapter title (often none) and no
    /// minutes left: both belong to the local position.
    nonisolated static func merged(_ local: ReadingSnapshot, synced: ReadingPosition?,
                                   tolerance: Double = 0.005) -> ReadingSnapshot {
        guard let synced, synced.percentage.isFinite, synced.percentage - local.fraction > tolerance else {
            return local
        }
        return ReadingSnapshot(bookID: local.bookID, title: local.title, chapterTitle: synced.chapter,
                               fraction: synced.percentage, minutesLeft: nil,
                               updatedAt: synced.timestamp ?? local.updatedAt)
    }

    /// The book shown by the complications was deleted: back to the "Start reading" placeholder.
    func bookRemoved(_ bookID: String) {
        guard store.load()?.bookID == bookID else { return }
        clear()
    }

    func clear() {
        store.clear()
        localStore.clear()
        lastReloaded = nil
        reload()
    }
}
