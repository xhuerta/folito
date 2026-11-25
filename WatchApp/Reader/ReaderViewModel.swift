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
    /// The blocks the reader's scroll view holds: the chapter being read, plus chapters appended while reading
    /// forward (`ChapterWindow`). Flat indices; positions stay global.
    @Published private(set) var window: Range<Int>
    /// Whether the reader shows the window in a lazy stack: only a window of more than `lazyWindowThreshold` blocks
    /// when it is loaded (one enormous spine chapter); decided on loading, never on appending, so the stack never
    /// changes kind under the reader.
    @Published private(set) var windowIsLazy: Bool
    static let lazyWindowThreshold = 400
    /// A prepend waits for the scroll to be idle this long (seconds), so the block at the reading line is still.
    static let prependIdle: TimeInterval = 0.35
    /// How far (points) the block at the reading line may be off after a prepend before it is brought back.
    static let prependTolerance = 1.0
    private var prependTask: Task<Void, Never>?
    /// When the last frame report came (a prepend waits until the scroll is idle).
    private var lastFrameReport = Date.distantPast
    /// A prepend in progress: the block that was at the reading line and its top (scroll-view space) before it.
    private struct PendingPrepend {
        let block: Int
        let minY: Double
    }
    private var pendingPrepend: PendingPrepend?
    /// Set by the view (watchOS 11+, from the scroll phase): the reader is dragging the text or a fling is still
    /// moving it. A prepend's check never corrects a position the reader has scrolled since the prepend.
    var isUserScrolling = false {
        didSet {
            if isUserScrolling, pendingPrepend != nil { userScrolledSincePrepend = true }
        }
    }
    private var userScrolledSincePrepend = false
    /// Set by the view (watchOS 11+, from the scroll phase): a finger is on the text (tracking or dragging). The scroll
    /// view's pan follows the finger from the offset the drag began at, so a `scrollTo` made meanwhile is undone by the
    /// next touch move: a prepend's keep-scroll was lost and the text showed a chapter's height higher (the reader
    /// "jumped" from the start of a chapter into the middle of the previous one). A prepend waits for the finger to
    /// lift; a fling's deceleration does not hold it back (the keep-scroll stops it where the text is).
    var isUserTouching = false {
        didSet {
            guard oldValue, !isUserTouching, prependWaitsForTouchEnd else { return }
            prependWaitsForTouchEnd = false
            prependAfterTouch()
        }
    }
    /// A prepend was due while a finger was on the text (`isUserTouching`): made once it lifts.
    private var prependWaitsForTouchEnd = false
    private var prependCheckTask: Task<Void, Never>?
    /// How long after a prepend the block at the reading line is checked (seconds): every row has reported its new
    /// place by then. The first frame reports after the rows go in still mix old and new places.
    static let prependCheckDelay: TimeInterval = 0.3
    /// Set with a prepend, in the same update as the new rows: where the reader scrolls so that the block at the
    /// reading line stays where it is (the scroll view keeps its offset when rows go in above). Cleared by any other
    /// change of the window.
    @Published private(set) var prependKeep: JumpRequest?
#if DEBUG
    /// Trace only: when the current window was loaded, for how long it takes to show (`window shown`).
    private var windowLoad: (date: Date, target: Int, count: Int)?
#endif
    @Published var showRemoteOffer = false
    /// "Mark as Finished?": the reader just arrived at the end of the book (`ReadStatusRules.shouldOfferFinish`).
    @Published var showFinishOffer = false
    /// The book is marked finished (set by the loader from the library; updated by `setFinished`).
    @Published var isFinished = false {
        // Finished books show no minutes left in the complications (#169); unmarking brings them back.
        didSet { if isFinished != oldValue { publishComplication(force: false) } }
    }
    /// Stores a status the user chose here (the library, which tells the iPhone). Nil in previews and tests.
    var onSetReadStatus: (@MainActor (ReadStatus) -> Void)?
    /// Whether the end of the book was on screen at the last frame report (nil before the first one after the
    /// opening restore, so a book that opens at its end is not offered).
    private var wasAtEnd: Bool?
    /// The end of the book is on screen (same rule as the finish offer): nothing is left to read (#169).
    private var endOnScreen = false
    /// The finish offer was shown during this opening (answered or not): never twice.
    private var finishOffered = false
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
    /// A far jump (chapter, bookmark, synced position) is settling under a cover (#174, `JumpSettling`): the
    /// view hides the text until the target line is at the top edge, so the corrections are never seen.
    @Published private(set) var isSettling = false
    /// The text has been covered (opening or a far jump) for `settlingIndicatorDelay`: the cover shows a
    /// small progress indicator.
    @Published private(set) var showsSettlingIndicator = false
    /// When the indicator shows (injectable for tests).
    var settlingIndicatorDelay: UInt64 = JumpSettling.indicatorDelay
    private var settlingIndicatorTask: Task<Void, Never>?
    /// Where a covered jump landed, for VoiceOver to announce once when the text is revealed (a new value per
    /// jump).
    @Published private(set) var arrival: Arrival?
    /// The current cover is a jump's (announced on arrival), not a re-layout's (the reader stays where it was).
    private var announcesArrival = false
    /// The reader's layout key (`ReaderRenderStyle.layoutKey`) the frames were last measured with; nil until known.
    private(set) var layoutKey: String?

    struct Arrival: Equatable {
        let token = UUID()
        /// The chapter title at the new position, or the progress ("43% read") when it has none.
        let announcement: String
    }

    /// The text is hidden: the book is opening or a far jump is settling.
    var coversText: Bool { !isPositioned || isSettling }
    private var restoreTask: Task<Void, Never>?
    /// Block the current restore / jump must bring to the top, and how many times it was re-issued.
    private var restoreTarget: Int?
    private var restoreAttempts = 0
    /// Character offset inside `restoreTarget` the jump must bring to the top edge, the anchor last used
    /// for it, and how many times it was corrected.
    private var restoreOffset = 0
    private var restoreAnchor: Double?
    private var inBlockAttempts = 0
    /// Covered restores only: the target's top at the last check where it was in place, and how many such checks
    /// there were (`RestoreCheck.isStable`).
    private var settledMinY: Double?
    private var stabilityChecks = 0
    /// The target's top after the last re-issued scroll: the same scroll landing at the same point again cannot be
    /// helped by re-issuing it once more, so the anchor is corrected instead.
    private var lastRetryMinY: Double?
    /// The last anchor a chapter start was scrolled with and where the block's top landed with it, so the next
    /// correction uses the measured points-per-anchor of this scroll view, not a model of it.
    private var anchorSample: (anchor: Double, minY: Double)?
    /// Set by a re-layout: when `lastFrames` was dropped, and what it held. Until a frame of the new layout arrives
    /// the checks wait (without using up the retries), for at most `JumpSettling.newLayoutWait`: behind the Reading
    /// Options sheet the reader may report the new frames late. A key change that resized nothing reports no new
    /// frames at all (an unchanged preference is not delivered again): after the wait the old frames, which are the
    /// current ones then, are used.
    private var framesStaleSince: Date?
    private var staleFrames: [Int: BlockFrame] = [:]
    /// When the current restore began (real time): a covered one is revealed after `JumpSettling.maxSettleDuration`
    /// whatever its checks say, so the cover always lifts.
    private var restoreBegan = Date()
    /// Set when auto-scroll hands the text back (`handBackAutoScroll`): the exact points of `restoreTarget`
    /// above the reading line, used instead of `restoreOffset`, and the block the jump is anchored to (the
    /// next one when the target is about as tall as the viewport).
    private var restorePoints: Double?
    private var restoreJumpIndex: Int?
    /// How close a hand-back must land (points): the text must not visibly move when the scroll view shows.
    static let handBackTolerance = 0.5
    /// Latest frames reported by the view, kept while restoring to verify where the jump landed.
    private var lastFrames: [Int: BlockFrame] = [:]
    /// The reading line in the scroll view's coordinate space. Derived from `readingLineOnScreen` and the measured
    /// start of that space on screen (`scrollSpaceOriginOnScreen`) whenever either changes; tests set it directly.
    var viewportTop: CGFloat = 0
    /// The reading line on screen (global y), set by the view (`ReadingLine.updated`). Nil until the view reports it.
    var readingLineOnScreen: CGFloat? {
        didSet { updateReadingLine() }
    }
    /// Where the scroll view's coordinate space starts on screen, measured from the last frames that carried their
    /// screen position (`BlockFrame.screenMinY`). Nil until measured.
    private(set) var scrollSpaceOriginOnScreen: CGFloat?

    private func updateReadingLine() {
        guard let line = readingLineOnScreen, let origin = scrollSpaceOriginOnScreen else { return }
        viewportTop = ReadingLine.inScrollSpace(screenLine: line, scrollOriginY: origin)
    }
    /// Height of the scroll view (set by the view); used to compute in-block `scrollTo` anchors.
    var viewportHeight: CGFloat = 0
    /// Pause before checking where a programmatic jump landed (injectable for tests).
    var settleDelay: UInt64 = 700_000_000
    /// The same pause while the book opens. Shorter: the text is still hidden then, so a check that comes
    /// before the lazy layout settled only costs a re-issued jump nobody sees, and the hidden time stays
    /// short (most openings settle in a few checks; at most `RestoreCheck.coveredRetries` of each kind).
    var openSettleDelay: UInt64 = 200_000_000
    private var lastReported: Spot?

    private let positions: PositionStore
    private let sync: SyncCoordinator
    /// The book's bookmarks (#65), newest first.
    @Published private(set) var bookmarks: BookmarkList
    private let bookmarkStore: BookmarkStore
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
         settings: UserDefaults = .standard,
         imageFiles: BookImageFiles? = nil) {
        self.book = book
        self.imageFiles = imageFiles
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
        let bookmarkStore = positions.bookmarks
        self.bookmarkStore = bookmarkStore
        self.bookmarks = bookmarkStore.load(documentHash: book.documentHash)
        let (start, startOffset) = Self.openPosition(saved: positions.load(book.documentHash), in: flat)
        self.startIndex = start
        self.startOffset = startOffset
        let window = ChapterWindow.window(for: start, chapterStarts: flat.chapterStarts, count: flat.count)
        self.window = window
        self.windowIsLazy = window.count > Self.lazyWindowThreshold
        self.currentIndex = start
        self.currentOffset = startOffset
        // Merely opening a book must not PUT its (possibly 0%) start position: if the open-time GET
        // failed or the user declined the remote offer, that would overwrite real remote progress.
        // Only report once the reader actually moves.
        self.lastReported = Spot(index: start, offset: startOffset)
        // Counting the words of a whole book takes a moment on the watch: do it off the main actor.
        // With a TOC, "chapter" in the time left is the chapter-level TOC section the menu marks.
        let toc = flat.toc
        self.autoScrollLevel = AutoScroll.storedLevel(settings.integer(forKey: ReaderSettings.autoScrollSpeedKey))
#if DEBUG
        // From the start, so the first geometry reports and the opening restore are traced too.
        self.tracesRestores = UITesting.tracesRestores
#endif
        Task.detached(priority: .utility) { [weak self] in
            let index = FlatBook.lengthIndex(for: book, toc: toc)
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

    // MARK: Auto-scroll (#67)

    /// Auto-scroll: off, moving the text, or paused (by a tap, a sheet, the wrist going down). Never started
    /// by itself: only from Reading Options, and only resumed by a tap on the text.
    enum AutoScrollState: Equatable {
        case off
        case running
        case paused
    }

    @Published private(set) var autoScroll: AutoScrollState = .off
    /// Speed level (`AutoScroll.levels`). One for the user, not per book: stored in settings.
    @Published private(set) var autoScrollLevel = AutoScroll.defaultLevel
    /// Plays the start / stop haptics (silent in tests).
    var haptics: HapticPlaying = NoHaptics()

    /// Whether the speed badge also says "Turn the Digital Crown to change speed": only the first time
    /// auto-scroll is ever started (remembered in settings), until the badge goes or the speed changes.
    @Published private(set) var autoScrollShowsCrownHint = false
    /// How far auto-scroll has moved the text, in lines, as a function of time (`AutoScroll.Motion`). Not
    /// published: the reader reads it on every frame while the text moves, and nothing else changes then.
    private(set) var autoScrollMotion = AutoScroll.Motion()
    /// When the reading position was last saved while the text moved by itself.
    private var lastAutoScrollCommit: Date?

    var isAutoScrollActive: Bool { autoScroll != .off }

    /// Starts auto-scroll at the saved speed; with Reduce Motion at a gentle one (`AutoScroll.startLevel`).
    func startAutoScroll(reduceMotion: Bool) {
        guard !flat.isEmpty, autoScroll == .off else { return }
        autoScrollLevel = AutoScroll.startLevel(saved: settings.integer(forKey: ReaderSettings.autoScrollSpeedKey),
                                                reduceMotion: reduceMotion)
        if !settings.bool(forKey: ReaderSettings.autoScrollCrownHintShownKey) {
            settings.set(true, forKey: ReaderSettings.autoScrollCrownHintShownKey)
            autoScrollShowsCrownHint = true
        }
        autoScrollMotion = AutoScroll.Motion(linesPerSecond: AutoScroll.linesPerSecond(level: autoScrollLevel), at: now())
        lastAutoScrollCommit = nil
        autoScroll = .running
        // Pages scrolled by auto-scroll are not timed (`learnSpeed`).
        pageTimer.reset(at: now())
        haptics.play(.autoScrollStarted)
    }

    func pauseAutoScroll() {
        guard autoScroll == .running else { return }
        autoScrollMotion.setSpeed(0, at: now())
        autoScroll = .paused
        haptics.play(.autoScrollStopped)
    }

    func resumeAutoScroll() {
        guard autoScroll == .paused else { return }
        autoScrollMotion.setSpeed(AutoScroll.linesPerSecond(level: autoScrollLevel), at: now())
        autoScroll = .running
        haptics.play(.autoScrollStarted)
    }

    /// The first-start hint has been on screen long enough (or the user found the crown).
    func dismissAutoScrollCrownHint() {
        if autoScrollShowsCrownHint { autoScrollShowsCrownHint = false }
    }

    /// Lines auto-scroll has moved the text at `date` (frozen while paused).
    func autoScrollLines(at date: Date) -> Double {
        autoScrollMotion.lines(at: date)
    }

    /// While auto-scroll moves the text, the scroll view underneath stays where it was, so the reader reports
    /// the line at the reading line itself: the block, the points of it above that line and its height. Saved
    /// at most every `AutoScroll.commitInterval` seconds, or at once with `force` (pause, stop, leaving).
    /// Returns whether it was saved.
    @discardableResult
    func autoScrollPositionChanged(_ cursor: AutoScroll.Cursor, blockHeight: Double, force: Bool = false) -> Bool {
        guard !flat.isEmpty else { return false }
        let date = now()
        if !force, let last = lastAutoScrollCommit, date.timeIntervalSince(last) < AutoScroll.commitInterval {
            return false
        }
        lastAutoScrollCommit = date
        let index = flat.clamped(cursor.index)
        let text = flat.blocks[index].text
        let fraction = blockHeight > 0 && blockHeight.isFinite ? min(max(cursor.offset / blockHeight, 0), 1) : 0
        let offset = InBlockPosition.characterOffset(forFraction: fraction, in: text)
        guard index != currentIndex || offset != currentOffset else { return true }
        // Resets the page timer: auto-scrolled pages never teach the reading speed.
        learnSpeed(from: currentIndex, to: index)
        currentIndex = index
        currentOffset = offset
        persistCurrent()
        return true
    }

    /// Auto-scroll paused or stopped where `cursor` is (`frames`: the blocks as auto-scroll shows them, in
    /// the scroll view's coordinate space): saves that line and brings the scroll view to exactly that point
    /// (to the point, not to the start of a word as a restore by character offset would), checking where it
    /// landed like any restore. The reader keeps showing the auto-scrolled text until `isRestoring` is false.
    func handBackAutoScroll(at cursor: AutoScroll.Cursor, frames: [Int: AutoScroll.Span]) {
        guard !flat.isEmpty, let frame = frames[cursor.index] else { return }
        autoScrollPositionChanged(cursor, blockHeight: frame.height, force: true)
        guard let target = AutoScroll.scrollTarget(cursor, frames: frames, viewportTop: Double(viewportTop),
                                                   viewportHeight: Double(viewportHeight)) else {
            reanchor()
            return
        }
        // Auto-scroll may have moved past the loaded chapters: extend the window below (never above, which would
        // rebuild what is on screen) so the scroll view holds the block it is brought to.
        let furthest = max(cursor.index, target.index)
        if let extended = ChapterWindow.extended(window, toHold: furthest, chapterStarts: flat.chapterStarts,
                                                 count: flat.count) {
            if extended != window { window = extended }
        } else {
            loadWindow(for: cursor.index)
        }
        beginRestore(target: cursor.index)
        restorePoints = cursor.offset
        restoreJumpIndex = target.index
        restoreAnchor = target.anchorY
        jumpRequest = JumpRequest(index: target.index, anchorY: target.anchorY)
    }

    func stopAutoScroll() {
        guard autoScroll != .off else { return }
        autoScrollMotion.setSpeed(0, at: now())
        autoScroll = .off
        // Reading by hand starts a fresh page now: no sample spans the auto-scroll session.
        pageTimer.reset(at: now())
        haptics.play(.autoScrollStopped)
    }

    /// A new speed (the Digital Crown, VoiceOver adjust), clamped and remembered for the next time.
    func setAutoScrollLevel(_ level: Int) {
        let clamped = AutoScroll.clampedLevel(level)
        guard clamped != autoScrollLevel else { return }
        autoScrollLevel = clamped
        settings.set(clamped, forKey: ReaderSettings.autoScrollSpeedKey)
        // A new slope from now on, continuing from the distance reached: the text does not jump.
        if autoScroll == .running {
            autoScrollMotion.setSpeed(AutoScroll.linesPerSecond(level: clamped), at: now())
        }
        // Found the crown: the hint has done its job.
        dismissAutoScrollCrownHint()
    }

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
        // An image block has no words (#71): the next block with text, if any.
        var target = flat.clamped(index)
        var offset = characterOffset
        if flat.blocks[target].isImage {
            guard let next = flat.blocks.indices[target...].first(where: { !flat.blocks[$0].isImage }) else { return }
            target = next
            offset = nil
        }
        pageTimer.reset(at: now())
        lookupBlockIndex = LookupTarget(index: target, characterOffset: offset)
    }

    /// Note shown in the note sheet (#66). The sheet covers the reader without scrolling it, so closing it
    /// returns to the same line.
    @Published var openNote: OpenNote?

    struct OpenNote: Identifiable, Equatable {
        /// Flat index of the block holding the reference.
        let blockIndex: Int
        let note: NoteReference
        var id: String { "\(blockIndex)|\(note.location)" }
    }

    // MARK: Images (#71)

    /// Where the book's pictures are stored (nil: previews, tests, books without pictures).
    let imageFiles: BookImageFiles?

    /// Picture shown full screen. Like a note, the viewer covers the reader without scrolling it, so closing it
    /// returns to the same line.
    @Published var openImage: OpenImage?

    struct OpenImage: Identifiable, Equatable {
        /// Flat index of the image block.
        let blockIndex: Int
        let image: BlockImage
        var id: Int { blockIndex }
    }

    /// The picture file of an image block, when it has one.
    func imageURL(_ image: BlockImage) -> URL? {
        guard let id = image.id else { return nil }
        return imageFiles?.url(for: id)
    }

    /// Whether the picture of block `index` is decoded now (`ImageResidency`).
    func loadsImage(at index: Int) -> Bool {
        ImageResidency.isNear(index, current: currentIndex)
    }

    /// Opens the picture of an image block full screen. Returns false for a block that is not an image.
    @discardableResult
    func showImage(at index: Int) -> Bool {
        guard index >= 0, index < flat.count, let image = flat.blocks[index].image else { return false }
        pageTimer.reset(at: now())
        openImage = OpenImage(blockIndex: index, image: image)
        return true
    }

    func showNote(_ note: NoteReference, inBlock index: Int) {
        guard !flat.isEmpty else { return }
        // Time spent on a note is not reading time of the page.
        pageTimer.reset(at: now())
        openNote = OpenNote(blockIndex: flat.clamped(index), note: note)
    }

    /// Last measured frame of a block, if it is laid out.
    func frame(ofBlock index: Int) -> BlockFrame? { lastFrames[index] }

    /// Last measured frames of the instantiated blocks (scroll-view coordinate space).
    var blockFrames: [Int: BlockFrame] { lastFrames }

    /// Re-aligns the scroll view with the line we were reading (after the menu closes). Does not change the
    /// saved position. When that line is at the top edge already, nothing is scrolled: a scroll to where the text
    /// is would only risk a hop (`InBlockPosition.anchorY` is an estimate until corrected). Otherwise the text is
    /// covered until it has landed (`JumpSettling`).
    func reanchor() {
        guard !flat.isEmpty else { return }
        // Time in the menu or a lookup is not reading time.
        pageTimer.reset(at: now())
        // A restore in progress (the chapter just chosen, a re-layout) already brings this line back: another one
        // on top of it would only add a cover over a near jump.
        guard !isRestoring, !showsCurrentLine else { return }
        // The line is not where it should be (a re-layout that could not finish behind the menu, say): bring it
        // back under the cover, so the move shows as one.
        if isPositioned, !isSettling, autoScroll == .off {
            announcesArrival = false
            beginSettlingCover()
        }
        beginRestore(target: currentIndex, offset: currentOffset)
        jumpRequest = JumpRequest(index: currentIndex, anchorY: restoreAnchor)
    }

    /// Not restoring, and the saved line is at the top edge (within `InBlockPosition.tolerance`).
    private var showsCurrentLine: Bool {
        guard !isRestoring, currentIndex < flat.count,
              VisibleBlockResolver.lineIndex(frames: lastFrames, viewportTop: viewportTop) == currentIndex,
              let frame = lastFrames[currentIndex] else { return false }
        let fraction = InBlockPosition.fraction(forCharacterOffset: currentOffset, in: flat.blocks[currentIndex].text)
        let wanted = InBlockPosition.wantedMinY(fraction: fraction, blockHeight: Double(frame.maxY - frame.minY),
                                                viewportTop: Double(viewportTop))
        return abs(Double(frame.minY) - wanted) <= InBlockPosition.tolerance
    }

    /// The reader's layout changed (text size, font, spacing, margins, Bold Text, Dynamic Type): every block
    /// changes height, so the passage at the top must be brought back. Called by the view as soon as it sees a
    /// new `layoutKey`, and checked on every frame report too (`blockFramesChanged(_:layoutKey:)`), so whichever
    /// comes first freezes the position before a frame of the new layout could be read as the reader scrolling.
    ///
    /// The saved block and character offset are kept as they are and become the restore target; the old frames
    /// are dropped (their heights are wrong now). While the text is shown it is covered until that line is back
    /// at the top edge (`JumpSettling`), then revealed in one move. No VoiceOver announcement: the reader did not
    /// go anywhere. While auto-scroll runs it shows its own copy of the text, so nothing is covered.
    func layoutChanged(to key: String) {
        guard let old = layoutKey else {
            layoutKey = key
            return
        }
        guard old != key else { return }
        layoutKey = key
#if DEBUG
        trace("layout \(old) -> \(key) restoring=\(isRestoring ? 1 : 0)")
#endif
        guard !flat.isEmpty else { return }
        pageTimer.reset(at: now())
        staleFrames = lastFrames
        lastFrames = [:]
        framesStaleSince = Date()
        // The scroll view is rebuilt for the new layout: it gets the current chapter only (chapters appended while
        // reading are dropped here, not while reading).
        let reloaded = ChapterWindow.window(for: currentIndex, chapterStarts: flat.chapterStarts, count: flat.count)
        cancelPrepend()
        if reloaded != window {
            window = reloaded
            windowIsLazy = reloaded.count > Self.lazyWindowThreshold
            staleFrames = [:]
        }
#if DEBUG
        windowLoad = (Date(), currentIndex, window.count)
#endif
        if isPositioned, !isSettling, autoScroll != .running {
            announcesArrival = false
            beginSettlingCover()
        }
        // A jump still settling keeps its target (it is the position already: `jump` saved it).
        beginRestore(target: currentIndex, offset: currentOffset)
        jumpRequest = JumpRequest(index: currentIndex, anchorY: restoreAnchor)
    }

    // MARK: Visibility / persistence

    /// Receives the frames of the currently instantiated blocks (scroll-view coordinate space).
    ///
    /// The position is the line at the viewport's top edge: the top block plus the character offset of
    /// the part of it scrolled past that edge.
    /// `layoutKey`: the layout the frames were measured with (nil in tests that do not care); a new one is a
    /// layout change (`layoutChanged(to:)`), handled before the frames are read.
#if DEBUG
    // MARK: Restore trace (UI tests only, `-UITestingRestoreTrace`)

    /// Set by the view from `UITesting.tracesRestores`; off, nothing below is recorded.
    var tracesRestores = false
    /// The scroll view's content offset (distance scrolled), last reported (trace only; not published).
    var traceScrollOffset: CGFloat?
    /// The last `traceLimit` events of the restore machinery, oldest first, for a UI test's failure message.
    @Published private(set) var restoreTrace: [String] = []
    /// The last few geometry reports (scroll view top edge, reading line), kept apart so the bar's animation does
    /// not push the checks out of `restoreTrace`.
    @Published private(set) var geometryTrace: [String] = []
    /// Reading by hand (no restore): each change of the top block, and every tenth report, with the content offset,
    /// the measured blocks and the measured height above the top block, to show when the offset and the frames part.
    @Published private(set) var readingTrace: [String] = []
    private var readingReports = 0

    /// Everything the trace holds, for the "restoreTrace" element.
    var traceText: String {
        var parts: [String] = restoreTrace
        parts.append("geometry:")
        parts.append(contentsOf: geometryTrace)
        parts.append("reading:")
        parts.append(contentsOf: readingTrace)
        return parts.joined(separator: " | ")
    }

    private func traceReading(frames: [Int: BlockFrame], top: Int?, changed: Bool) {
        guard tracesRestores else { return }
        readingReports += 1
        guard changed || readingReports % 10 == 0 else { return }
        let offsetText = traceScrollOffset.map { String(format: "%.1f", Double($0)) } ?? "nil"
        var above: CGFloat = 0
        if let top {
            for (index, frame) in frames where index < top { above += frame.maxY - frame.minY }
        }
        let first = frames.keys.min() ?? -1
        let last = frames.keys.max() ?? -1
        let topText = top.map(String.init) ?? "nil"
        let aboveText = String(format: "%.1f", Double(above))
        readingTrace.append("r\(readingReports) top=\(topText) off=\(offsetText) blocks=\(first)-\(last) above=\(aboveText)")
        if readingTrace.count > 20 { readingTrace.removeFirst(readingTrace.count - 20) }
    }
    private static let traceLimit = 30

    func traceGeometry(_ event: @autoclosure () -> String) {
        guard tracesRestores else { return }
        let text = event()
        guard geometryTrace.last != text else { return }
        geometryTrace.append(text)
        if geometryTrace.count > 6 { geometryTrace.removeFirst(geometryTrace.count - 6) }
    }
    private var traceCheck = 0
    /// Frame reports still to trace after a restore ended (where the text really went once revealed).
    private var tracePostReports = 0

    func trace(_ event: @autoclosure () -> String) {
        guard tracesRestores else { return }
        restoreTrace.append(event())
        if restoreTrace.count > Self.traceLimit { restoreTrace.removeFirst(restoreTrace.count - Self.traceLimit) }
    }

    private func traceFrame(_ frame: BlockFrame?) -> String {
        frame.map { String(format: "%.1f..%.1f", Double($0.minY), Double($0.maxY)) } ?? "nil"
    }

    /// One settle check: the target, the reading line in scroll space, the target's measured frame, the top block.
    private func traceCheckState(_ step: String) {
        guard tracesRestores else { return }
        traceCheck += 1
        let target = restoreTarget
        let top = VisibleBlockResolver.topIndex(frames: lastFrames, viewportTop: viewportTop)
        let targetText = target.map(String.init) ?? "nil"
        let topText = top.map(String.init) ?? "nil"
        var frameText: String = traceFrame(target.flatMap { lastFrames[$0] })
        if let screenMinY = target.flatMap({ lastFrames[$0]?.screenMinY }) {
            frameText += String(format: " scr=%.1f", Double(screenMinY))
        }
        if let origin = scrollSpaceOriginOnScreen {
            frameText += String(format: " so=%.1f", Double(origin))
        }
        if let offset = traceScrollOffset {
            frameText += String(format: " off=%.1f", Double(offset))
        }
        if let first = lastFrames.keys.min(), let last = lastFrames.keys.max() {
            frameText += " blocks=\(first)-\(last)"
        }
        let anchorText = restoreAnchor.map { String(format: "%.3f", $0) } ?? "nil"
        let lineText = String(format: "vt=%.1f vh=%.1f", Double(viewportTop), Double(viewportHeight))
        let keyText = layoutKey ?? "nil"
        let parts: [String] = ["c\(traceCheck)", step, "tgt=\(targetText)", "off=\(restoreOffset)", lineText,
                               "f=\(frameText)", "top=\(topText)", "n=\(lastFrames.count)", "a=\(anchorText)",
                               "cov=\(coversText ? 1 : 0)", "key=\(keyText)"]
        trace(parts.joined(separator: " "))
    }

    /// After a restore or an append: where the text really went (the next few frame reports), and how long a loaded
    /// window took to show its target.
    private func traceFrameReport(_ frames: [Int: BlockFrame]) {
        if tracePostReports > 0, !isRestoring, let target = traceLastTarget {
            tracePostReports -= 1
            let topText = VisibleBlockResolver.topIndex(frames: frames, viewportTop: viewportTop).map(String.init) ?? "nil"
            let frameText = traceFrame(frames[target])
            let range = frames.keys.min().map { "\($0)-\(frames.keys.max()!)" } ?? "none"
            let since = traceEndedAt.map { String(format: "+%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            let offsetText = traceScrollOffset.map { String(format: " off=%.1f", Double($0)) } ?? ""
            let lineText = String(format: "vt=%.1f", Double(viewportTop))
            trace("post \(since) f=\(frameText) top=\(topText) blocks=\(range)\(offsetText) \(lineText)")
        }
        if let load = windowLoad, let frame = frames[load.target] {
            let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(load.date) * 1000)
            let kind = windowIsLazy ? "lazy" : "plain"
            let height = String(format: "h=%.1f", Double(frame.maxY - frame.minY))
            trace("window shown \(load.count) blocks (\(kind)), target in \(elapsed) \(height)")
            windowLoad = nil
        }
    }

    private func traceAppend(to appended: Range<Int>, frames: [Int: BlockFrame]) {
        guard tracesRestores else { return }
        let top = VisibleBlockResolver.topIndex(frames: frames, viewportTop: viewportTop)
        let topText = top.map(String.init) ?? "nil"
        let offsetText = traceScrollOffset.map { String(format: "%.1f", Double($0)) } ?? "nil"
        trace("append \(window.upperBound) -> \(appended.upperBound) top=\(topText) off=\(offsetText)")
        if let top {
            traceLastTarget = top
            traceEndedAt = Date()
            tracePostReports = 6
        }
    }

    private func traceIgnoredReport(_ frames: [Int: BlockFrame]) {
        guard tracesRestores, !frames.isEmpty else { return }
        let topText = VisibleBlockResolver.topIndex(frames: frames, viewportTop: viewportTop).map(String.init) ?? "nil"
        let first = frames.keys.min() ?? -1
        let last = frames.keys.max() ?? -1
        trace("ignored report: no block at the line (first below=\(topText), blocks=\(first)-\(last))")
    }

    private func traceStepBack(to top: Int, frame: BlockFrame, frames: [Int: BlockFrame]) {
        guard tracesRestores else { return }
        let originText = scrollSpaceOriginOnScreen.map { String(format: "%.1f", Double($0)) } ?? "nil"
        let offsetText = traceScrollOffset.map { String(format: "%.1f", Double($0)) } ?? "nil"
        let screenText = frame.screenMinY.map { String(format: "%.1f", Double($0)) } ?? "nil"
        let lineText = String(format: "%.1f", Double(viewportTop))
        let first = frames.keys.min() ?? -1
        let last = frames.keys.max() ?? -1
        trace("back \(currentIndex) -> \(top) f=\(traceFrame(frame)) scr=\(screenText) vt=\(lineText) so=\(originText) "
              + "off=\(offsetText) blocks=\(first)-\(last)")
    }
#endif

    func blockFramesChanged(_ frames: [Int: BlockFrame], layoutKey: String? = nil) {
        if let layoutKey { layoutChanged(to: layoutKey) }
        lastFrames = frames
        lastFrameReport = Date()
        // Measure where the scroll view's space starts on screen from these very frames, so the reading line and the
        // frames it is compared with are always in the same space.
        if let measured = frames.min(by: { $0.key < $1.key }).flatMap({ entry in
            entry.value.screenMinY.map { $0 - entry.value.minY } }) {
            if scrollSpaceOriginOnScreen.map({ abs($0 - measured) > 0.25 }) ?? true {
#if DEBUG
                trace(String(format: "space origin=%.1f (was %@)", Double(measured),
                             scrollSpaceOriginOnScreen.map { String(format: "%.1f", Double($0)) } ?? "nil"))
#endif
                scrollSpaceOriginOnScreen = measured
                updateReadingLine()
            }
        }
#if DEBUG
        traceFrameReport(frames)
#endif
        if framesStaleSince != nil, !frames.isEmpty {
            framesStaleSince = nil
            staleFrames = [:]
        }
        // While auto-scroll moves the text the scroll view underneath stands still (hidden): its frames say
        // nothing about the reading position, which auto-scroll reports itself (`autoScrollPositionChanged`).
        guard autoScroll != .running else { return }
        // Between a prepend and its check, frame reports mix the rows' old and new places: they are not reading.
        guard pendingPrepend == nil else { return }
        // Reading forward: the next chapter goes below before its first block is needed (never during a restore,
        // which must not see the content change under it).
        if !isRestoring, ChapterWindow.needsAppend(lastLaidOut: frames.keys.max(), window: window, count: flat.count) {
            let appended = ChapterWindow.appendingNextChapter(to: window, chapterStarts: flat.chapterStarts,
                                                              count: flat.count)
#if DEBUG
            traceAppend(to: appended, frames: frames)
#endif
            window = appended
        }
        if !isRestoring { checkEnd(frames) }
        // Only a block that is at the reading line moves the position: a partial report (some rows only, while the
        // lazy stack re-lays them) leaves it where it is.
        guard !isRestoring else { return }
        let lineTop = VisibleBlockResolver.lineIndex(frames: frames, viewportTop: viewportTop)
#if DEBUG
        traceReading(frames: frames, top: lineTop, changed: lineTop != nil && lineTop != currentIndex)
#endif
        // Reading up near the first loaded block: the previous chapter goes above once the scroll is idle.
        // Keep a spare chapter above: once idle, or at once (even mid-fling) close to the edge.
        if autoScroll == .off, ChapterWindow.needsPrepend(top: lineTop, window: window, chapterStarts: flat.chapterStarts,
                                                          count: flat.count) {
            if let lineTop, ChapterWindow.prependIsUrgent(top: lineTop, window: window) {
                prepend(keeping: lineTop)
            } else {
                schedulePrepend()
            }
        }
        guard let top = lineTop,
              top < flat.count, let frame = frames[top] else {
#if DEBUG
            traceIgnoredReport(frames)
#endif
            return
        }
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
#if DEBUG
        // Only a jump back (more than a few blocks), not reading up a block at a time.
        if currentIndex - top > 3 { traceStepBack(to: top, frame: frame, frames: frames) }
#endif
        learnSpeed(from: currentIndex, to: top)
        currentIndex = top
        currentOffset = InBlockPosition.characterOffset(forFraction: fraction, in: text)
        persistCurrent()
    }

    // MARK: Read status

    /// Offers "Mark as Finished?" when the bottom of the last block comes on screen while reading. Never marks
    /// the book by itself: readers jump to the end for the notes or an epilogue.
    private func checkEnd(_ frames: [Int: BlockFrame]) {
        guard !flat.isEmpty else { return }
        let atEnd = ReadStatusRules.reachedEnd(lastBlockMaxY: frames[flat.count - 1].map { Double($0.maxY) },
                                               viewportBottom: Double(viewportHeight))
        defer { wasAtEnd = atEnd }
        if atEnd != endOnScreen {
            endOnScreen = atEnd
            saveTimeRemaining()
            publishComplication(force: false)
        }
        guard let before = wasAtEnd else { return }
        if ReadStatusRules.shouldOfferFinish(wasAtEnd: before, isAtEnd: atEnd, isFinished: isFinished,
                                             alreadyOffered: finishOffered, bookCharacters: book.totalCharacters) {
            finishOffered = true
            showFinishOffer = true
        }
    }

    /// "Mark as Finished" / "Mark as Unread" (the offer at the end, or the reader menu).
    func setFinished(_ finished: Bool) {
        isFinished = finished
        onSetReadStatus?(finished ? .finished : .unread)
    }

    /// Scrolling forward past blocks feeds the page timer; going back starts a new page without a sample.
    private func learnSpeed(from old: Int, to new: Int) {
        let date = now()
        // While auto-scroll is on (running or paused) it sets the pace, so its pages say nothing about the
        // reader's own speed (#67): no samples, and each block starts a new page.
        guard new > old, let lengths, autoScroll == .off else { pageTimer.reset(at: date); return }
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

    /// Time left from the block at the top of the screen (0 with the end of the book on screen, #169); nil until
    /// the words are counted or for an empty book. This is what is saved for the iPhone library.
    private var estimatedTimeRemaining: ReadingTimeRemaining? {
        guard let lengths, !flat.isEmpty, lengths.blockCount == flat.count else { return nil }
        let estimate = ReadingTimeEstimator.estimate(lengths, atBlock: currentIndex, speed: speed,
                                                     endOnScreen: endOnScreen)
        return ReadingTimeRemaining(documentHash: documentHash, bookTitle: title,
                                    chapterSeconds: estimate.chapter, bookSeconds: estimate.book,
                                    fractionRead: flat.percentage(at: currentIndex), updatedAt: now())
    }

    /// The time left to show: nil (no "… left" line) while it is not known, for a book marked Finished and when
    /// nothing is left to read (#169).
    var timeRemaining: ReadingTimeRemaining? {
        guard let value = estimatedTimeRemaining,
              ReadingTimeEstimator.shownTimeLeft(value.bookSeconds, isFinished: isFinished) != nil else { return nil }
        return value
    }

    /// Saved with the reading position, for the iPhone library (`ReadingTimeStore`). Saved even when nothing is
    /// left, so the iPhone drops its earlier "1 min left".
    private func saveTimeRemaining() {
        if let value = estimatedTimeRemaining { times.save(value) }
    }

    // MARK: Complications

    /// What the complications show for the current position.
    var complicationSnapshot: ReadingSnapshot {
        let chapter = flat.chapterTitle(at: currentIndex, characterOffset: currentOffset)
        return ReadingSnapshot(bookID: documentHash, title: title, chapterTitle: chapter,
                               fraction: flat.percentage(at: currentIndex),
                               minutesLeft: minutesLeftInChapter())
    }

    /// Estimated minutes left in the current chapter, shown by the rectangular complication / Smart Stack.
    ///
    /// Same estimate as the reader's time-remaining line (`timeRemaining.chapterSeconds`, rounded with
    /// `ReadingTimeEstimator.displayMinutes`). Nil, which hides the line, while the words are still being
    /// counted, when the user turned off *Show Time Remaining* in Settings, for a book marked Finished and with
    /// the end of the book on screen (#169).
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
        // A jump elsewhere leaves the end; the next frame report after the restore says whether it is on screen.
        if target != currentIndex { endOnScreen = false }
        restoreTarget = target
        restoreAttempts = 0
        restoreOffset = offset
        restoreAnchor = knownAnchor(target: target, offset: offset)
        inBlockAttempts = 0
        restorePoints = nil
        restoreJumpIndex = nil
        settledMinY = nil
        stabilityChecks = 0
        lastRetryMinY = nil
        anchorSample = nil
        restoreBegan = Date()
#if DEBUG
        trace("begin tgt=\(target) off=\(offset) cov=\(coversText ? 1 : 0)")
#endif
        scheduleRestoreCheck()
    }

    /// How many re-issues and corrections a restore gets: more under a cover, where they are not seen.
    private var restoreLimit: Int { coversText ? RestoreCheck.coveredRetries : RestoreCheck.maxRetries }

    /// The end of the book is on screen in the last frames.
    private var endOfBookOnScreen: Bool {
        RestoreCheck.endOfBookOnScreen(lastBlockMaxY: lastFrames[flat.count - 1].map { Double($0.maxY) },
                                       viewportHeight: Double(viewportHeight))
    }

    /// The in-block anchor for `offset`, from the block's last measured height, if it is laid out.
    /// Offset 0 (a chapter's start) never needs one: `.top` puts the block's top at the reading line.
    private func knownAnchor(target: Int, offset: Int) -> Double? {
        guard offset > 0, target < flat.count, let frame = lastFrames[target], viewportHeight > 0 else { return nil }
        let fraction = InBlockPosition.fraction(forCharacterOffset: offset, in: flat.blocks[target].text)
        return InBlockPosition.anchorY(fraction: fraction, blockHeight: Double(frame.maxY - frame.minY),
                                       viewportHeight: Double(viewportHeight), viewportTop: Double(viewportTop))
    }

    private func scheduleRestoreCheck() {
        restoreTask?.cancel()
        let delay = JumpSettling.checkDelay(isPositioned: isPositioned, isSettling: isSettling,
                                            settleDelay: settleDelay, openSettleDelay: openSettleDelay)
        restoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.restoreSettled()
        }
    }

    private func restoreSettled() {
        // First the right block at the top: a landing on estimated heights is fixed by re-issuing the same scroll
        // once the blocks around the target are measured (never by correcting the anchor from it: that error
        // comes from the estimate, not the anchor, and an anchor "corrected" for it lands just as far off the
        // other way, a heading in mid-screen).
        // Hard cap: a covered restore is revealed after `maxSettleDuration`, wherever it stands.
        if coversText, Date().timeIntervalSince(restoreBegan) >= JumpSettling.maxSettleDuration {
#if DEBUG
            traceCheckState("cap")
#endif
            finishRestore(reason: "cap")
            return
        }
        // A re-layout's frames have not arrived yet: check again shortly, without using up a retry.
        if let since = framesStaleSince {
            if Date().timeIntervalSince(since) < JumpSettling.newLayoutWait {
#if DEBUG
                traceCheckState("waitframes")
#endif
                scheduleRestoreCheck()
                return
            }
#if DEBUG
            trace("newframes timeout: old frames used=\(lastFrames.isEmpty ? 1 : 0)")
#endif
            framesStaleSince = nil
            if lastFrames.isEmpty { lastFrames = staleFrames }
            staleFrames = [:]
        }
        let limit = restoreLimit
        // Near the end of the book the target may be unable to reach the top: on screen below the line is its place.
        // The same at the start of the book: the first block cannot go lower than the content's top.
        let targetHeldByTheEnd = (restoreTarget.flatMap { lastFrames[$0] }.map { $0.minY > viewportTop } == true
            && endOfBookOnScreen) || (restoreTarget == 0 && restoreOffset == 0 && lastFrames[0] != nil)
        // The last re-issue landed the target exactly where the one before did: the layout is measured and stable,
        // so the scroll itself is what is off (`.top` short of the reading line): correct the anchor below instead.
        let targetMinY = restoreTarget.flatMap { lastFrames[$0] }
            .flatMap { JumpSettling.isNear($0, viewportHeight: viewportHeight) ? Double($0.minY) : nil }
        let retryStuck = restorePoints == nil && targetMinY != nil
            && lastRetryMinY.map { abs($0 - targetMinY!) <= 0.5 } == true
        if let target = restoreTarget, !targetHeldByTheEnd, !retryStuck,
           RestoreCheck.needsRetry(top: VisibleBlockResolver.topIndex(frames: lastFrames, viewportTop: viewportTop),
                                   target: target, attempts: restoreAttempts, limit: limit) {
            restoreAttempts += 1
            lastRetryMinY = targetMinY
            settledMinY = nil
#if DEBUG
            traceCheckState("retry")
#endif
            jumpRequest = JumpRequest(index: restoreJumpIndex ?? target, anchorY: restoreAnchor)
            scheduleRestoreCheck()
            return
        }
        if let target = restoreTarget, let points = restorePoints, let frame = lastFrames[target],
           let anchor = handBackAnchor(target: target, points: points, frame: frame) {
            inBlockAttempts += 1
            restoreAnchor = anchor
            jumpRequest = JumpRequest(index: restoreJumpIndex ?? target, anchorY: anchor)
            scheduleRestoreCheck()
            return
        }
        // Also for offset 0 (a chapter's start): the block's top must be at the reading line, not merely the
        // block at the top. A landing a few points off would leave a heading half under the bar.
        if let target = restoreTarget, restorePoints == nil, !targetHeldByTheEnd, let frame = lastFrames[target],
           let anchor = inBlockAnchor(target: target, frame: frame, limit: limit) {
            inBlockAttempts += 1
            settledMinY = nil
            restoreAnchor = anchor
#if DEBUG
            traceCheckState("inblock")
#endif
            jumpRequest = JumpRequest(index: target, anchorY: anchor)
            scheduleRestoreCheck()
            return
        }
        // In place. Under a cover, reveal only once it stays in place: one more check without scrolling, so a
        // target that the lazy stack is still moving (it measures the blocks above at their real heights) is
        // caught and brought back above, not revealed mid-move and then saved where it drifted to.
        if coversText, restorePoints == nil, let target = restoreTarget, let frame = lastFrames[target],
           stabilityChecks < limit, !RestoreCheck.isStable(previousMinY: settledMinY, minY: Double(frame.minY)) {
            settledMinY = Double(frame.minY)
            stabilityChecks += 1
#if DEBUG
            traceCheckState("confirm")
#endif
            scheduleRestoreCheck()
            return
        }
#if DEBUG
        traceCheckState("done")
#endif
        finishRestore(reason: targetHeldByTheEnd ? "end" : (restoreAttempts >= limit ? "retries-out" : "inplace"))
    }

#if DEBUG
    /// The target of the restore that ended last (trace only).
    private var traceLastTarget: Int?
    private var traceEndedAt: Date?
#endif

    /// The restore is over: the position follows the scroll view again and the cover (if any) lifts.
    private func finishRestore(reason: String = "inplace") {
#if DEBUG
        if tracesRestores {
            let elapsed = String(format: "after %.2fs", Date().timeIntervalSince(restoreBegan))
            trace("end \(reason) checks=\(restoreAttempts)+\(inBlockAttempts)+\(stabilityChecks) \(elapsed)")
            traceLastTarget = restoreTarget
            traceEndedAt = Date()
            tracePostReports = 8
        }
#endif
        restoreTarget = nil
        isRestoring = false
        let jumped = isSettling && announcesArrival
        announcesArrival = false
        endSettlingCover()
        if !isPositioned { isPositioned = true }
        if jumped { arrival = Arrival(announcement: arrivalAnnouncement) }
        // Landed near the first loaded block (a chapter's start): the chapter before it goes above once idle.
        if autoScroll == .off, ChapterWindow.needsPrepend(top: currentIndex, window: window,
                                                          chapterStarts: flat.chapterStarts, count: flat.count) {
            schedulePrepend()
        }
    }

    /// Covers the text until the jump has landed (`restoreSettled`), with the indicator after a moment.
    private func beginSettlingCover() {
        if !isSettling { isSettling = true }
        scheduleSettlingIndicator()
    }

    /// Shows the progress indicator if the text is still covered after `settlingIndicatorDelay`.
    private func scheduleSettlingIndicator() {
        guard settlingIndicatorTask == nil, !showsSettlingIndicator else { return }
        let delay = settlingIndicatorDelay
        settlingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.settlingIndicatorTask = nil
            if self.coversText, !self.showsSettlingIndicator { self.showsSettlingIndicator = true }
        }
    }

    private func endSettlingCover() {
        settlingIndicatorTask?.cancel()
        settlingIndicatorTask = nil
        if isSettling { isSettling = false }
        if showsSettlingIndicator { showsSettlingIndicator = false }
    }

    /// What VoiceOver says when a covered jump is revealed: the chapter there, else the progress.
    private var arrivalAnnouncement: String {
        flat.chapterTitle(at: currentIndex, characterOffset: currentOffset) ?? progressText()
    }

    /// The anchor for another hand-back jump, or nil when it landed within `handBackTolerance` (or retries ran
    /// out). All blocks move together, so the error of the target block corrects the anchor of the jump block.
    private func handBackAnchor(target: Int, points: Double, frame: BlockFrame) -> Double? {
        let wanted = Double(viewportTop) - points
        let error = Double(frame.minY) - wanted
        guard RestoreCheck.needsInBlockRetry(landedMinY: Double(frame.minY), wantedMinY: wanted,
                                             attempts: inBlockAttempts, tolerance: Self.handBackTolerance),
              let jumpFrame = lastFrames[restoreJumpIndex ?? target] else { return nil }
        let previous = restoreAnchor ?? 0
        return InBlockPosition.correctedAnchorY(previous, error: error,
                                                blockHeight: Double(jumpFrame.maxY - jumpFrame.minY),
                                                viewportHeight: Double(viewportHeight))
    }

    /// The anchor for another in-block jump, or nil when the saved line is at the top (or retries ran out).
    /// With offset 0 the block's own top must be at the reading line, within `JumpSettling.startTolerance`; the
    /// same `.top` scroll is then simply re-issued (now on measured heights): no anchor is ever computed for it.
    private func inBlockAnchor(target: Int, frame: BlockFrame, limit: Int = RestoreCheck.maxRetries) -> Double? {
        let height = Double(frame.maxY - frame.minY)
        let fraction = InBlockPosition.fraction(forCharacterOffset: restoreOffset, in: flat.blocks[target].text)
        let wanted = InBlockPosition.wantedMinY(fraction: fraction, blockHeight: height,
                                                viewportTop: Double(viewportTop))
        let tolerance = restoreOffset > 0 ? InBlockPosition.tolerance : JumpSettling.startTolerance
        guard RestoreCheck.needsInBlockRetry(landedMinY: Double(frame.minY), wantedMinY: wanted,
                                             attempts: inBlockAttempts, tolerance: tolerance, limit: limit) else { return nil }
        guard restoreOffset > 0 else { return measuredStartAnchor(minY: Double(frame.minY), wanted: wanted, height: height) }
        if let previous = restoreAnchor {
            return InBlockPosition.correctedAnchorY(previous, error: Double(frame.minY) - wanted,
                                                    blockHeight: height, viewportHeight: Double(viewportHeight))
        }
        return InBlockPosition.anchorY(fraction: fraction, blockHeight: height,
                                       viewportHeight: Double(viewportHeight), viewportTop: Double(viewportTop))
    }

    /// The anchor that brings a block's start (offset 0) to the reading line, from where the last scroll put it.
    ///
    /// `.top` does not always put the block's top at the reading line (when the scroll space starts at the top of the
    /// screen, it puts it under the bar). The first correction assumes the model of
    /// `InBlockPosition.anchorY` (moving the anchor by `dy` moves the block by `dy * (V - H)`); once two landings with
    /// different anchors are known, their measured slope is used instead (a secant step), so a scroll view that maps
    /// anchors differently is still brought to the line in a step or two.
    private func measuredStartAnchor(minY: Double, wanted: Double, height: Double) -> Double? {
        guard viewportHeight > 0 else { return nil }
        let current = restoreAnchor ?? 0
        defer { anchorSample = (current, minY) }
        if let sample = anchorSample, abs(current - sample.anchor) > 1e-6 {
            let slope = (minY - sample.minY) / (current - sample.anchor)
            if slope.isFinite, slope >= 1 {
                return min(max(current + (wanted - minY) / slope, -8), 8)
            }
        }
        return InBlockPosition.correctedAnchorY(current, error: minY - wanted, blockHeight: height,
                                                viewportHeight: Double(viewportHeight))
    }

    /// Called by the view once it appeared: scroll to the saved block, then to the saved line in it. Both
    /// moves happen while the text is still transparent (`isPositioned`), so the reader appears at the line.
    func restoreInitialPosition() {
        if flat.isEmpty { isPositioned = true }
#if DEBUG
        windowLoad = (Date(), startIndex, window.count)
#endif
        beginRestore(target: startIndex, offset: startOffset)
        // A long opening shows the same indicator as a far jump.
        if !isPositioned { scheduleSettlingIndicator() }
        jumpRequest = JumpRequest(index: startIndex, anchorY: restoreAnchor)
        // The opened book becomes the one the complications show.
        publishComplication(force: false)
    }

    func jump(to index: Int, characterOffset: Int = 0) {
        let i = flat.clamped(index)
        let offset = flat.clampedOffset(characterOffset, in: i)
        // A target outside the loaded blocks loads its chapter (a new scroll view): nothing above it but that
        // chapter's own blocks.
        loadWindow(for: i)
        // Before `beginRestore`, so its checks already run at the covered pace. A block measured long ago (and
        // kept by the lazy stack) far from the screen does not land exactly either: only a near one is uncovered.
        let laidOut = lastFrames[i].map { JumpSettling.isNear($0, viewportHeight: viewportHeight) } ?? false
        if JumpSettling.covers(isPositioned: isPositioned, targetLaidOut: laidOut) {
            announcesArrival = true
            beginSettlingCover()
        }
        beginRestore(target: i, offset: offset)
        pageTimer.reset(at: now())
        currentIndex = i
        currentOffset = offset
        persistCurrent()
        jumpRequest = JumpRequest(index: i, anchorY: restoreAnchor)
    }

    // MARK: Chapter window

    /// Loads the window a jump to `target` needs, unless the loaded one already holds it. A window starting at another
    /// block replaces the rows: the frames measured for the old ones are dropped, and the restore waits for the new
    /// ones like after a re-layout.
    private func loadWindow(for target: Int) {
        guard !flat.isEmpty, !window.contains(target) else { return }
        let next = ChapterWindow.window(for: target, chapterStarts: flat.chapterStarts, count: flat.count)
#if DEBUG
        trace("window \(window.lowerBound)-\(window.upperBound) -> \(next.lowerBound)-\(next.upperBound)")
#endif
        if next.lowerBound != window.lowerBound {
            lastFrames = [:]
            staleFrames = [:]
            framesStaleSince = Date()
        }
        cancelPrepend()
        window = next
        windowIsLazy = next.count > Self.lazyWindowThreshold
#if DEBUG
        windowLoad = (Date(), target, next.count)
#endif
    }

    /// The reader is in the window's first chapter: prepend the previous chapter once the scroll is idle (no frame
    /// report for `prependIdle`), checked every `prependIdle`. Never during a restore or auto-scroll; a deferred
    /// prepend looks again at the position it then finds. (Close to the edge it does not wait: `prependIsUrgent`.)
    private func schedulePrepend() {
        guard prependTask == nil else { return }
        let idle = Self.prependIdle
        prependTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.prependTask = nil
            self.prependIfIdle()
        }
    }

    private func prependIfIdle() {
        guard ChapterWindow.needsPrepend(top: currentIndex, window: window, chapterStarts: flat.chapterStarts,
                                         count: flat.count) else { return }
        let idle = Date().timeIntervalSince(lastFrameReport) >= Self.prependIdle
        guard idle || ChapterWindow.prependIsUrgent(top: currentIndex, window: window) else {
            schedulePrepend()
            return
        }
        prepend(keeping: currentIndex)
    }

    /// Prepends the previous chapter, keeping `block` (at the reading line) where it is: the reader scrolls to the
    /// same point of it in the same update as the new rows (`prependKeep`), and `prependCheckDelay` later the view
    /// model checks it (`checkPrepend`).
    private func prepend(keeping block: Int) {
        guard !isRestoring, autoScroll == .off, pendingPrepend == nil, window.contains(block),
              let frame = lastFrames[block] else { return }
        // Under a finger the keep-scroll would be undone by the drag (`isUserTouching`): once it lifts.
        guard !isUserTouching else {
            prependWaitsForTouchEnd = true
            prependTask?.cancel()
            prependTask = nil
            return
        }
        prependTask?.cancel()
        prependTask = nil
        let spans = lastFrames.mapValues { AutoScroll.Span(minY: Double($0.minY), maxY: Double($0.maxY)) }
        let pointsAbove = Double(viewportTop) - Double(frame.minY)
        let cursor = AutoScroll.Cursor(index: block, offset: pointsAbove)
        guard let keep = AutoScroll.scrollTarget(cursor, frames: spans, viewportTop: Double(viewportTop),
                                                 viewportHeight: Double(viewportHeight)) else { return }
        let prepended = ChapterWindow.prependingPreviousChapter(to: window, chapterStarts: flat.chapterStarts,
                                                                count: flat.count)
        let trimmed = ChapterWindow.trimmedBelow(prepended, readingAt: block, chapterStarts: flat.chapterStarts,
                                                 count: flat.count)
        pendingPrepend = PendingPrepend(block: block, minY: Double(frame.minY))
        userScrolledSincePrepend = isUserScrolling
#if DEBUG
        let before = String(format: "minY=%.1f", Double(frame.minY))
        let scrolling = isUserScrolling ? " while scrolling" : ""
        trace("prepend \(window.lowerBound)-\(window.upperBound) -> \(trimmed.lowerBound)-\(trimmed.upperBound) "
              + "block=\(block) \(before)\(scrolling)")
#endif
        prependKeep = JumpRequest(index: keep.index, anchorY: keep.anchorY)
        window = trimmed
        prependCheckTask?.cancel()
        let delay = Self.prependCheckDelay
        prependCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.prependCheckTask = nil
            self.checkPrepend()
        }
    }

    /// The finger lifted with a prepend due: made at once close to the edge (the text may still be decelerating
    /// towards it), otherwise once the scroll is idle, for the block at the reading line now.
    private func prependAfterTouch() {
        guard autoScroll == .off, !isRestoring, pendingPrepend == nil else { return }
        let top = VisibleBlockResolver.lineIndex(frames: lastFrames, viewportTop: viewportTop) ?? currentIndex
        guard ChapterWindow.needsPrepend(top: top, window: window, chapterStarts: flat.chapterStarts,
                                         count: flat.count) else { return }
        if ChapterWindow.prependIsUrgent(top: top, window: window) {
            prepend(keeping: top)
        } else {
            schedulePrepend()
        }
    }

    /// `prependCheckDelay` after a prepend, once every row has reported its new place: the block that was at the
    /// reading line must be where it was. If it moved and nobody scrolled since the prepend, the scroll view is
    /// brought back to the same point of that block (a restore like auto-scroll's hand-back); if it is not even
    /// measured any more, back to the saved line. Once the reader has scrolled, its place is the reader's: the check
    /// never pulls the text back from under a finger or a fling.
    private func checkPrepend() {
        guard let pending = pendingPrepend else { return }
        pendingPrepend = nil
        let scrolled = userScrolledSincePrepend || isUserScrolling
        userScrolledSincePrepend = false
        let frames = lastFrames
        guard let frame = frames[pending.block] else {
#if DEBUG
            trace("prepend lost block \(pending.block): blocks=\(frames.keys.min() ?? -1)-\(frames.keys.max() ?? -1)"
                  + (scrolled ? " while scrolling" : ""))
#endif
            guard !isRestoring, !scrolled else { return }
            beginRestore(target: currentIndex, offset: currentOffset)
            jumpRequest = JumpRequest(index: currentIndex, anchorY: restoreAnchor)
            return
        }
        let moved = Double(frame.minY) - pending.minY
#if DEBUG
        trace(String(format: "prepend kept block %ld: moved=%.1f", pending.block, moved) + (scrolled ? " while scrolling" : ""))
#endif
        guard abs(moved) > Self.prependTolerance, !isRestoring, !scrolled else { return }
        keepPoint(of: pending.block, pointsAbove: Double(viewportTop) - pending.minY, frames: frames)
    }

    /// A jump or a re-layout replaces the window: a prepend waiting or being checked no longer applies.
    private func cancelPrepend() {
        prependTask?.cancel()
        prependTask = nil
        prependCheckTask?.cancel()
        prependCheckTask = nil
        pendingPrepend = nil
        userScrolledSincePrepend = false
        prependWaitsForTouchEnd = false
        prependKeep = nil
    }

    /// Brings the scroll view back so that `pointsAbove` points of `block` are above the reading line, the way
    /// auto-scroll's hand-back does, without changing the saved position.
    private func keepPoint(of block: Int, pointsAbove: Double, frames: [Int: BlockFrame]) {
        let spans = frames.mapValues { AutoScroll.Span(minY: Double($0.minY), maxY: Double($0.maxY)) }
        let cursor = AutoScroll.Cursor(index: block, offset: pointsAbove)
        guard let target = AutoScroll.scrollTarget(cursor, frames: spans, viewportTop: Double(viewportTop),
                                                   viewportHeight: Double(viewportHeight)) else { return }
        beginRestore(target: block)
        restorePoints = pointsAbove
        restoreJumpIndex = target.index
        restoreAnchor = target.anchorY
        jumpRequest = JumpRequest(index: target.index, anchorY: target.anchorY)
    }

    // MARK: Bookmarks

    /// The position a new bookmark would mark: the line at the top of the screen.
    private var bookmarkPosition: BookPosition? {
        flat.position(at: currentIndex, characterOffset: currentOffset)
    }

    /// Whether the line at the top of the screen is bookmarked already (the menu then says "Bookmarked").
    var isCurrentPositionBookmarked: Bool {
        guard let position = bookmarkPosition else { return false }
        return bookmarks.contains(position)
    }

    /// Bookmarks the line at the top of the screen. Nil for an empty book; `.duplicate` when that line is
    /// bookmarked already (nothing changes).
    @discardableResult
    func addBookmark() -> BookmarkList.AddResult? {
        guard let position = bookmarkPosition,
              let bookmark = Bookmark.make(at: position, in: book,
                                           chapterTitle: flat.chapterTitle(at: currentIndex, characterOffset: currentOffset),
                                           createdAt: now()) else { return nil }
        let result = bookmarks.add(bookmark)
        if case .added = result { bookmarkStore.save(bookmarks, documentHash: documentHash) }
        return result
    }

    func deleteBookmark(id: UUID) {
        guard bookmarks.remove(id: id) else { return }
        bookmarkStore.save(bookmarks, documentHash: documentHash)
    }

    /// Swipe to delete in the bookmark list (offsets into `bookmarks.items`).
    func deleteBookmarks(atOffsets offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        bookmarkStore.save(bookmarks, documentHash: documentHash)
    }

    /// Opens the book at `bookmark`: its XPointer found in this copy of the book, else its stored position,
    /// else its percentage.
    func jump(to bookmark: Bookmark) {
        guard !flat.isEmpty else { return }
        if let position = bookmark.resolvedPosition(in: book, resolver: resolver),
           let index = flat.flatIndex(for: position) {
            jump(to: index, characterOffset: position.characterOffset)
        } else {
            jump(to: flat.index(forPercentage: bookmark.percentage))
        }
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
        syncedPositionReached()
    }

    /// The reader now stands at the synced position: the service's row is no longer offered or shown as
    /// newer, and the complications show the new position at once (#132).
    private func syncedPositionReached() {
        sync.offerAccepted(book: bookIdentity)
        publishComplication(force: true)
    }

    /// The active sync service (`SyncConnectorDescriptor.id`), for the offer's wording.
    var syncConnectorID: String? { sync.activeConnectorID }

    /// Whether the reader menu offers "Go to Synced Position": only while a sync service is set up and this
    /// book syncs with it (#167).
    var canGoToSyncedPosition: Bool { sync.isConfigured && syncsThisBook }

    /// Whether a sync service is set up (the reader menu then shows the per-book switch).
    var isSyncConfigured: Bool { sync.isConfigured }

    /// Whether this book syncs with the active service (false while sync is off). When it does not, nothing is
    /// fetched or pushed for it and the reader shows no sync glyph (#167).
    var syncsThisBook: Bool { sync.syncs(documentHash) }

    /// Whether the iPhone reported this book outside the Readest library while Readest is the service: the reader
    /// menu then shows a note instead of "Sync Progress for This Book", which could not make it sync (#167).
    var isOutsideSyncLibrary: Bool { sync.isOutsideLibrary(documentHash) }

    /// The active service's name ("Readest", "KOReader Sync") for the switch's footnote; empty while sync is off.
    var syncServiceName: String { sync.activeServiceName ?? "" }

    /// "Sync Progress for This Book" in the reader menu (default on; synced with the iPhone).
    var isSyncSwitchedOn: Bool { sync.isSwitchedOn(documentHash) }

    func setSyncSwitchedOn(_ isOn: Bool) {
        sync.setSyncEnabled(isOn, bookKey: documentHash)
        if !isOn {
            // An offer from the service is no longer relevant: the book now stays on this watch.
            remoteOffer = nil
            showRemoteOffer = false
        }
        objectWillChange.send()
    }

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
            if target == Spot(index: currentIndex, offset: currentOffset) {
                sync.offerAccepted(book: bookIdentity)
                return .alreadyThere
            }
            go(to: remote)
            syncedPositionReached()
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

    /// "Stay Here": this remote position is not offered again on open, nor shown by the complications and
    /// the Library, until the service holds another one (#132).
    func declineRemote() {
        remoteOffer = nil
        sync.offerDeclined(book: bookIdentity)
    }

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
        InlineImageCache.shared.removeAll()
        restoreTask?.cancel()
        prependTask?.cancel()
        prependTask = nil
        prependCheckTask?.cancel()
        prependCheckTask = nil
        settlingIndicatorTask?.cancel()
        settlingIndicatorTask = nil
        if autoScroll != .off { autoScroll = .off }
        autoScrollMotion = AutoScroll.Motion()
        reportProgress(immediately: true)
        // Closing the book: always refresh the complications with the final position.
        publishComplication(force: true)
    }
}
