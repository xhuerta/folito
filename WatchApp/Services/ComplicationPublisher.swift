import Foundation
import WidgetKit

/// Writes the reading snapshot the complications show (App Group, `ReadingSnapshotStore`) and asks WidgetKit to
/// reload them. Called by the reader whenever it saves the reading position and when the book is closed.
///
/// The reader saves the position on every scroll step, so the timeline is reloaded only when something the
/// complication displays changed (whole percent, title, chapter, minutes left) or when the book is closed.
@MainActor
final class ComplicationPublisher {
    private let store: ReadingSnapshotStore
    private let reload: () -> Void
    private var lastReloaded: ReadingSnapshot?

    init(store: ReadingSnapshotStore,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: ComplicationKind.readingProgress) }) {
        self.store = store
        self.reload = reload
        self.lastReloaded = store.load()
    }

    /// Stores the snapshot; reloads the complications if it looks different, or always with `force`.
    func publish(_ snapshot: ReadingSnapshot, force: Bool = false) {
        store.save(snapshot)
        guard force || snapshot.differsVisibly(from: lastReloaded) else { return }
        lastReloaded = snapshot
        reload()
    }

    /// The book shown by the complications was deleted: back to the "Start reading" placeholder.
    func bookRemoved(_ bookID: String) {
        guard store.load()?.bookID == bookID else { return }
        clear()
    }

    func clear() {
        store.clear()
        lastReloaded = nil
        reload()
    }
}
