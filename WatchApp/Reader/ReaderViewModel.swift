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
        /// Vertical `UnitPoint` anchor for `scrollTo`; nil scrolls the block's top to the top (`.top`).
        var anchorY: Double? = nil
    }

    /// A block and a character offset inside it.
    private struct Spot: Equatable {
        var index: Int
        var offset: Int
    }

    let book: ProcessedBook
    let flat: FlatBook

    @Published var jumpRequest: JumpRequest?
    @Published var showRemoteOffer = false
    @Published private(set) var remoteOffer: ReadingPosition?
    @Published private(set) var currentIndex: Int
    /// Character offset inside `currentIndex` of the line at the top edge (not published: it changes on
    /// every line scrolled and nothing on screen shows it).
    private(set) var currentOffset: Int

    let startIndex: Int
    let startOffset: Int

    /// While true (initial restore / programmatic jumps) scroll callbacks do not overwrite the saved position,
    /// and the view tells `BarAutoHide` that offset changes are programmatic, not reading (#125).
    @Published private(set) var isRestoring = true
    /// False until the opening restore has brought the saved line to the top edge. The view keeps the
    /// text transparent until then, so the book appears already at the saved line instead of first at the
    /// top of the saved block and, a moment later, at the line inside it (#125).
    @Published private(set) var isPositioned = false
    private var restoreTask: Task<Void, Never>?
    /// Block the current restore / jump must bring to the top, and how many times it was re-issued.
    private var restoreTarget: Int?
    private var restoreAttempts = 0
    /// Character offset inside `restoreTarget` the jump must bring to the top edge, the anchor last used
    /// for it, and how many times it was corrected.
    private var restoreOffset = 0
    private var restoreAnchor: Double?
    private var inBlockAttempts = 0
    /// Latest frames reported by the view, kept while restoring to verify where the jump landed.
    private var lastFrames: [Int: BlockFrame] = [:]
    /// Top of the visible area in the scroll view's coordinate space (the inset under the navigation
    /// bar when the scroll view extends beneath it). Set by the view.
    var viewportTop: CGFloat = 0
    /// Height of the scroll view (set by the view); used to compute in-block `scrollTo` anchors.
    var viewportHeight: CGFloat = 0
    /// Pause before checking where a programmatic jump landed (injectable for tests).
    var settleDelay: UInt64 = 700_000_000
    /// The same pause while the book opens. Shorter: the text is still hidden then, so a check that comes
    /// before the lazy layout settled only costs a re-issued jump nobody sees, and the hidden time stays
    /// short (at most `2 * RestoreCheck.maxRetries + 1` checks).
    var openSettleDelay: UInt64 = 200_000_000
    private var lastReported: Spot?

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
        let (start, startOffset) = Self.openPosition(saved: positions.load(book.documentHash), in: flat)
        self.startIndex = start
        self.startOffset = startOffset
        self.currentIndex = start
        self.currentOffset = startOffset
        // Merely opening a book must not PUT its (possibly 0%) start position: if the open-time GET
        // failed or the user declined the remote offer, that would overwrite real remote progress.
        // Only report once the reader actually moves.
        self.lastReported = Spot(index: start, offset: startOffset)
        // Counting the words of a whole book takes a moment on the watch: do it off the main actor.
        Task.detached(priority: .utility) { [weak self] in
            let index = BookLengthIndex(book: book)
            await self?.lengthsReady(index)
        }
    }

    /// Where a book opens: the saved block and the character offset of the saved line in it. Old
    /// block-only positions decode with offset 0. An offset is only kept for the block it was saved in (a
    /// clamped, out-of-range position starts at its block's top).
    static func openPosition(saved: StoredPosition?, in flat: FlatBook) -> (index: Int, offset: Int) {
        let start = saved.flatMap { flat.flatIndex(for: $0.position) } ?? 0
        var offset = 0
        if let p = saved?.position, let mapped = flat.position(at: start),
           mapped.chapterIndex == p.chapterIndex, mapped.blockIndex == p.blockIndex {
            offset = flat.clampedOffset(p.characterOffset, in: start)
        }
        return (start, offset)
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
        /// Character offset in the block's text where the word picker starts (nil: the first word).
        var characterOffset: Int? = nil
        var id: Int { index }
    }

    func beginLookup(at index: Int, characterOffset: Int? = nil) {
        guard !flat.isEmpty else { return }
        pageTimer.reset(at: now())
        lookupBlockIndex = LookupTarget(index: flat.clamped(index), characterOffset: characterOffset)
    }

    /// Last measured frame of a block, if it is laid out.
    func frame(ofBlock index: Int) -> BlockFrame? { lastFrames[index] }

    /// Last measured frames of the instantiated blocks (scroll-view coordinate space).
    var blockFrames: [Int: BlockFrame] { lastFrames }

    /// Re-aligns the scroll view with the block we were reading after the layout changed (typography).
    /// Does not change the saved position.
    func reanchor() {
        guard !flat.isEmpty else { return }
        // Time in the menu or a lookup is not reading time.
        pageTimer.reset(at: now())
        beginRestore(target: currentIndex, offset: currentOffset)
        jumpRequest = JumpRequest(index: currentIndex, anchorY: restoreAnchor)
    }

    // MARK: Visibility / persistence

    /// Receives the frames of the currently instantiated blocks (scroll-view coordinate space).
    ///
    /// The position is the line at the viewport's top edge: the top block plus the character offset of
    /// the part of it scrolled past that edge.
    func blockFramesChanged(_ frames: [Int: BlockFrame]) {
        lastFrames = frames
        guard !isRestoring, let top = VisibleBlockResolver.topIndex(frames: frames, viewportTop: viewportTop),
              top < flat.count, let frame = frames[top] else { return }
        let text = flat.blocks[top].text
        let fraction = InBlockPosition.fractionScrolledPast(minY: Double(frame.minY), maxY: Double(frame.maxY),
                                                           viewportTop: Double(viewportTop))
        guard top != currentIndex else {
            // Still within the saved line (layout rounding, the settle after a restore): keep the offset,
            // so reopening never creeps back a word at a time.
            let saved = InBlockPosition.fraction(forCharacterOffset: currentOffset, in: text)
            let wanted = InBlockPosition.wantedMinY(fraction: saved, blockHeight: Double(frame.maxY - frame.minY),
                                                    viewportTop: Double(viewportTop))
            guard abs(Double(frame.minY) - wanted) > InBlockPosition.tolerance else { return }
            let offset = InBlockPosition.characterOffset(forFraction: fraction, in: text)
            guard offset != currentOffset else { return }
            currentOffset = offset
            savePosition()
            return
        }
        learnSpeed(from: currentIndex, to: top)
        currentIndex = top
        currentOffset = InBlockPosition.characterOffset(forFraction: fraction, in: text)
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
        savePosition()
        saveTimeRemaining()
        publishComplication(force: false)
    }

    /// Saves block and in-block offset for the next opening (and the Library's percentage).
    private func savePosition() {
        guard let pos = flat.position(at: currentIndex, characterOffset: currentOffset) else { return }
        positions.save(StoredPosition(position: pos, percentage: localPercentage), for: documentHash)
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

    /// Suppresses position updates while the scroll view settles after a programmatic scroll to `target`.
    ///
    /// A `LazyVStack` lays out far-away rows with estimated heights, and the first jump after the reader
    /// appears can run before the scroll view has its size, so `scrollTo` may land a few blocks off (or
    /// not move at all). Once the view settles the landing block is checked and the jump re-issued, so
    /// reopening a book shows the exact block it was closed at (#105). Scroll callbacks never overwrite
    /// the saved position meanwhile.
    /// With a non-zero `offset`, once the block is at the top a second jump (with an anchor computed from
    /// the offset's fraction of the block's laid-out height, then corrected from where it landed) brings
    /// the saved line to the top edge (#108). When the target block is already laid out (a re-anchor, a
    /// jump to a nearby block) that anchor is known up front and set as `restoreAnchor`, so the first
    /// jump already lands on the line and no second, visible move follows (#125).
    private func beginRestore(target: Int, offset: Int = 0) {
        if !isRestoring { isRestoring = true }
        restoreTarget = target
        restoreAttempts = 0
        restoreOffset = offset
        restoreAnchor = knownAnchor(target: target, offset: offset)
        inBlockAttempts = 0
        scheduleRestoreCheck()
    }

    /// The in-block anchor for `offset`, from the block's last measured height, if it is laid out.
    private func knownAnchor(target: Int, offset: Int) -> Double? {
        guard offset > 0, target < flat.count, let frame = lastFrames[target], viewportHeight > 0 else { return nil }
        let fraction = InBlockPosition.fraction(forCharacterOffset: offset, in: flat.blocks[target].text)
        return InBlockPosition.anchorY(fraction: fraction, blockHeight: Double(frame.maxY - frame.minY),
                                       viewportHeight: Double(viewportHeight), viewportTop: Double(viewportTop))
    }

    private func scheduleRestoreCheck() {
        restoreTask?.cancel()
        let delay = isPositioned ? settleDelay : openSettleDelay
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.restoreSettled()
        }
    }

    private func restoreSettled() {
        if let target = restoreTarget,
           RestoreCheck.needsRetry(top: VisibleBlockResolver.topIndex(frames: lastFrames, viewportTop: viewportTop),
                                   target: target, attempts: restoreAttempts) {
            restoreAttempts += 1
            jumpRequest = JumpRequest(index: target, anchorY: restoreAnchor)
            scheduleRestoreCheck()
            return
        }
        if let target = restoreTarget, restoreOffset > 0, let frame = lastFrames[target],
           let anchor = inBlockAnchor(target: target, frame: frame) {
            inBlockAttempts += 1
            restoreAnchor = anchor
            jumpRequest = JumpRequest(index: target, anchorY: anchor)
            scheduleRestoreCheck()
            return
        }
        restoreTarget = nil
        isRestoring = false
        if !isPositioned { isPositioned = true }
    }

    /// The anchor for another in-block jump, or nil when the saved line is at the top (or retries ran out).
    private func inBlockAnchor(target: Int, frame: BlockFrame) -> Double? {
        let height = Double(frame.maxY - frame.minY)
        let fraction = InBlockPosition.fraction(forCharacterOffset: restoreOffset, in: flat.blocks[target].text)
        let wanted = InBlockPosition.wantedMinY(fraction: fraction, blockHeight: height,
                                                viewportTop: Double(viewportTop))
        guard RestoreCheck.needsInBlockRetry(landedMinY: Double(frame.minY), wantedMinY: wanted,
                                             attempts: inBlockAttempts) else { return nil }
        if let previous = restoreAnchor {
            return InBlockPosition.correctedAnchorY(previous, error: Double(frame.minY) - wanted,
                                                    blockHeight: height, viewportHeight: Double(viewportHeight))
        }
        return InBlockPosition.anchorY(fraction: fraction, blockHeight: height,
                                       viewportHeight: Double(viewportHeight), viewportTop: Double(viewportTop))
    }

    /// Called by the view once it appeared: scroll to the saved block, then to the saved line in it. Both
    /// moves happen while the text is still transparent (`isPositioned`), so the reader appears at the line.
    func restoreInitialPosition() {
        if flat.isEmpty { isPositioned = true }
        beginRestore(target: startIndex, offset: startOffset)
        jumpRequest = JumpRequest(index: startIndex, anchorY: restoreAnchor)
        // The opened book becomes the one the complications show.
        publishComplication(force: false)
    }

    func jump(to index: Int, characterOffset: Int = 0) {
        let i = flat.clamped(index)
        let offset = flat.clampedOffset(characterOffset, in: i)
        beginRestore(target: i, offset: offset)
        pageTimer.reset(at: now())
        currentIndex = i
        currentOffset = offset
        persistCurrent()
        jumpRequest = JumpRequest(index: i, anchorY: restoreAnchor)
    }

    // MARK: Sync

    /// Characters before the line at the top edge over the book's characters.
    var localPercentage: Double { flat.percentage(at: currentIndex, characterOffset: currentOffset) }

    /// The current position in the same form `reportProgress` pushes it. The XPointer carries the
    /// in-block offset (`.../text().N`, in code points as crengine counts them) when it is not 0.
    var localPosition: ReadingPosition {
        guard !flat.isEmpty else { return ReadingPosition(xpointer: "", percentage: 0) }
        return ReadingPosition(xpointer: currentXPointer, percentage: localPercentage,
                               page: currentIndex + 1, pageCount: flat.count)
    }

    private var currentXPointer: String {
        guard let pos = flat.position(at: currentIndex, characterOffset: currentOffset),
              let located = XPointerResolver().locate(pos, in: book) else { return flat.blocks[currentIndex].xpointer }
        return located.xpointer
    }

    /// "43% read" for the reader menu: the position saved for the Library, so the menu and the book's
    /// Library row show the same number.
    func progressText(locale: Locale = .current) -> String {
        ReadingProgressFormat.read(localPercentage, locale: locale)
    }

    /// True while the open-time check is fetching the remote position: nothing is pushed meanwhile, so a
    /// newer remote position (e.g. the Readest apps' CFI) is not overwritten before it could be offered.
    private(set) var isCheckingRemote = false

    /// Readest rows can hold the Readest apps' CFI next to an older XPointer written by the watch: place the
    /// CFI in this book and use it when it is further (`ReadingPosition.resolvingCFI`).
    func syncOnOpen() async {
        isCheckingRemote = true
        defer { isCheckingRemote = false }
        let decision = await sync.decisionOnOpen(book: bookIdentity, local: localPosition,
                                                 resolveRemote: { [book] in $0.resolvingCFI(in: book) })
        if case .offerRemote(let remote) = decision {
            remoteOffer = remote
            showRemoteOffer = true
        }
    }

    func acceptRemote() {
        guard let remote = remoteOffer else { return }
        remoteOffer = nil
        go(to: remote)
    }

    /// Whether the reader menu offers "Go to Synced Position": only while a sync service is set up.
    var canGoToSyncedPosition: Bool { sync.isConfigured }

    /// What "Go to Synced Position" did.
    enum SyncedJump: Equatable {
        case jumped
        /// The synced position is the one on screen: nothing moved (the menu says so).
        case alreadyThere
        /// The service has no position for this book (or sync is off).
        case noPosition
        /// The service could not be reached.
        case failed
    }

    /// Fetches the remote position and jumps to it even when it is behind the local one (#112): the
    /// open-time check only offers positions that are ahead.
    func goToSyncedPosition() async -> SyncedJump {
        switch await sync.syncedPosition(book: bookIdentity, resolveRemote: { [book] in $0.resolvingCFI(in: book) }) {
        case .position(let remote):
            remoteOffer = nil
            showRemoteOffer = false
            let target = spot(for: remote)
            if target == Spot(index: currentIndex, offset: currentOffset) { return .alreadyThere }
            go(to: remote)
            return .jumped
        case .missing, .notConfigured:
            return .noPosition
        case .failed:
            return .failed
        }
    }

    /// Where `remote` lands in this book (clamped block index and in-block offset).
    private func spot(for remote: ReadingPosition) -> Spot {
        let target: Int
        var offset = 0
        switch resolver.resolve(remote.xpointer, percentage: remote.percentage, in: book) {
        case .position(let pos, _)?:
            target = flat.flatIndex(for: pos) ?? flat.index(forPercentage: remote.percentage)
            offset = pos.characterOffset
        case .percentage(let p)?:
            target = flat.index(forPercentage: p)
        case nil:
            target = flat.index(forPercentage: remote.percentage)
        }
        let i = flat.clamped(target)
        return Spot(index: i, offset: flat.clampedOffset(offset, in: i))
    }

    private func go(to remote: ReadingPosition) {
        let target = spot(for: remote)
        // The remote position is now our baseline: no need to echo it back.
        lastReported = target
        jump(to: target.index, characterOffset: target.offset)
    }

    func declineRemote() { remoteOffer = nil }

    /// Whether `reportProgress` must not push now (see there).
    var isHoldingPushes: Bool {
        if isCheckingRemote { return true }
        if let offer = remoteOffer, localPercentage < offer.percentage { return true }
        return false
    }

    /// Records the current position for syncing. No-op if nothing changed since the last report.
    ///
    /// Held back while the open-time check runs, and while a further remote position is offered and not yet
    /// answered (until the reader reads past it): pushing the older local position first would overwrite the
    /// remote one (Readest keeps one row per book, last writer wins).
    func reportProgress(immediately: Bool) {
        let spot = Spot(index: currentIndex, offset: currentOffset)
        guard !flat.isEmpty, lastReported != spot, !isHoldingPushes else { return }
        lastReported = spot
        sync.report(book: bookIdentity,
                    xpointer: currentXPointer,
                    percentage: localPercentage,
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
