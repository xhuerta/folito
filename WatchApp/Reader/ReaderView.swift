import SwiftUI
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    private var readerAccessibility = ReaderAccessibilityReader()
    private static let scrollSpace = "reader.scroll"

    init(model: ReaderViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        // Fonts and colours are resolved once per typography / accessibility change, not per block per render.
        let style = typography.style(for: readerAccessibility.value)
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
            })
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
                updateBar { $0.programmaticScroll(restoring) }
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
        }
        .background(style.background)
        // Covers the system time while the bar is hidden (#125). On the root, outside the scroll view.
        .overlay(alignment: .top) {
            ClockBandOverlay(barHidden: barHidden, color: style.background)
        }
        // The left-edge swipe back (#118), with the bar shown or hidden. Above the scroll view so the edge
        // touch reaches it first; a thin strip along the text margin.
        .overlay(alignment: .leading) {
            EdgeSwipeBackStrip { dismiss() }
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
        .sheet(isPresented: $showMenu, onDismiss: {
            if lookupAfterMenu {
                lookupAfterMenu = false
                // From the menu: start on the word at the reading line.
                model.beginLookup(at: model.currentIndex, characterOffset: model.currentOffset)
            }
            model.reanchor()
        }) {
            ReaderMenuView(model: model,
                           syncNote: visibleSyncStatus.flatMap { WatchMessages.syncExplanation($0, failure: sync.failure) },
                           onLookup: { lookupAfterMenu = true })
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
                Text(ReadingProgressFormat.readOnDevice(
                    remote.percentage,
                    device: remote.deviceName.isEmpty
                        ? String(localized: "another device",
                                 comment: "Used in '43% read on another device' when the device name is unknown")
                        : remote.deviceName))
            }
        }
        .onAppear {
            updateBar { $0.programmaticScroll(true) }
            model.restoreInitialPosition()
        }
        .onDisappear { model.leave() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.reportProgress(immediately: true) }
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

    /// A tap on the text shows the hidden bar (then hides it again after a few seconds); with the bar
    /// visible it opens the word lookup on the word under the finger (estimated, see `TapPosition`).
    fileprivate func tapped(block index: Int, at location: CGPoint, style: ReaderRenderStyle) {
        var revealed = false
        updateBar { revealed = $0.tapped(at: Date(), voiceOver: voiceOver) }
        if revealed {
            DispatchQueue.main.asyncAfter(deadline: .now() + BarAutoHide.tapRevealDuration + 0.05) {
                updateBar { $0.tick(at: Date(), voiceOver: voiceOver) }
            }
            return
        }
        guard tapToLookUp else { return }
        model.beginLookup(at: index, characterOffset: tappedCharacterOffset(block: index, at: location, style: style))
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

    fileprivate func updateBar(_ change: (inout BarAutoHide) -> Void) {
        change(&autoHide.state)
        guard autoHide.state.isHidden != barHidden else { return }
        withAnimation(.easeInOut(duration: 0.2)) { barHidden = autoHide.state.isHidden }
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
/// reader recognises the swipe itself. A touch that starts in the strip neither scrolls nor taps the text; the
/// strip is mostly the text margin (4 pt by default, at most 16), the crown and touches anywhere else scroll as
/// usual. Hidden from VoiceOver, which leaves with the escape scrub instead.
private struct EdgeSwipeBackStrip: View {
    let onBack: () -> Void

    var body: some View {
        Color.clear
            .frame(width: EdgeSwipeBack.edgeWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
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
