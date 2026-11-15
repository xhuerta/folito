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
/// Type (see `ReaderAccessibilityReader`). Programmatic jumps (restore, chapters, remote position) are never
/// animated, so Reduce Motion needs no special case. With the wrist down (Always On, reduced luminance)
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
/// Auto-scroll (#67): started from Reading Options, never by itself. While it runs, a tick about 30 times a
/// second moves a cursor (block + points into it, `AutoScroll.Cursor`) at the chosen speed and puts it at the
/// reading line with `ScrollViewProxy.scrollTo(_:anchor:)`, without animation (the same anchor math as the
/// in-block restore, so it works on watchOS 10). A transparent layer over the text (only while it runs) takes
/// the Digital Crown, which changes the speed level with one detent and haptic per level, and a tap, which
/// pauses; a tap on the text resumes. The top bar stays up while auto-scroll is on (paused or running), so
/// Reading Options, where it is stopped, is one tap away and the reading line never moves with the bar. It
/// pauses when a sheet or an alert opens, when the wrist goes down (Always On) or the app leaves the
/// foreground, stops at the end of the book and on leaving it. It runs only while the screen is on: reading is
/// not one of the session types `WKExtendedRuntimeSession` allows, so the app does not keep itself running.
/// The position keeps being saved from the block frames, as for any scroll.
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Start auto-scroll once the menu is gone (its "Start Auto-Scroll" button).
    @State private var autoScrollAfterMenu = false
    /// The auto-scroll layer holds the crown while auto-scroll runs (the scroll view has it otherwise).
    @FocusState private var autoScrollFocused: Bool
    /// The scroll view's crown focus, handed back once auto-scroll stops running.
    @FocusState private var scrollFocused: Bool
    /// Auto-scroll stopped running while a sheet was up: give the crown back to the text once it is gone.
    @State private var crownReturnPending = false
    /// The crown's value on the auto-scroll layer: one detent per speed level.
    @State private var crownValue = Double(AutoScroll.defaultLevel)
    /// The speed badge, shown for a moment after a speed change.
    @State private var showSpeedBadge = false
    @State private var speedBadgeToken = 0
    private var readerAccessibility = ReaderAccessibilityReader()
    private static let scrollSpace = "reader.scroll"

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
                                                           value: [index: BlockFrame(minY: f.minY, maxY: f.maxY, width: f.width)])
                                })
                    }
                    if model.flat.isEmpty {
                        Text("This book has no text.").foregroundStyle(style.secondaryColor)
                    }
                }
                .padding(.horizontal, style.typography.horizontalMargin)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentTopKey.self, value: geo.frame(in: .named(Self.scrollSpace)).minY)
                })
                // Laid out and scrolled as usual, but not shown until the saved line is at the top edge.
                .opacity(model.isPositioned ? 1 : 0)
                .accessibilityHidden(!model.isPositioned)
            }
            .coordinateSpace(name: Self.scrollSpace)
            // Every auto-scroll step is a scroll, and the system shows the scroll indicator beside the crown
            // for each one: about 30 flashes a second read as a flickering bar. Hidden while it runs; `.never`
            // rather than `.hidden`, which a platform may override (watchOS 9+ API, so fine on watchOS 10).
            .scrollIndicators(model.autoScroll == .running ? .never : .automatic)
            // Only set when auto-scroll stops running (`returnCrownToText`), so the crown scrolls the text again
            // at once instead of staying with the auto-scroll layer that went away.
            .focused($scrollFocused)
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
            .onPreferenceChange(ViewportOriginKey.self) { scrollOrigin = $0 }
            .onPreferenceChange(ViewportTopKey.self) { top in
                // The reading line stays where it is while the bar is hidden (see `ReadingLine`).
                model.viewportTop = ReadingLine.updated(current: model.viewportTop, measured: top, barShown: !barHidden)
            }
            .onPreferenceChange(ContentTopKey.self) { top in
                // Fallback for watchOS 10 only (see `ScrollDistanceReader`).
                guard !ScrollDistanceReader.readsScrollGeometry else { return }
                let offset = model.viewportTop - top
                updateBar { $0.scrolled(to: offset, at: Date(), voiceOver: voiceOver) }
            }
            .onPreferenceChange(ViewportHeightKey.self) { model.viewportHeight = $0 }
            .onPreferenceChange(BlockFramesKey.self) { model.blockFramesChanged($0) }
            // Restores and jumps are not reading: they must not hide the bar.
            .onChange(of: model.isRestoring) { restoring in
                // Auto-scroll moves the text too: it never hides the bar either.
                updateBar { $0.programmaticScroll(restoring || model.isAutoScrollActive) }
            }
            .onChange(of: model.jumpRequest) { request in
                guard let request else { return }
                DispatchQueue.main.async {
                    // Instant jump (no animation), also under Reduce Motion.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // An in-block restore passes an anchor that puts the saved line at the top edge.
                        proxy.scrollTo(request.index, anchor: request.anchorY.map { UnitPoint(x: 0, y: $0) } ?? .top)
                    }
                }
            }
            // Auto-scroll ticks while running; cancelled on pause, stop and leaving.
            .task(id: model.autoScroll == .running) {
                guard model.autoScroll == .running else { return }
                await runAutoScroll(proxy, lineHeight: autoScrollLineHeight)
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
        // Layout metrics changed: keep reading the same block. Colour-only changes (Always On,
        // Increase Contrast) keep the layout and need no re-anchoring.
        .onChange(of: style.layoutKey) { _ in
            DispatchQueue.main.async { model.reanchor() }
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
                if state != .off { $0.show(at: Date()) }
            }
            if state == .running {
                crownValue = Double(model.autoScrollLevel)
                // On every start and resume, a little longer than after a crown change (the sheet is still
                // leaving), and longer still with the first-start crown hint.
                flashSpeedBadge(for: model.autoScrollShowsCrownHint ? AutoScrollBadge.hintDuration
                                                                     : AutoScrollBadge.startDuration)
            } else {
                returnCrownToText()
            }
        }
        .sheet(isPresented: $showMenu, onDismiss: {
            if lookupAfterMenu {
                lookupAfterMenu = false
                // From the menu: start on the word at the reading line.
                model.beginLookup(at: model.currentIndex, characterOffset: model.currentOffset)
            }
            model.reanchor()
            if autoScrollAfterMenu {
                autoScrollAfterMenu = false
                // Waits for the re-anchor to settle before the first move (`runAutoScroll`).
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
        .onAppear {
            updateBar { $0.programmaticScroll(true) }
            model.restoreInitialPosition()
        }
        .onDisappear { model.leave() }
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
    /// (Always On shows just the page), and nothing while idle.
    fileprivate var visibleSyncStatus: SyncStatus? {
        guard showSyncInfo, sync.isConfigured, !isLuminanceReduced, sync.status != .idle else { return nil }
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

    /// Moves the text while auto-scroll runs: every `AutoScroll.tickInterval` the view model advances its
    /// cursor by the current speed times the time since the last tick (`ReaderViewModel.autoScrollTick`), and
    /// `scrollTo` puts it at the reading line. Steps are instant: an animated `scrollTo` uses the system's
    /// scroll curve rather than a linear one on watchOS, so back-to-back animated steps would pulse. Nothing is
    /// published per tick, so the reader does not re-render; the scroll itself updates the block frames, from
    /// which the position is saved as usual.
    @MainActor
    fileprivate func runAutoScroll(_ proxy: ScrollViewProxy, lineHeight: Double) async {
        var lastTick = Date()
        let tickNanoseconds = UInt64(AutoScroll.tickInterval * 1_000_000_000)
        while !Task.isCancelled, model.autoScroll == .running {
            try? await Task.sleep(nanoseconds: tickNanoseconds)
            guard !Task.isCancelled, model.autoScroll == .running else { return }
            let tickDate = Date()
            let elapsed = tickDate.timeIntervalSince(lastTick)
            lastTick = tickDate
            switch model.autoScrollTick(elapsed: elapsed, lineHeight: lineHeight) {
            case .idle:
                continue
            case .reachedEnd:
                autoScrollReachedEnd()
                return
            case .scroll(let step):
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(step.index, anchor: UnitPoint(x: 0, y: step.anchorY))
                }
            }
        }
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
            .focused($autoScrollFocused)
            .focusEffectDisabled()
            .digitalCrownRotation($crownValue,
                                  from: Double(AutoScroll.levels.lowerBound), through: Double(AutoScroll.levels.upperBound),
                                  by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onTapGesture { model.pauseAutoScroll() }
            .onAppear {
                crownValue = Double(model.autoScrollLevel)
                autoScrollFocused = true
            }
            // Keep the crown while running (a re-render can drop the focus, as in the word picker).
            .onChange(of: autoScrollFocused) { focused in
                if !focused, model.autoScroll == .running { autoScrollFocused = true }
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
        autoScrollFocused = false
        // After the layer has left the view tree.
        DispatchQueue.main.async {
            guard model.autoScroll != .running else { return }
            scrollFocused = true
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
