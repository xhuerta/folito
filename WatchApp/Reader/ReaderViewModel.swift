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
    @Published private(set) var remoteOffer: ReadingPosition?
    @Published private(set) var currentIndex: Int

    let startIndex: Int

    /// While true (initial restore / programmatic jumps) scroll callbacks do not overwrite the saved position.
    private var isRestoring = true
    private var restoreTask: Task<Void, Never>?
    private var lastReportedIndex: Int?

    private let positions: PositionStore
    private let sync: SyncCoordinator
    private let resolver: XPointerResolving
    /// Complications / Smart Stack snapshot writer; nil in previews and most tests.
    private let complications: ComplicationPublisher?
    let dictionary: DictionaryProviding

    init(book: ProcessedBook, positions: PositionStore, sync: SyncCoordinator,
         resolver: XPointerResolving = XPointerResolver(),
         dictionary: DictionaryProviding = MockDictionaryProvider.sample,
         complications: ComplicationPublisher? = nil) {
        self.book = book
        self.complications = complications
        self.dictionary = dictionary
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
    /// Every id a sync connector may need (KOReader partial MD5, Readest meta hash, title, authors).
    var bookIdentity: BookIdentity {
        BookIdentity(partialMD5: book.documentHash, metaHash: book.metaHash.isEmpty ? nil : book.metaHash,
                     title: book.metadata.title, authors: book.metadata.authors)
    }
    var title: String { book.metadata.title }
    /// BCP-47 language of the book (dictionary language); nil when the EPUB does not declare one.
    var bookLanguage: String? { book.metadata.language }

    /// Block shown in the word-lookup sheet.
    @Published var lookupBlockIndex: LookupTarget?

    struct LookupTarget: Identifiable, Equatable {
        let index: Int
        var id: Int { index }
    }

    func beginLookup(at index: Int) {
        guard !flat.isEmpty else { return }
        lookupBlockIndex = LookupTarget(index: flat.clamped(index))
    }

    /// Re-aligns the scroll view with the block we were reading after the layout changed (typography).
    /// Does not change the saved position.
    func reanchor() {
        guard !flat.isEmpty else { return }
        beginRestore()
        jumpRequest = JumpRequest(index: currentIndex)
    }

    // MARK: Visibility / persistence

    /// Receives the frames of the currently instantiated blocks (scroll-view coordinate space).
    func blockFramesChanged(_ frames: [Int: BlockFrame]) {
        guard !isRestoring, let top = VisibleBlockResolver.topIndex(frames: frames),
              top != currentIndex, top < flat.count else { return }
        currentIndex = top
        persistCurrent()
    }

    private func persistCurrent() {
        guard let pos = flat.position(at: currentIndex) else { return }
        positions.save(StoredPosition(position: pos, percentage: flat.percentage(at: currentIndex)),
                       for: documentHash)
        publishComplication(force: false)
    }

    // MARK: Complications

    /// What the complications show for the current position.
    var complicationSnapshot: ReadingSnapshot {
        let chapter = flat.chapterRefIndex(containing: currentIndex).map { flat.chapterRefs[$0].title }
        return ReadingSnapshot(bookID: documentHash, title: title, chapterTitle: chapter,
                               fraction: flat.percentage(at: currentIndex),
                               minutesLeft: minutesLeftInChapter())
    }

    /// Estimated minutes left in the current chapter, shown by the rectangular complication / Smart Stack.
    ///
    /// PLUG-IN POINT for the time-remaining estimator (branch feat/time-remaining): return its estimate for
    /// the rest of the chapter containing `currentIndex`. This is the only place the complications get it from;
    /// nil hides the line.
    func minutesLeftInChapter() -> Int? {
        nil
    }

    private func publishComplication(force: Bool) {
        guard !flat.isEmpty else { return }
        complications?.publish(complicationSnapshot, force: force)
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
        // The opened book becomes the one the complications show.
        publishComplication(force: false)
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
        let decision = await sync.decisionOnOpen(book: bookIdentity, localPercentage: localPercentage)
        if case .offerRemote(let remote) = decision {
            remoteOffer = remote
            showRemoteOffer = true
        }
    }

    func acceptRemote() {
        guard let remote = remoteOffer else { return }
        remoteOffer = nil
        let target: Int
        switch resolver.resolve(remote.xpointer, percentage: remote.percentage, in: book) {
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
        sync.report(book: bookIdentity,
                    xpointer: flat.blocks[currentIndex].xpointer,
                    percentage: flat.percentage(at: currentIndex),
                    page: currentIndex + 1, pageCount: flat.count,
                    immediately: immediately)
    }

    func leave() {
        restoreTask?.cancel()
        reportProgress(immediately: true)
        // Closing the book: always refresh the complications with the final position.
        publishComplication(force: true)
    }
}
