import SwiftUI
import ReaderCore

/// Scrolling reader.
///
/// Digital Crown: we deliberately rely on the native `ScrollView` crown support (watchOS scrolls a
/// `ScrollView` with the crown automatically, with haptic detents and momentum) instead of
/// `.digitalCrownRotation`, which would replace that behaviour and require manual offset math over a
/// lazily-laid-out list of thousands of blocks.
struct ReaderView: View {
    @StateObject private var model: ReaderViewModel
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReaderSettings.fontSizeKey) private var fontSize = ReaderSettings.defaultFontSize
    @AppStorage(ReaderSettings.showSyncInfoKey) private var showSyncInfo = true
    @State private var showMenu = false
    private static let scrollSpace = "reader.scroll"

    init(model: ReaderViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<model.flat.count, id: \.self) { index in
                        BlockView(block: model.flat.blocks[index], fontSize: ReaderSettings.clampFontSize(fontSize))
                            .id(index)
                            .background(
                                GeometryReader { geo in
                                    let f = geo.frame(in: .named(Self.scrollSpace))
                                    Color.clear.preference(key: BlockFramesKey.self,
                                                           value: [index: BlockFrame(minY: f.minY, maxY: f.maxY)])
                                })
                    }
                    if model.flat.isEmpty {
                        Text("This book has no text.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(BlockFramesKey.self) { model.blockFramesChanged($0) }
            .onChange(of: model.jumpRequest) { request in
                guard let request else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(request.index, anchor: .top)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { showMenu = true } label: { Image(systemName: "list.bullet") }
            }
            if showSyncInfo && sync.isConfigured {
                ToolbarItem(placement: .cancellationAction) {
                    SyncStatusIndicator(status: sync.status)
                }
            }
        }
        .sheet(isPresented: $showMenu) {
            ReaderMenuView(model: model)
        }
        .alert("Go to \(model.remoteOffer?.device ?? "other device") position?",
               isPresented: $model.showRemoteOffer) {
            Button("Go") { model.acceptRemote() }
            Button("Stay", role: .cancel) { model.declineRemote() }
        } message: {
            if let remote = model.remoteOffer {
                Text("\(Int((remote.percentage * 100).rounded()))% read there")
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

struct BlockView: View {
    let block: Block
    let fontSize: Double

    var body: some View {
        let style = block.style
        let size = fontSize * BlockText.scale(for: style)
        let text = Text(BlockText.attributed(text: block.text, spans: block.spans))
        switch style {
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\u{2022}")
                text
            }
            .font(.system(size: size))
            .foregroundStyle(.white)
        case .quote:
            text
                .font(.system(size: size).italic())
                .foregroundStyle(Color(white: 0.85))
                .padding(.leading, 8)
        default:
            if BlockText.isHeading(style) {
                text
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 6)
            } else {
                text
                    .font(.system(size: size))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Discreet status glyph; nothing is shown while idle.
struct SyncStatusIndicator: View {
    let status: SyncStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .offline:
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
