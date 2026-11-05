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
    /// Word counts per block for the time-remaining estimate; built off the main actor after opening.
    @Published private(set) var lengths: BookLengthIndex?
    private let speeds: ReadingSpeedStore
    private let times: ReadingTimeStore
    private var speed: ReadingSpeed
    private var pageTimer: PageTimer
    /// Clock for the page timer (injectable for tests).
    private let now: () -> Date
    private let resolver: XPointerResolving
    /// Complications / Smart Stack snapshot writer; nil in previews and most tests.
    private let complications: ComplicationPublisher?
    /// Where the *Show Time Remaining* setting lives (the app's `@AppStorage` uses `.standard`).
    private let settings: UserDefaults
    let dictionary: DictionaryProviding

    init(book: ProcessedBook, positions: PositionStore, sync: SyncCoordinator,
         resolver: XPointerResolving = XPointerResolver(),
         dictionary: DictionaryProviding = MockDictionaryProvider.sample,
         speeds: ReadingSpeedStore? = nil,
         times: ReadingTimeStore? = nil,
         now: @escaping () -> Date = { Date() },
         complications: ComplicationPublisher? = nil,
         settings: UserDefaults = .standard) {
        self.book = book
        self.complications = complications
        self.settings = settings
        // By default next to the positions (same UserDefaults), so Reset and deleting a book clear them too.
        let speeds = speeds ?? positions.readingSpeed
        self.speeds = speeds
        self.times = times ?? positions.readingTimes
        self.now = now
        self.speed = speeds.load()
        self.pageTimer = PageTimer(start: now())
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
        // Counting the words of a whole book takes a moment on the watch: do it off the main actor.
        Task.detached(priority: .utility) { [weak self] in
            let index = BookLengthIndex(book: book)
            await self?.lengthsReady(index)
        }
    }

    private func lengthsReady(_ index: BookLengthIndex) {
        lengths = index
        saveTimeRemaining()
        // The snapshot published on open had no estimate yet: refresh it now that minutes left are known.
        publishComplication(force: false)
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
        pageTimer.reset(at: now())
        lookupBlockIndex = LookupTarget(index: flat.clamped(index))
    }

    /// Re-aligns the scroll view with the block we were reading after the layout changed (typography).
    /// Does not change the saved position.
    func reanchor() {
        guard !flat.isEmpty else { return }
        // Time in the menu or a lookup is not reading time.
        pageTimer.reset(at: now())
        beginRestore()
        jumpRequest = JumpRequest(index: currentIndex)
    }

    // MARK: Visibility / persistence

    /// Receives the frames of the currently instantiated blocks (scroll-view coordinate space).
    func blockFramesChanged(_ frames: [Int: BlockFrame]) {
        guard !isRestoring, let top = VisibleBlockResolver.topIndex(frames: frames),
              top != currentIndex, top < flat.count else { return }
        learnSpeed(from: currentIndex, to: top)
        currentIndex = top
        persistCurrent()
    }

    /// Scrolling forward past blocks feeds the page timer; going back starts a new page without a sample.
    private func learnSpeed(from old: Int, to new: Int) {
        let date = now()
        guard new > old, let lengths else { pageTimer.reset(at: date); return }
        if let learned = pageTimer.advance(by: lengths.length(from: old, to: new), at: date, speed: speed) {
            speed = learned
            speeds.save(learned)
        }
    }

    private func persistCurrent() {
        guard let pos = flat.position(at: currentIndex) else { return }
        positions.save(StoredPosition(position: pos, percentage: flat.percentage(at: currentIndex)),
                       for: documentHash)
        saveTimeRemaining()
        publishComplication(force: false)
    }

    // MARK: Time remaining

    /// Time left from the block at the top of the screen; nil until the words are counted or for an empty book.
    var timeRemaining: ReadingTimeRemaining? {
        guard let lengths, !flat.isEmpty, lengths.blockCount == flat.count else { return nil }
        let estimate = ReadingTimeEstimator.estimate(lengths, atBlock: currentIndex, speed: speed)
        return ReadingTimeRemaining(documentHash: documentHash, bookTitle: title,
                                    chapterSeconds: estimate.chapter, bookSeconds: estimate.book,
                                    fractionRead: flat.percentage(at: currentIndex), updatedAt: now())
    }

    /// Saved with the reading position, for the iPhone library (`ReadingTimeStore`).
    private func saveTimeRemaining() {
        if let value = timeRemaining { times.save(value) }
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
    /// Same estimate as the reader's time-remaining line (`timeRemaining.chapterSeconds`, rounded with
    /// `ReadingTimeEstimator.displayMinutes`). Nil, which hides the line, while the words are still being
    /// counted or when the user turned off *Show Time Remaining* in Settings.
    func minutesLeftInChapter() -> Int? {
        guard showsTimeRemaining, let remaining = timeRemaining else { return nil }
        // At least 1, like the reader's line ("1 min left"), so the end of a chapter never reads "0 min".
        return max(ReadingTimeEstimator.displayMinutes(remaining.chapterSeconds), 1)
    }

    /// The *Show Time Remaining* setting (on by default).
    private var showsTimeRemaining: Bool {
        settings.object(forKey: ReaderSettings.showTimeRemainingKey) as? Bool ?? true
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
        pageTimer.reset(at: now())
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
