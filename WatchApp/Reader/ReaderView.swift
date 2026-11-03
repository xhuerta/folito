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
struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var typography: TypographyModel
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @AppStorage(ReaderSettings.tapToLookUpKey) private var tapToLookUp = true
    @State private var showMenu = false
    @State private var lookupAfterMenu = false
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
                            .onTapGesture { if tapToLookUp { model.beginLookup(at: index) } }
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
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(BlockFramesKey.self) { model.blockFramesChanged($0) }
            .onChange(of: model.jumpRequest) { request in
                guard let request else { return }
                DispatchQueue.main.async {
                    // Instant jump (no animation), also under Reduce Motion.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(request.index, anchor: .top)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showMenu = true } label: {
                    Label("Reading Options", systemImage: "list.bullet")
                }
                .accessibilityHint(Text("Text size, chapters and dictionary."))
                .accessibilityIdentifier("readerOptionsButton")
            }
            // Status only, never while the wrist is down (Always On shows just the page).
            if showSyncInfo && sync.isConfigured && !isLuminanceReduced {
                ToolbarItem(placement: .cancellationAction) {
                    SyncStatusIndicator(status: sync.status)
                }
            }
        }
        .sheet(isPresented: $showMenu, onDismiss: {
            if lookupAfterMenu {
                lookupAfterMenu = false
                model.beginLookup(at: model.currentIndex)
            }
            model.reanchor()
        }) {
            ReaderMenuView(model: model, onLookup: { lookupAfterMenu = true })
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

/// Collects the frames of the blocks the `LazyVStack` currently has instantiated. Views that are
/// discarded stop contributing, so the dictionary only holds on-screen blocks plus a small buffer.
struct BlockFramesKey: PreferenceKey {
    static var defaultValue: [Int: BlockFrame] = [:]
    static func reduce(value: inout [Int: BlockFrame], nextValue: () -> [Int: BlockFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
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
