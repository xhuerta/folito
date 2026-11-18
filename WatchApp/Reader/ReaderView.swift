import SwiftUI
import Accessibility
import ReaderCore

/// Scrolling reader.
///
/// Digital Crown: we deliberately rely on the native `ScrollView` crown support (watchOS scrolls a
/// `ScrollView` with the crown automatically, with haptic detents and momentum) instead of
/// `.digitalCrownRotation`, which would replace that behaviour and require manual offset math over a
/// lazily-laid-out list of thousands of blocks.
///
/// Accessibility: each block is one VoiceOver element and headings carry the header trait (rotor
/// "Headings"); the text follows Bold Text, Increase Contrast and, with "Match System Text Size", Dynamic
/// Type (see `ReaderAccessibilityReader`). Programmatic jumps (restore, chapters, remote position) never
/// animate the scroll; the cover over a far jump lifts with a cross-fade, which Reduce Motion turns into an
/// instant reveal. With the wrist down (Always On, reduced luminance)
/// the page switches to a dim black palette and the sync glyph is hidden.
///
/// Top bar (#106): the navigation bar hides while scrolling down through the text and comes back when
/// scrolling up a little or on a tap on the text (`BarAutoHide`); with VoiceOver on it never hides. The
/// back button is the system's own (nothing is placed in the leading / cancellation slot, which on watchOS
/// replaces the back button and with it the left-edge swipe back), so leaving the book always works from the
/// visible bar. The time in the corner is drawn by the system: watchOS documents no API for an app to hide
/// it, so it is not requested. With the bar hidden the scroll view's top inset drops to 0 and the text would
/// scroll under the time, so while the bar is hidden an overlay in the page colour (`ClockBand`) covers the
/// time area at the top of the screen: text scrolling up disappears behind it (#125). It is pinned to the
/// root, outside the scroll content, and is not an inset, so the text never shifts when the bar toggles.
/// What remains on screen with the bar hidden
/// is captured by `WatchReaderTopBarTests` (attachment "watch-reader-bar-hidden").
///
/// Opening (#125): the text stays transparent until the view model has scrolled to the saved block and the
/// saved line inside it (`ReaderViewModel.isPositioned`), so the book appears at that line without a
/// visible move, and every programmatic scroll is announced to `BarAutoHide`, which then cannot hide the bar.
///
/// Far jumps (#174: a chapter, a bookmark, the synced position) work the same way: a jump to a block that is not
/// laid out yet covers the text (`ReaderViewModel.isSettling`, see `JumpSettling`) while the lazy stack's
/// estimated landing is corrected, and reveals it once the target line is at the top edge, so the reader sees
/// the old place and then the new one, never the hops in between. The cover is the page colour; after a moment
/// it shows a small progress indicator (also while a book opens). It lifts with a short cross-fade, or at once
/// with Reduce Motion, and VoiceOver then announces the chapter arrived at, once. A jump to a block's start (a
/// chapter) is over only once that block's top is at the reading line, not merely once it is the top block.
///
/// Text size and other layout changes (build 48 feedback) are covered the same way: the saved block and character
/// offset are frozen the moment the layout key changes, the text is covered while that line is brought back to the
/// top edge, and it is revealed in one move, without an announcement.
///
/// Auto-scroll (#67): started from Reading Options, never by itself. While it runs, the reader shows the
/// blocks around the reading line in a plain stack over the scroll view (an `AutoScroll.Window`, laid out at
/// the same width so every line breaks the same) and moves it with an offset computed on every display frame
/// from `AutoScroll.Motion` (a `TimelineView(.animation)`), so the text glides with sub-pixel steps; the
/// scroll view underneath is hidden and stands still. Nothing is published per frame: the window changes
/// only when a block scrolls off the top or one is added below, and the reading position is saved every few
/// seconds. On pause or stop the scroll view is brought to the exact point shown (`handBackAutoScroll`) and
/// the stack stays on screen until it has landed, so nothing visibly moves. A transparent layer over the text
/// (only while it runs) holds the Digital Crown (speed, one detent and haptic per level, the badge shows
/// "Speed N of 7" at each change) and pauses on a tap. The top bar hides while it runs, like reading by hand,
/// and shows when it pauses, so Reading Options (where it stops) is one tap away; a tap on the text resumes.
/// While paused the crown scrolls the text by hand, as when reading, and auto-scroll resumes from there.
/// It pauses when a sheet or an alert opens, when the wrist goes down (Always On) or the app leaves the
/// foreground, stops at the end of the book and on leaving it. It runs only while the screen is on: reading is
/// not one of the session types `WKExtendedRuntimeSession` allows, so the app does not keep itself running.
struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var typography: TypographyModel
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @AppStorage(ReaderSettings.tapToLookUpKey) private var tapToLookUp = true
    @State private var showMenu = false
    @State private var lookupAfterMenu = false
    /// Auto-hide state, updated on every scroll frame without re-rendering the view; `barHidden` mirrors
    /// its `isHidden` and changes only when the bar actually hides or shows.
    @State private var autoHide = BarAutoHideBox()
    @State private var barHidden = false
    /// The scroll view's origin in global coordinates: the origin of `scrollSpace`, for taps in the edge strip.
    @State private var scrollOrigin: CGPoint = .zero
    /// The reading line on screen (global y of the bar's bottom edge, latched while the bar is hidden; see
    /// `ReadingLine`). The model gets it in the scroll view's own coordinates (`ReadingLine.inScrollSpace`).
    @State private var readingLineOnScreen: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Start auto-scroll once the menu is gone (its "Start Auto-Scroll" button).
    @State private var autoScrollAfterMenu = false
    /// What the Digital Crown drives: the text (scrolls it) or, while auto-scroll runs, its speed. One focus
    /// value for both, so they can never both claim it (two separate focus states left the scroll view
    /// focused, and the crown stopped changing the speed after the first re-render).
    @FocusState private var crownFocus: CrownTarget?
    /// While auto-scroll shows the text itself (running, and after a pause until the scroll view has landed
    /// at the same point): which blocks, where.
    @State private var autoScrollWindow: AutoScroll.Window?
    /// Heights of the blocks in the auto-scroll window, measured there.
    @State private var autoScrollHeights: [Int: Double] = [:]
    /// Left edge and width of the text in the scroll view (every block fills the column's width), so the
    /// auto-scroll window lays out every line exactly as the scroll view does.
    @State private var autoScrollLeading: CGFloat = 0
    @State private var autoScrollTextWidth: CGFloat = 0
    /// The scroll view's global origin when the auto-scroll window was made: the window's coordinates are the
    /// scroll view's as they were then, so the text stays put on screen even if the bar hiding moves the
    /// scroll view's frame. Hand-back converts back to the scroll view's coordinates of the moment.
    @State private var autoScrollOrigin: CGPoint = .zero
    /// Auto-scroll paused or stopped and the scroll view is being brought to the point shown.
    @State private var autoScrollHandingBack = false
    /// Line height and paragraph spacing the auto-scroll housekeeping runs with (set when it starts).
    @State private var autoScrollMetrics: (lineHeight: Double, spacing: Double)?
    /// Auto-scroll stopped running while a sheet was up: give the crown back to the text once it is gone.
    @State private var crownReturnPending = false
    /// The crown's value on the auto-scroll layer: one detent per speed level.
    @State private var crownValue = Double(AutoScroll.defaultLevel)
    /// The speed badge, shown for a moment after a speed change.
    @State private var showSpeedBadge = false
    @State private var speedBadgeToken = 0
    private var readerAccessibility = ReaderAccessibilityReader()
    private static let scrollSpace = "reader.scroll"

    enum CrownTarget: Hashable {
        case text
        case autoScroll
    }

    init(model: ReaderViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        // Fonts and colours are resolved once per typography / accessibility change, not per block per render.
        let style = typography.style(for: readerAccessibility.value)
        // Auto-scroll speeds are in lines: one line of body text in points.
        let autoScrollLineHeight = AutoScroll.lineHeight(pointSize: style.spec(for: .paragraph).pointSize,
                                                         lineSpacing: style.typography.lineSpacing)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style.typography.paragraphSpacing) {
                    ForEach(0..<model.flat.count, id: \.self) { index in
                        BlockStyledText(block: model.flat.blocks[index], style: style)
                            .equatable()
                            .modifier(UITestBlockHeight())
                            .contentShape(Rectangle())
                            .onTapGesture { location in tapped(block: index, at: location, style: style) }
                            // Available from the VoiceOver actions rotor even with tap-to-look-up off.
                            .accessibilityAction(named: Text("Look Up a Word")) { model.beginLookup(at: index) }
                            // One action per note reference in the block ("Footnote 3"), opening the note (#66).
                            .modifier(NoteAccessibilityActions(notes: model.flat.blocks[index].notes ?? []) { note in
                                model.showNote(note, inBlock: index)
                            })
                            // VoiceOver's two-finger scrub leaves the book from any paragraph (#118).
                            .accessibilityAction(.escape) { dismiss() }
                            .accessibilityIdentifier("readerBlock")
                            .id(index)
                            .background(
                                GeometryReader { geo in
                                    let f = geo.frame(in: .named(Self.scrollSpace))
                                    Color.clear.preference(key: BlockFramesKey.self,
                                                           value: [index: BlockFrame(minY: f.minY, maxY: f.maxY, width: f.width,
                                                                                     minX: f.minX)])
                                })
                    }
                    if model.flat.isEmpty {
                        Text("This book has no text.").foregroundStyle(style.secondaryColor)
                    }
                }
                .padding(.horizontal, style.typography.horizontalMargin)
                // A tap between two paragraphs (the stack's spacing belongs to no block) or in the side margins
                // reaches no block's tap gesture: here it shows a hidden bar too (or resumes a paused auto-scroll),
                // so a tap anywhere on the text always brings the bar back. Taps on a block keep their own action
                // (a child's gesture wins over this one).
                .contentShape(Rectangle())
                .onTapGesture { tappedBetweenBlocks() }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentTopKey.self, value: geo.frame(in: .named(Self.scrollSpace)).minY)
                })
                // Laid out and scrolled as usual, but not shown until the saved line (or a far jump's
                // target line) is at the top edge.
                .opacity(model.coversText ? 0 : 1)
                .accessibilityHidden(model.coversText)
            }
            .coordinateSpace(name: Self.scrollSpace)
            // While auto-scroll shows the text itself, the scroll view stays laid out (its frames place the
            // hand-back) but is hidden, silent and untouchable, with no indicator flashing beside the crown.
            .scrollIndicators(autoScrollWindow == nil ? .automatic : .never)
            .opacity(autoScrollWindow == nil ? 1 : 0)
            .accessibilityHidden(autoScrollWindow != nil)
            .allowsHitTesting(autoScrollWindow == nil)
            // Set when auto-scroll hands the text back (`returnCrownToText`), so the crown scrolls the text again
            // at once instead of staying with the auto-scroll layer that went away.
            .focused($crownFocus, equals: .text)
            // How far the text is scrolled, for the bar auto-hide. Read from the scroll view itself where
            // available: the content-top preference below is not delivered reliably while scrolling on
            // watchOS (the text scrolled hundreds of points and the bar never hid).
            .modifier(ScrollDistanceReader { offset in
                updateBar { $0.scrolled(to: offset, at: Date(), voiceOver: voiceOver) }
            })
            // The scroll view runs under the navigation bar: its top inset is where reading starts.
            .background(GeometryReader { geo in
                Color.clear
                    .preference(key: ViewportTopKey.self, value: geo.safeAreaInsets.top)
                    .preference(key: ViewportHeightKey.self, value: geo.size.height)
                    .preference(key: ViewportOriginKey.self, value: geo.frame(in: .global).origin)
            })
            .onPreferenceChange(ViewportOriginKey.self) { origin in
                scrollOrigin = origin
                model.viewportTop = ReadingLine.inScrollSpace(screenLine: readingLineOnScreen, scrollOriginY: origin.y)
                model.traceGeometry(String(format: "geo origin=%.1f line=%.1f vt=%.1f bar=%ld", Double(origin.y),
                                   Double(readingLineOnScreen), Double(model.viewportTop), barHidden ? 0 : 1))
            }
            .onPreferenceChange(ViewportTopKey.self) { top in
                // The reading line stays where it is on screen while the bar is hidden (see `ReadingLine`).
                readingLineOnScreen = ReadingLine.updated(current: readingLineOnScreen, measured: top, barShown: !barHidden)
                model.viewportTop = ReadingLine.inScrollSpace(screenLine: readingLineOnScreen, scrollOriginY: scrollOrigin.y)
                model.traceGeometry(String(format: "geo inset=%.1f line=%.1f origin=%.1f vt=%.1f bar=%ld", Double(top),
                                   Double(readingLineOnScreen), Double(scrollOrigin.y), Double(model.viewportTop),
                                   barHidden ? 0 : 1))
            }
            .onPreferenceChange(ContentTopKey.self) { top in
                // Fallback for watchOS 10 only (see `ScrollDistanceReader`).
                guard !ScrollDistanceReader.readsScrollGeometry else { return }
                let offset = model.viewportTop - top
                updateBar { $0.scrolled(to: offset, at: Date(), voiceOver: voiceOver) }
            }
            .onPreferenceChange(ViewportHeightKey.self) { model.viewportHeight = $0 }
            // With the layout they were measured in: the first frames of a new text size freeze the position
            // (`ReaderViewModel.layoutChanged(to:)`) instead of being read as the reader scrolling.
            .onPreferenceChange(BlockFramesKey.self) { model.blockFramesChanged($0, layoutKey: style.layoutKey) }
            // Restores and jumps are not reading: they must not hide the bar.
            .onChange(of: model.isRestoring) { restoring in
                // Auto-scroll's own motion is not reading by hand either: offsets never toggle the bar then.
                updateBar { $0.programmaticScroll(restoring || model.isAutoScrollActive) }
            }
            .onChange(of: model.jumpRequest) { request in
                guard let request else { return }
                DispatchQueue.main.async {
                    model.trace("scroll \(request.index) a=\(request.anchorY.map { String(format: "%.3f", $0) } ?? "top")")
                    // Instant jump (no animation), also under Reduce Motion.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // An in-block restore passes an anchor that puts the saved line at the top edge.
                        proxy.scrollTo(request.index, anchor: request.anchorY.map { UnitPoint(x: 0, y: $0) } ?? .top)
                    }
                }
            }
            // The auto-scrolled text, over the (hidden) scroll view and in its coordinates.
            .overlay(alignment: .topLeading) {
                if let window = autoScrollWindow {
                    autoScrollColumn(window, style: style, lineHeight: autoScrollLineHeight)
                }
            }
            // Over the text (and a paused auto-scroll window) while the book opens or a far jump settles (#174).
            .overlay {
                SettlingCover(covers: model.coversText, showsIndicator: model.showsSettlingIndicator,
                              color: style.background, textColor: style.secondaryColor, reduceMotion: reduceMotion)
            }
            // UI tests only (`-UITestingReaderPosition`): the saved position, to check where a jump landed.
            .overlay(alignment: .bottomTrailing) {
                if UITesting.exposesReaderPosition {
                    UITestReaderPosition(index: model.currentIndex, offset: model.currentOffset,
                                         settled: !model.isRestoring && !model.coversText)
                }
                // UI tests only (`-UITestingRestoreTrace`): the restore machinery's last events.
                if UITesting.tracesRestores {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("restoreTrace")
                        .accessibilityValue(Text(verbatim: (model.restoreTrace + ["geometry:"] + model.geometryTrace) // i18n-ignore: UI-test hook
                            .joined(separator: " | ")))
                        .allowsHitTesting(false)
                }
            }
            // Auto-scroll housekeeping a few times a second (never per frame): makes and updates the window,
            // saves the position, stops at the end, finishes the hand-back. Restarted when the layout changes.
            .task(id: "\(model.isAutoScrollActive || autoScrollWindow != nil)|\(style.layoutKey)") {
                await maintainAutoScroll(lineHeight: autoScrollLineHeight,
                                         spacing: Double(style.typography.paragraphSpacing))
            }
        }
        .background(style.background)
        // Covers the system time while the bar is hidden (#125). On the root, outside the scroll view.
        .overlay(alignment: .top) {
            ClockBandOverlay(barHidden: barHidden, color: style.background)
        }
        // The left-edge swipe back (#118), with the bar shown or hidden. Above the scroll view so the edge
        // touch reaches it first; a thin strip along the text margin that forwards taps to the text. Never a
        // drag gesture on the scroll view or an ancestor: even a simultaneous one stops the scroll view panning.
        .overlay(alignment: .leading) {
            EdgeSwipeBackStrip(onBack: { dismiss() }, onTap: { edgeTapped(at: $0, style: style) })
        }
        // Only while auto-scroll runs: with it off (or paused) nothing covers the text and its taps.
        .overlay {
            if model.autoScroll == .running {
                autoScrollLayer
            }
        }
        .overlay(alignment: .bottom) {
            AutoScrollBadge(state: model.autoScroll, level: model.autoScrollLevel, showsSpeed: showSpeedBadge,
                            showsCrownHint: model.autoScrollShowsCrownHint)
                .padding(.bottom, 4)
        }
        .tint(style.accentColor)
        .preferredColorScheme(style.isLightPage ? .light : .dark)
        // Layout metrics changed (text size, font, spacing): the same line stays at the top. The position is
        // frozen at once and the text covered until that line is back at the top edge, then revealed in one move
        // (`ReaderViewModel.layoutChanged(to:)`, `JumpSettling`). Colour-only changes (Always On, Increase
        // Contrast) keep the layout and need no re-anchoring.
        .onChange(of: style.layoutKey) { key in
            // A paused auto-scroll window was laid out for the old metrics: the scroll view takes over.
            if autoScrollWindow != nil, model.autoScroll != .running { endAutoScrollWindow() }
            model.layoutChanged(to: key)
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only a trailing item: the leading slot belongs to the system back button (and its edge swipe).
            ToolbarItem(placement: .topBarTrailing) {
                Button { showMenu = true } label: {
                    Label {
                        Text("Reading Options")
                    } icon: {
                        // The sync glyph rides on the options button, which opens the menu that explains it.
                        Image(systemName: "list.bullet")
                            .overlay(alignment: .topTrailing) {
                                if let status = visibleSyncStatus {
                                    SyncStatusIndicator(status: status)
                                        .font(.system(size: 10, weight: .semibold))
                                        .offset(x: 8, y: -8)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .accessibilityHint(Text("Text size, chapters and dictionary."))
                .accessibilityValue(Text(visibleSyncStatus.flatMap(WatchMessages.syncStatus) ?? ""))
                .accessibilityIdentifier("readerOptionsButton")
            }
        }
        .toolbar(barHidden ? .hidden : .visible, for: .navigationBar)
        .onChange(of: voiceOver) { on in
            if on { updateBar { $0.show(at: Date()) } }
        }
        .onChange(of: showMenu) { shown in
            if shown { updateBar { $0.show(at: Date()) } }
        }
        // Anything over the text pauses auto-scroll; it resumes only on a tap.
        .onChange(of: coversReader) { covered in
            if covered {
                model.pauseAutoScroll()
            } else if crownReturnPending {
                returnCrownToText()
            }
        }
        .onChange(of: isLuminanceReduced) { dimmed in
            if dimmed { model.pauseAutoScroll() }
        }
        .onChange(of: model.autoScroll) { state in
            updateBar {
                $0.programmaticScroll(state != .off || model.isRestoring)
                $0.autoScroll(running: state == .running, at: Date(), voiceOver: voiceOver)
            }
            if state == .running {
                autoScrollHandingBack = false
                // Seeded from the text as it is on screen right now, in this same update.
                makeAutoScrollWindow(at: Date())
                crownValue = Double(model.autoScrollLevel)
                // On every start and resume, a little longer than after a crown change (the sheet is still
                // leaving), and longer still with the first-start crown hint.
                flashSpeedBadge(for: model.autoScrollShowsCrownHint ? AutoScrollBadge.hintDuration
                                                                     : AutoScrollBadge.startDuration)
            } else {
                handTextBackToScrollView()
            }
        }
        .sheet(isPresented: $showMenu, onDismiss: {
            if lookupAfterMenu {
                lookupAfterMenu = false
                // From the menu: start on the word at the reading line.
                model.beginLookup(at: model.currentIndex, characterOffset: model.currentOffset)
            }
            // While auto-scroll shows the text, the hand-back already brings the scroll view to the exact point
            // (a re-anchor goes to the start of a word); a layout change ends the window and re-anchors anyway.
            if autoScrollWindow == nil { model.reanchor() }
            if autoScrollAfterMenu {
                autoScrollAfterMenu = false
                // Waits for the re-anchor to settle before the first move (`tendAutoScroll`).
                model.startAutoScroll(reduceMotion: reduceMotion)
            }
        }) {
            ReaderMenuView(model: model,
                           syncNote: visibleSyncStatus.flatMap { WatchMessages.syncExplanation($0, failure: sync.failure) },
                           onLookup: { lookupAfterMenu = true },
                           onAutoScroll: { autoScrollAfterMenu = true })
                .environmentObject(typography)
        }
        .sheet(item: $model.openNote) { target in
            NoteSheet(note: target.note)
                .environmentObject(typography)
        }
        .sheet(item: $model.lookupBlockIndex) { target in
            WordLookupSheet(text: model.flat.blocks[target.index].text,
                            language: model.bookLanguage, provider: model.dictionary,
                            initialCharacterOffset: target.characterOffset)
        }
        .alert(Text("Continue Where You Left Off?", comment: "Title of the offer to jump to the position saved by another device"),
               isPresented: $model.showRemoteOffer) {
            Button("Go to Position") { model.acceptRemote() }
            Button("Stay Here", role: .cancel) { model.declineRemote() }
        } message: {
            if let remote = model.remoteOffer {
                Text(ReadingProgressFormat.remoteOffer(remote.percentage, deviceName: remote.deviceName,
                                                       connectorID: model.syncConnectorID))
            }
        }
        // At the end of the book: offered once per opening, never set automatically (#113).
        .alert(Text("Mark as Finished?", comment: "Title of the offer shown on reaching the end of a book"),
               isPresented: $model.showFinishOffer) {
            Button("Mark as Finished") { model.setFinished(true) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("You’ve reached the end of the book.", comment: "Message of the offer to mark a book as finished")
        }
        // A far jump has landed and the text is revealed: VoiceOver says where, once (#174).
        .onChange(of: model.arrival) { arrival in
            guard let arrival, voiceOver else { return }
            AccessibilityNotification.Announcement(arrival.announcement).post()
        }
        .onAppear {
            updateBar { $0.programmaticScroll(true) }
            model.restoreInitialPosition()
        }
        .onDisappear {
            commitAutoScrollPosition(force: true)
            model.leave()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                model.pauseAutoScroll()
                model.reportProgress(immediately: true)
            }
        }
        .task { await model.syncOnOpen() }
        .task {
            // Debounced periodic push (~60 s) while reading; cancelled automatically on leaving.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                model.reportProgress(immediately: false)
            }
        }
    }
}

extension ReaderView {
    /// The sync status to show, if any: only with sync on and configured, never while the wrist is down
    /// (Always On shows just the page), and nothing while idle. Never for a book that does not sync (switched
    /// off, or not in the Readest library: #167).
    fileprivate var visibleSyncStatus: SyncStatus? {
        guard showSyncInfo, sync.isConfigured, !isLuminanceReduced, sync.status != .idle,
              sync.syncs(model.documentHash) else { return nil }
        return sync.status
    }

    /// A tap on a note marker (#66) opens the note, with the bar shown or hidden and whether or not tap to look up
    /// is on. Any other tap on the text shows the hidden bar (then hides it again after a few seconds); with the
    /// bar visible it opens the word lookup on the word under the finger (estimated, see `TapPosition`).
    fileprivate func tapped(block index: Int, at location: CGPoint, style: ReaderRenderStyle) {
        // Paused auto-scroll: a tap anywhere on the text resumes it.
        if model.autoScroll == .paused {
            model.resumeAutoScroll()
            return
        }
        if index < model.flat.count, model.flat.blocks[index].notes?.isEmpty == false,
           let offset = tappedCharacterOffset(block: index, at: location, style: style),
           let note = model.flat.blocks[index].noteReference(nearCharacterOffset: offset) {
            model.showNote(note, inBlock: index)
            return
        }
        guard !revealBarOnTap(), tapToLookUp else { return }
        model.beginLookup(at: index, characterOffset: tappedCharacterOffset(block: index, at: location, style: style))
    }

    /// A tap in the left-edge strip (#118), in global coordinates: handled as a tap on the block under it (in
    /// that block's own coordinates), or, over no block, like a tap on empty reader space (shows a hidden bar).
    fileprivate func edgeTapped(at point: CGPoint, style: ReaderRenderStyle) {
        // The text under the strip is covered while a far jump settles (#174).
        guard !model.coversText else { return }
        if model.autoScroll == .paused {
            model.resumeAutoScroll()
            return
        }
        guard let target = EdgeSwipeBack.tapTarget(at: point, scrollOrigin: scrollOrigin,
                                                   contentMinX: CGFloat(style.typography.horizontalMargin),
                                                   frames: model.blockFrames) else {
            _ = revealBarOnTap()
            return
        }
        tapped(block: target.index, at: target.location, style: style)
    }

    /// A tap on the text outside every block (between paragraphs, in the margins): like a tap on empty reader space.
    fileprivate func tappedBetweenBlocks() {
        guard !model.coversText else { return }
        if model.autoScroll == .paused {
            model.resumeAutoScroll()
            return
        }
        _ = revealBarOnTap()
    }

    /// Shows the hidden bar for a tap (then hides it again after a few seconds). Returns whether it did.
    fileprivate func revealBarOnTap() -> Bool {
        var revealed = false
        updateBar { revealed = $0.tapped(at: Date(), voiceOver: voiceOver) }
        guard revealed else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + BarAutoHide.tapRevealDuration + 0.05) {
            updateBar { $0.tick(at: Date(), voiceOver: voiceOver) }
        }
        return true
    }

    /// Character offset of the text under `location` (in the block's own coordinates), or nil when the
    /// block's size is not known yet.
    fileprivate func tappedCharacterOffset(block index: Int, at location: CGPoint, style: ReaderRenderStyle) -> Int? {
        guard index < model.flat.count, let frame = model.frame(ofBlock: index), frame.width > 0 else { return nil }
        let block = model.flat.blocks[index]
        let spec = style.spec(for: block.style)
        let layout = TapPosition.Layout(width: Double(frame.width) - spec.indent,
                                        height: Double(frame.maxY - frame.minY) - spec.topPadding,
                                        pointSize: spec.pointSize,
                                        lineSpacing: style.typography.lineSpacing,
                                        tracking: style.typography.tracking)
        return TapPosition.characterOffset(x: Double(location.x) - spec.indent, y: Double(location.y) - spec.topPadding,
                                           layout: layout, characterCount: block.text.count)
    }

    /// A sheet or an alert covers the text (the menu, a note, the word lookup, a sync or finish offer).
    fileprivate var coversReader: Bool {
        showMenu || model.openNote != nil || model.lookupBlockIndex != nil || model.showRemoteOffer || model.showFinishOffer
    }

    // MARK: Auto-scroll (#67)

    /// The auto-scrolled text: the window's blocks stacked exactly like the reader's list (`AutoScrollColumn`:
    /// the same block view, style, width and spacing, every block at its full height), placed where the
    /// scroll view showed them when the window was made and moved up by the distance scrolled. Behind it, the
    /// reader's own page colour edge to edge, as the reader paints it, and no clipping box: the screen looks
    /// the same as the reader's. The offset is computed on every display frame from the view model's `Motion`
    /// (paused, it stops asking for frames); the stack itself only changes with the window (it is equatable),
    /// so a frame costs one offset, not a layout.
    fileprivate func autoScrollColumn(_ window: AutoScroll.Window, style: ReaderRenderStyle,
                                      lineHeight: Double) -> some View {
        let margin = CGFloat(style.typography.horizontalMargin)
        return ZStack(alignment: .topLeading) {
            style.background
                .ignoresSafeArea()
            GeometryReader { geo in
                // UI tests only: the area the text is drawn in, so a test can check that it is the scroll view's.
                if UITesting.exposesBlockHeights {
                    Color.clear
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityElement()
                        .accessibilityIdentifier("autoScrollSurface")
                        .allowsHitTesting(false)
                }
                // From this overlay's own global origin (it ignores the safe area) to the scroll view's text.
                let origin = geo.frame(in: .global).origin
                let dx = autoScrollOrigin.x - origin.x + (autoScrollLeading > 0 ? autoScrollLeading : margin)
                let dy = autoScrollOrigin.y - origin.y
                TimelineView(.animation(minimumInterval: nil, paused: model.autoScroll != .running)) { context in
                    AutoScrollColumn(blocks: model.flat.blocks, first: window.first, last: window.last, style: style,
                                     width: autoScrollTextWidth > 0 ? autoScrollTextWidth
                                                                    : max(geo.size.width - 2 * margin, 0))
                        .equatable()
                        .offset(x: dx, y: dy + CGFloat(window.originY - autoScrollShift(window, at: context.date,
                                                                                        lineHeight: lineHeight,
                                                                                        spacing: Double(style.typography.paragraphSpacing))))
                }
            }
            // The text's container spans the whole screen, as the scroll view does: laid out inside the safe area
            // it ended at the bottom inset (y 178 of 197 on a 41 mm watch) and under the bar, where the
            // scroll view's text runs on to the edges.
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Paused (the scroll view is still landing underneath): a tap resumes, as on the text.
        .onTapGesture {
            if model.autoScroll == .paused { model.resumeAutoScroll() }
        }
        .onPreferenceChange(AutoScrollHeightsKey.self) { measured in
            autoScrollHeights.merge(measured) { _, new in new }
        }
    }

    /// Makes the window from the blocks exactly where the scroll view shows them now (their measured frames,
    /// the geometry the reading position is tracked with), so its first frame is the reader's last one.
    /// Returns whether it did.
    @discardableResult
    fileprivate func makeAutoScrollWindow(at date: Date) -> Bool {
        guard autoScrollWindow == nil, model.autoScroll == .running, !model.isRestoring, !model.coversText else {
            return false
        }
        let frames = model.blockFrames.mapValues { AutoScroll.Span(minY: Double($0.minY), maxY: Double($0.maxY)) }
        guard let window = AutoScroll.Window(frames: frames, viewportHeight: Double(model.viewportHeight),
                                             blockCount: model.flat.count,
                                             baseLines: model.autoScrollLines(at: date)) else { return false }
        withoutAnimation {
            autoScrollHeights = frames.mapValues(\.height)
            autoScrollLeading = model.blockFrames[window.first]?.minX ?? 0
            autoScrollTextWidth = model.blockFrames[window.first]?.width ?? 0
            autoScrollOrigin = scrollOrigin
            autoScrollWindow = window
        }
        return true
    }

    /// Points the window has moved since it was made, at `date`: never past the end of the book.
    fileprivate func autoScrollShift(_ window: AutoScroll.Window, at date: Date, lineHeight: Double,
                                     spacing: Double) -> Double {
        let raw = max(model.autoScrollLines(at: date) - window.baseLines, 0) * lineHeight
        guard let end = window.endShift(heights: autoScrollHeights, spacing: spacing,
                                        viewportHeight: Double(model.viewportHeight),
                                        blockCount: model.flat.count) else { return raw }
        return min(raw, end)
    }

    /// The line at the reading line in the window (and the window's blocks, where they are), or nil.
    fileprivate func autoScrollCursor(at date: Date, lineHeight: Double, spacing: Double)
        -> (cursor: AutoScroll.Cursor, frames: [Int: AutoScroll.Span])? {
        guard let window = autoScrollWindow else { return nil }
        let shift = autoScrollShift(window, at: date, lineHeight: lineHeight, spacing: spacing)
        // In the scroll view's coordinates of the moment (the same as the window's unless its frame moved).
        let moved = Double(autoScrollOrigin.y - scrollOrigin.y)
        let frames = window.spans(heights: autoScrollHeights, spacing: spacing, shift: shift - moved)
        guard let cursor = AutoScroll.cursor(frames: frames, viewportTop: Double(model.viewportTop)) else { return nil }
        return (cursor, frames)
    }

    /// Runs while auto-scroll is on or its window is shown, a few times a second.
    @MainActor
    fileprivate func maintainAutoScroll(lineHeight: Double, spacing: Double) async {
        autoScrollMetrics = (lineHeight, spacing)
        while !Task.isCancelled, model.isAutoScrollActive || autoScrollWindow != nil {
            tendAutoScroll(lineHeight: lineHeight, spacing: spacing)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    fileprivate func tendAutoScroll(lineHeight: Double, spacing: Double) {
        let date = Date()
        let viewportHeight = Double(model.viewportHeight)
        if model.autoScroll == .running {
            // The crown changes the speed at any moment while it runs (unless a sheet has it).
            if crownFocus != .autoScroll, !coversReader { crownFocus = .autoScroll }
            if autoScrollWindow == nil {
                // Starts (or resumes) from exactly where the scroll view shows the text, once it settled (when
                // it was already settled, `onChange(of: autoScroll)` made the window at once).
                makeAutoScrollWindow(at: date)
                return
            }
        }
        guard var window = autoScrollWindow else { return }
        guard model.autoScroll == .running else {
            // Paused or stopped: once the scroll view has landed at the point shown, it takes over.
            if !autoScrollHandingBack || !model.isRestoring { endAutoScrollWindow() }
            return
        }
        let shift = autoScrollShift(window, at: date, lineHeight: lineHeight, spacing: spacing)
        if let end = window.endShift(heights: autoScrollHeights, spacing: spacing, viewportHeight: viewportHeight,
                                     blockCount: model.flat.count), shift >= end {
            autoScrollReachedEnd()
            return
        }
        if window.update(heights: autoScrollHeights, spacing: spacing, shift: shift, viewportHeight: viewportHeight,
                         blockCount: model.flat.count, margin: max(viewportHeight, 100)) {
            withoutAnimation { autoScrollWindow = window }
        }
        commitAutoScrollPosition(force: false)
    }

    /// Saves the line at the reading line (at most every `AutoScroll.commitInterval` s unless `force`).
    fileprivate func commitAutoScrollPosition(force: Bool) {
        guard let metrics = autoScrollMetrics,
              let found = autoScrollCursor(at: Date(), lineHeight: metrics.lineHeight, spacing: metrics.spacing),
              let frame = found.frames[found.cursor.index] else { return }
        model.autoScrollPositionChanged(found.cursor, blockHeight: frame.height, force: force)
    }

    /// Paused or stopped: the scroll view is brought to the exact point shown, while the window stays on screen
    /// (frozen) until it has landed. The crown is nobody's meanwhile, so it cannot scroll the hidden text.
    fileprivate func handTextBackToScrollView() {
        guard autoScrollWindow != nil else {
            returnCrownToText()
            return
        }
        if crownFocus == .autoScroll { crownFocus = nil }
        guard let metrics = autoScrollMetrics,
              let found = autoScrollCursor(at: Date(), lineHeight: metrics.lineHeight, spacing: metrics.spacing) else {
            endAutoScrollWindow()
            return
        }
        autoScrollHandingBack = true
        model.handBackAutoScroll(at: found.cursor, frames: found.frames)
    }

    /// The scroll view shows the text again.
    fileprivate func endAutoScrollWindow() {
        withoutAnimation {
            autoScrollWindow = nil
            autoScrollHeights = [:]
            autoScrollHandingBack = false
        }
        returnCrownToText()
    }

    fileprivate func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// The end of the book is on screen: auto-scroll stops (with the stop haptic), and VoiceOver says so.
    fileprivate func autoScrollReachedEnd() {
        model.stopAutoScroll()
        AccessibilityNotification.Announcement(String(localized: "End of book. Auto-scroll stopped.",
                                                      comment: "VoiceOver announcement when auto-scroll reaches the end of the book"))
            .post()
    }

    /// Over the text while auto-scroll runs: holds the Digital Crown (speed, one detent and haptic per level)
    /// and pauses on a tap. One VoiceOver element: "Auto-Scroll, speed 3 of 7", adjustable with swipe up /
    /// down, double-tap pauses.
    fileprivate var autoScrollLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .focused($crownFocus, equals: .autoScroll)
            .focusEffectDisabled()
            .digitalCrownRotation($crownValue,
                                  from: Double(AutoScroll.levels.lowerBound), through: Double(AutoScroll.levels.upperBound),
                                  by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onTapGesture { model.pauseAutoScroll() }
            .onAppear {
                crownValue = Double(model.autoScrollLevel)
                crownFocus = .autoScroll
            }
            // Keep the crown while running (a re-render can drop the focus, as in the word picker); the
            // housekeeping task also checks it a few times a second.
            .onChange(of: crownFocus) { focus in
                if focus != .autoScroll, model.autoScroll == .running, !coversReader { crownFocus = .autoScroll }
            }
            .onChange(of: crownValue) { value in
                changeAutoScrollSpeed(to: AutoScroll.level(forCrown: value))
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Auto-Scroll"))
            .accessibilityValue(AutoScrollBadge.speedText(model.autoScrollLevel))
            .accessibilityHint(Text("Double-tap to pause. Swipe up or down to change the speed.",
                                    comment: "VoiceOver hint of the auto-scroll control over the reader text"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.pauseAutoScroll() }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: changeAutoScrollSpeed(to: model.autoScrollLevel + 1)
                case .decrement: changeAutoScrollSpeed(to: model.autoScrollLevel - 1)
                @unknown default: break
                }
                crownValue = Double(model.autoScrollLevel)
            }
            .accessibilityIdentifier("autoScrollControl")
    }

    /// The auto-scroll layer is gone (paused, stopped, end of the book): the crown goes back to the scroll view.
    /// Not while a sheet is up (it would take the crown from the sheet): then once the sheet is gone.
    fileprivate func returnCrownToText() {
        guard !coversReader else {
            crownReturnPending = true
            return
        }
        crownReturnPending = false
        // After the layer has left the view tree.
        DispatchQueue.main.async {
            guard model.autoScroll != .running, autoScrollWindow == nil else { return }
            crownFocus = .text
        }
    }

    fileprivate func changeAutoScrollSpeed(to level: Int) {
        guard AutoScroll.clampedLevel(level) != model.autoScrollLevel else { return }
        model.setAutoScrollLevel(level)
        flashSpeedBadge(for: AutoScrollBadge.speedDuration)
    }

    /// Shows the speed badge for `duration` seconds. It fades in and out, or with Reduce Motion simply appears
    /// and goes. The first-start crown hint goes with it.
    fileprivate func flashSpeedBadge(for duration: TimeInterval) {
        speedBadgeToken &+= 1
        let token = speedBadgeToken
        setSpeedBadge(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == speedBadgeToken else { return }
            setSpeedBadge(false)
            model.dismissAutoScrollCrownHint()
        }
    }

    fileprivate func setSpeedBadge(_ visible: Bool) {
        if reduceMotion {
            showSpeedBadge = visible
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { showSpeedBadge = visible }
        }
    }

    fileprivate func updateBar(_ change: (inout BarAutoHide) -> Void) {
        change(&autoHide.state)
        guard autoHide.state.isHidden != barHidden else { return }
        withAnimation(.easeInOut(duration: 0.2)) { barHidden = autoHide.state.isHidden }
    }
}

/// The small badge at the bottom of the reader for auto-scroll (#67): the speed ("Speed 3 of 7" and a row of
/// dots) for a moment after it starts or changes, the first time also with "Turn the Digital Crown to change
/// speed", and "Paused – Tap to Continue" while paused (also after the screen went dark: the wrist went down).
/// Transparent to taps. The speed is hidden from VoiceOver (the auto-scroll control's value and hint say it);
/// the paused badge is readable.
private struct AutoScrollBadge: View {
    let state: ReaderViewModel.AutoScrollState
    let level: Int
    let showsSpeed: Bool
    let showsCrownHint: Bool

    /// After a crown change.
    static let speedDuration: TimeInterval = 1.5
    /// On start and resume.
    static let startDuration: TimeInterval = 2.5
    /// The first start, with the crown hint to read.
    static let hintDuration: TimeInterval = 4

    static func speedText(_ level: Int) -> Text {
        Text("Speed \(level) of \(AutoScroll.levelCount)",
             comment: "Auto-scroll speed level, e.g. 'Speed 3 of 7' (badge and VoiceOver value)")
    }

    var body: some View {
        if state == .paused {
            pill {
                Label {
                    Text("Paused – Tap to Continue",
                         comment: "Badge at the bottom of the reader while auto-scroll is paused (a tap on the text resumes it)")
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                } icon: {
                    Image(systemName: "pause.fill")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Auto-Scroll Paused", comment: "Badge at the bottom of the reader while auto-scroll is paused"))
            .accessibilityHint(Text("Tap the text to resume.", comment: "VoiceOver hint of the paused auto-scroll badge"))
            .accessibilityIdentifier("autoScrollPaused")
        } else if state == .running, showsSpeed {
            pill {
                VStack(spacing: 2) {
                    Self.speedText(level)
                    HStack(spacing: 3) {
                        ForEach(AutoScroll.levels, id: \.self) { dot in
                            Circle()
                                .fill(dot <= level ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                                .frame(width: 4, height: 4)
                        }
                    }
                    if showsCrownHint {
                        Text("Turn the Digital Crown to change speed",
                             comment: "Hint under the auto-scroll speed badge, shown the first time auto-scroll starts")
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.regularMaterial))
            .allowsHitTesting(false)
    }
}

/// The page-coloured cover over the text while a book opens or a far jump settles (#174, `JumpSettling`). It
/// appears at once (a fade-in would let the hops show through) and lifts with a short cross-fade, or at once
/// with Reduce Motion. After `JumpSettling.indicatorDelay` it shows a small progress indicator. It takes the
/// taps meant for the hidden text and is hidden from VoiceOver, which announces the destination once revealed.
private struct SettlingCover: View {
    let covers: Bool
    let showsIndicator: Bool
    let color: Color
    let textColor: Color
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if covers {
                ZStack {
                    color
                    if showsIndicator {
                        VStack(spacing: 4) {
                            ProgressView()
                            Text("Opening\u{2026}")
                                .font(.footnote)
                                .foregroundStyle(textColor)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {}
                .transition(reduceMotion ? AnyTransition.identity
                                          : AnyTransition.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.2), value: covers)
        .animation(reduceMotion ? nil : Animation.easeIn(duration: 0.15), value: showsIndicator)
        .allowsHitTesting(covers)
        .accessibilityHidden(true)
    }
}

/// Holds `BarAutoHide` outside SwiftUI's change tracking, so per-frame scroll updates do not re-render.
final class BarAutoHideBox {
    var state = BarAutoHide()
}

/// Reports how far a scroll view's content is scrolled (0 at the top, growing while reading forward) on
/// every scroll position change, from the scroll view's own geometry (watchOS 11+). On watchOS 10 it does
/// nothing and the reader falls back to the `ContentTopKey` preference.
struct ScrollDistanceReader: ViewModifier {
    let action: (CGFloat) -> Void

    static var readsScrollGeometry: Bool {
        if #available(watchOS 11.0, *) { return true }
        return false
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                // contentOffset.y is -inset at the top; adding the (bar) inset makes the start of the text 0.
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                action(offset)
            }
        } else {
            content
        }
    }
}

/// Top of the reader's text in the scroll view's coordinate space (moves up while scrolling forward).
struct ContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The page-coloured band over the system time while the navigation bar is hidden (`ClockBand`). It reads
/// the top safe-area inset at the reader's root and spans the screen from its very top edge. Decorative:
/// hidden from VoiceOver and transparent to taps. Under the UI tests it stays in the accessibility tree
/// as "clockBand" so its frame can be asserted (the bar never hides with VoiceOver on, so VoiceOver never
/// meets it).
private struct ClockBandOverlay: View {
    let barHidden: Bool
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let height = ClockBand.height(barHidden: barHidden, topInset: geo.safeAreaInsets.top,
                                          screenHeight: geo.size.height)
            VStack(spacing: 0) {
                if height > 0 {
                    color
                        .frame(height: height)
                        .accessibilityElement()
                        .accessibilityIdentifier("clockBand")
                        .accessibilityHidden(!UITesting.isActive)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
        }
        // The GeometryReader covers the whole screen, so the band starts at the top edge, spans the full width
        // (the side safe areas are 2 pt on 44 mm) and its height is a fraction of the real screen height.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A transparent strip `EdgeSwipeBack.edgeWidth` wide along the left edge of the screen that leaves the book on
/// a clear rightward drag starting there (#118). watchOS disables the navigation stack's own edge pan while the
/// bar is hidden, and the scroll view and the text's tap gestures claim edge touches when it is shown, so the
/// reader recognises the swipe itself. A tap in the strip is forwarded to the text under it (`onTap`, global
/// coordinates; see `EdgeSwipeBack.tapTarget`), so the first word of a line can still be looked up. A vertical
/// drag that starts in the strip does not scroll: the strip is mostly the text margin (4 pt by default, at most
/// 16), the crown and touches anywhere else scroll as usual. Hidden from VoiceOver, which leaves with the
/// escape scrub instead.
private struct EdgeSwipeBackStrip: View {
    let onBack: () -> Void
    let onTap: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .frame(width: EdgeSwipeBack.edgeWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .global) { onTap($0) }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onEnded { value in
                        if EdgeSwipeBack.isBackSwipe(startX: value.startLocation.x, translation: value.translation,
                                                     predictedEndTranslation: value.predictedEndTranslation) {
                            onBack()
                        }
                    }
            )
            // From the physical left edge (the side safe area is 2 pt on 44 mm), below the bar.
            .ignoresSafeArea(.container, edges: .leading)
            .accessibilityHidden(true)
    }
}

/// Collects the frames of the blocks the `LazyVStack` currently has instantiated. Views that are
/// discarded stop contributing, so the dictionary only holds on-screen blocks plus a small buffer.
struct BlockFramesKey: PreferenceKey {
    static var defaultValue: [Int: BlockFrame] = [:]
    static func reduce(value: inout [Int: BlockFrame], nextValue: () -> [Int: BlockFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Top safe-area inset of the reader's scroll view (navigation bar height when content runs under it).
struct ViewportTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Heights of the blocks in the auto-scroll window, measured there.
struct AutoScrollHeightsKey: PreferenceKey {
    static var defaultValue: [Int: Double] = [:]
    static func reduce(value: inout [Int: Double], nextValue: () -> [Int: Double]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The blocks auto-scroll moves (#67, `AutoScroll.Window`): stacked like the reader's own list (same width,
/// spacing and style, so every line breaks at the same word) and measured. Equatable on what changes its
/// layout, so the offset applied on every frame never re-evaluates it. Each block keeps the reader's
/// "readerBlock" identifier (the scroll view underneath is hidden from accessibility meanwhile).
private struct AutoScrollColumn: View, Equatable {
    let blocks: [Block]
    let first: Int
    let last: Int
    let style: ReaderRenderStyle
    let width: CGFloat

    static func == (lhs: AutoScrollColumn, rhs: AutoScrollColumn) -> Bool {
        lhs.first == rhs.first && lhs.last == rhs.last && lhs.width == rhs.width
            && lhs.blocks.count == rhs.blocks.count && lhs.style == rhs.style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.typography.paragraphSpacing) {
            ForEach(first...max(first, min(last, blocks.count - 1)), id: \.self) { index in
                BlockStyledText(block: blocks[index], style: style)
                    .equatable()
                    // In a scroll view every block gets its full height. Here the stack is offered one screen,
                    // and without this the blocks shared it: each was cut to a line or two ending in "…".
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(UITestBlockHeight())
                    .accessibilityIdentifier("readerBlock")
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: AutoScrollHeightsKey.self, value: [index: Double(geo.size.height)])
                    })
            }
        }
        // The full width the scroll view gives its text, and the stack's whole height, past the screen's edge
        // (no clipping: the screen's own edges cut it, as they cut the scroll view).
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// UI tests only (`-UITestingBlockHeights`, see `UITesting`): the block's laid-out height as its accessibility
/// value, "h=<points>", for the reader's blocks and the ones auto-scroll draws alike. Without the argument (and in
/// Release builds) it changes nothing.
private struct UITestBlockHeight: ViewModifier {
    @State private var height: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if UITesting.exposesBlockHeights {
            content
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { height = geo.size.height }
                        .onChange(of: geo.size.height) { height = $0 }
                })
                .accessibilityValue(Text(verbatim: String(format: "h=%.1f", Double(height)))) // i18n-ignore: UI-test hook
        } else {
            content
        }
    }
}

/// UI tests only (`-UITestingReaderPosition`, see `UITesting`): the reading position as a tiny, untappable element
/// "readerPosition" whose value is "block=<flat index> offset=<characters> settled=<0|1>" ("settled" once no restore
/// or cover is running). Without the argument (and in Release builds) it is never created.
private struct UITestReaderPosition: View {
    let index: Int
    let offset: Int
    let settled: Bool

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("readerPosition")
            .accessibilityValue(Text(verbatim: "block=\(index) offset=\(offset) settled=\(settled ? 1 : 0)")) // i18n-ignore: UI-test hook
            .allowsHitTesting(false)
    }
}

/// Origin of the reader's scroll view in global coordinates, to map edge-strip taps into the scroll view's space.
struct ViewportOriginKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// Height of the reader's scroll view, for the in-block restore anchor.
struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Discreet status glyph; nothing is shown while idle. Each glyph has a VoiceOver label
/// (`WatchMessages.syncStatus`).
struct SyncStatusIndicator: View {
    let status: SyncStatus

    var body: some View {
        if let label = WatchMessages.syncStatus(status) {
            glyph
                .imageScale(.small)
                .accessibilityLabel(Text(label))
        }
    }

    @ViewBuilder private var glyph: some View {
        switch status {
        case .idle:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .offline:
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        case .error:
            // Shape differs from the other states, so the meaning does not rely on colour alone.
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.tint)
        }
    }
}
