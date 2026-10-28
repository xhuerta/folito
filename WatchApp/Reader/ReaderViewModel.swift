import Foundation
import SwiftUI
import ReaderCore

/// Reader state: current block, persistence, and sync policy. UI-agnostic apart from SwiftUI's
/// ObservableObject so it can be driven from previews with mocks.
@MainActor
final class ReaderViewModel: ObservableObject {
    struct JumpRequest: Equatable {
        let token = UUID()
        let index: Int
    }

    let book: ProcessedBook
    let flat: FlatBook

    @Published var jumpRequest: JumpRequest?
    @Published var showRemoteOffer = false
    @Published private(set) var remoteOffer: KOSyncProgress?
    @Published private(set) var currentIndex: Int

    let startIndex: Int

    private var tracker = VisibleTracker()
    /// While true (initial restore / programmatic jumps) scroll callbacks do not overwrite the saved position.
    private var isRestoring = true
    private var restoreTask: Task<Void, Never>?
    private var lastReportedIndex: Int?

    private let positions: PositionStore
    private let sync: SyncCoordinator
    private let resolver: XPointerResolving

    init(book: ProcessedBook, positions: PositionStore, sync: SyncCoordinator,
         resolver: XPointerResolving = XPointerResolver()) {
        self.book = book
        let flat = FlatBook(book)
        self.flat = flat
        self.positions = positions
        self.sync = sync
        self.resolver = resolver
        let saved = positions.load(book.documentHash)
        let start = saved.flatMap { flat.flatIndex(for: $0.position) } ?? 0
        self.startIndex = start
        self.currentIndex = start
        // Merely opening a book must not PUT its (possibly 0%) start position: if the open-time GET
        // failed or the user declined the remote offer, that would overwrite real remote progress.
        // Only report once the reader actually moves.
        self.lastReportedIndex = start
    }

    var documentHash: String { book.documentHash }
    var title: String { book.metadata.title }

    // MARK: Visibility / persistence

    func blockAppeared(_ index: Int) {
        tracker.appeared(index)
        visibleChanged()
    }

    func blockDisappeared(_ index: Int) {
        tracker.disappeared(index)
        visibleChanged()
    }

    private func visibleChanged() {
        guard !isRestoring, let top = tracker.top, top != currentIndex else { return }
        currentIndex = top
        persistCurrent()
    }

    private func persistCurrent() {
        guard let pos = flat.position(at: currentIndex) else { return }
        positions.save(StoredPosition(position: pos, percentage: flat.percentage(at: currentIndex)),
                       for: documentHash)
    }

    /// Suppresses position updates while the scroll view settles after a programmatic scroll.
    private func beginRestore() {
        isRestoring = true
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.isRestoring = false
        }
    }

    /// Called by the view once it appeared: scroll to the saved block.
    func restoreInitialPosition() {
        beginRestore()
        jumpRequest = JumpRequest(index: startIndex)
    }

    func jump(to index: Int) {
        let i = flat.clamped(index)
        beginRestore()
        currentIndex = i
        persistCurrent()
        jumpRequest = JumpRequest(index: i)
    }

    // MARK: Sync

    var localPercentage: Double { flat.percentage(at: currentIndex) }

    func syncOnOpen() async {
        let decision = await sync.decisionOnOpen(document: documentHash, localPercentage: localPercentage)
        if case .offerRemote(let remote) = decision {
            remoteOffer = remote
            showRemoteOffer = true
        }
    }

    func acceptRemote() {
        guard let remote = remoteOffer else { return }
        remoteOffer = nil
        let target: Int
        switch resolver.resolve(remote.progress, percentage: remote.percentage, in: book) {
        case .position(let pos, _)?:
            target = flat.flatIndex(for: pos) ?? flat.index(forPercentage: remote.percentage)
        case .percentage(let p)?:
            target = flat.index(forPercentage: p)
        case nil:
            target = flat.index(forPercentage: remote.percentage)
        }
        // The remote position is now our baseline: no need to echo it back.
        lastReportedIndex = flat.clamped(target)
        jump(to: target)
    }

    func declineRemote() { remoteOffer = nil }

    /// Records the current position for syncing. No-op if nothing changed since the last report.
    func reportProgress(immediately: Bool) {
        guard !flat.isEmpty, lastReportedIndex != currentIndex else { return }
        lastReportedIndex = currentIndex
        sync.report(document: documentHash,
                    xpointer: flat.blocks[currentIndex].xpointer,
                    percentage: flat.percentage(at: currentIndex),
                    immediately: immediately)
    }

    func leave() {
        restoreTask?.cancel()
        reportProgress(immediately: true)
    }
}
