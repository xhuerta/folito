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
/// it, so it is not requested; what remains on screen with the bar hidden is captured by
/// `WatchReaderTopBarTests` (attachment "watch-reader-bar-hidden").
struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
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
                            .onTapGesture { tapped(block: index) }
                            // Available from the VoiceOver actions rotor even with tap-to-look-up off.
                            .accessibilityAction(named: Text("Look Up a Word")) { model.beginLookup(at: index) }
                            .accessibilityIdentifier("readerBlock")
                            .id(index)
                            .background(
                                GeometryReader { geo in
                                    let f = geo.frame(in: .named(Self.scrollSpace))
                                    Color.clear.preference(key: BlockFramesKey.self,
                                                           value: [index: BlockFrame(minY: f.minY, maxY: f.maxY)])
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
            }
            .coordinateSpace(name: Self.scrollSpace)
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
                let offset = model.viewportTop - top
                updateBar { $0.scrolled(to: offset, at: Date(), voiceOver: voiceOver) }
            }
            .onPreferenceChange(ViewportHeightKey.self) { model.viewportHeight = $0 }
            .onPreferenceChange(BlockFramesKey.self) { model.blockFramesChanged($0) }
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
                model.beginLookup(at: model.currentIndex)
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
                            language: model.bookLanguage, provider: model.dictionary)
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
        .onAppear { model.restoreInitialPosition() }
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
    /// visible it opens the word lookup as before.
    fileprivate func tapped(block index: Int) {
        var revealed = false
        updateBar { revealed = $0.tapped(at: Date(), voiceOver: voiceOver) }
        if revealed {
            DispatchQueue.main.asyncAfter(deadline: .now() + BarAutoHide.tapRevealDuration + 0.05) {
                updateBar { $0.tick(at: Date(), voiceOver: voiceOver) }
            }
            return
        }
        if tapToLookUp { model.beginLookup(at: index) }
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

/// Top of the reader's text in the scroll view's coordinate space (moves up while scrolling forward).
struct ContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
