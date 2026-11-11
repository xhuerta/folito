import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    var sendToWatch: (LibraryEntry) -> Void
    /// The Readest side of the library (nil in previews and when the app did not inject it).
    @Environment(ReadestLibraryModel.self) private var readest: ReadestLibraryModel?
    @State private var showImporter = false
    @State private var deletion = BookDeletion()
    @State private var showOtherSamples = false
    @AppStorage("library.filter") private var filterRaw = LibraryFilter.all.rawValue

    private static let epubType = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data

    private var filter: LibraryFilter {
        readest?.isAvailable == true ? (LibraryFilter(rawValue: filterRaw) ?? .all) : .all
    }

    private var items: [MergedLibraryItem<LibraryEntry>] {
        readest?.merged(library.entries) ?? LibraryMerge.merge(local: library.entries, hash: \.documentHash, cloud: [])
    }

    var body: some View {
        withPresentations(
            bookList
            .readableScrollEdges()
            .navigationTitle("Library")
            .refreshable {
                connectivity.syncWatchState()
                await readest?.refresh()
                await readest?.relinkDownloadedBooks(in: library)
            }
            .task {
                await readest?.refreshIfStale()
                await readest?.relinkDownloadedBooks(in: library)
            }
            .toolbar { toolbarContent }
            .navigationDestination(for: BookDetailRoute.self) { route in
                BookDetailView(hash: route.hash, library: library, connectivity: connectivity, sendToWatch: sendToWatch)
            }
        )
        .modifier(BookDeletionDialogs(library: library, readest: readest, deletion: $deletion))
        .task { library.fillMissingCovers() }
    }

    private var bookList: some View {
        let all = items
        let shown = all.filter { filter.includes($0.availability) }
        return List {
            WatchStatusSection(status: connectivity.status)
            if all.isEmpty {
                emptyLibrarySection
            } else if shown.isEmpty {
                emptyFilterSection
            } else {
                booksSection(shown)
            }
            if all.isEmpty, ReadestFooter.hasMessage(readest, hasCloudOnly: false) {
                Section {} footer: { ReadestFooter(readest: readest, hasCloudOnly: false) }
            }
        }
    }

    private var emptyLibrarySection: some View {
        Section {
            ContentUnavailableView {
                Label("No Books", systemImage: "books.vertical")
            } description: {
                Text("Import an EPUB file to read it on your Apple Watch. You can also open EPUB files from the Files app or the share sheet. Books are sent to your watch automatically.").foregroundStyle(.secondaryText)
            } actions: {
                // Borderless: in a List row, plain buttons all fire on a tap anywhere in the row.
                Button { showImporter = true } label: { Text("Import EPUB").minimumHitArea() }
                    .buttonStyle(.borderless)
                    .disabled(library.isImporting)
                // A bundled public-domain book, imported like any other (see SampleBooks).
                Button { library.addSample(language: SampleBooks.preferredLanguage) } label: { Text("Add a Sample Book").minimumHitArea() }
                    .buttonStyle(.borderless)
                    .disabled(library.isImporting)
                    .accessibilityIdentifier("libraryAddSample")
                Button {
                    showOtherSamples = true
                } label: {
                    Text("Other Languages…", comment: "Button: choose a sample book in another language")
                        .minimumHitArea()
                }
                .buttonStyle(.borderless)
                .disabled(library.isImporting)
                .accessibilityHint("Shows the sample books in every language.")
                .accessibilityIdentifier("libraryOtherSamples")
            }
        }
    }

    private var emptyFilterSection: some View {
        Section {
            ContentUnavailableView {
                if filter == .inReadest {
                    Label("No Books in Readest", systemImage: "icloud")
                } else {
                    Label("No Books on This iPhone", systemImage: "iphone")
                }
            } description: {
                if filter == .inReadest {
                    Text("Upload a book from its menu to keep it in your Readest library.").foregroundStyle(.secondaryText)
                } else {
                    Text("Download a book from Readest, or import an EPUB file.").foregroundStyle(.secondaryText)
                }
            }
        }
    }

    /// The footer is only added when it has something to say: an empty section footer is an unlabelled
    /// accessibility element ("Element has no description").
    @ViewBuilder
    private func booksSection(_ shown: [MergedLibraryItem<LibraryEntry>]) -> some View {
        let hasCloudOnly = shown.contains { $0.availability == .readestOnly }
        if ReadestFooter.hasMessage(readest, hasCloudOnly: hasCloudOnly) {
            Section {
                bookRows(shown)
            } header: {
                Text("Books").foregroundStyle(.secondaryText)
            } footer: {
                ReadestFooter(readest: readest, hasCloudOnly: hasCloudOnly)
            }
        } else {
            Section {
                bookRows(shown)
            } header: {
                Text("Books").foregroundStyle(.secondaryText)
            }
        }
    }

    /// Rows are identified by their hash *and* their shape (local / Readest / both, uploading, downloading):
    /// when a row gains or loses a line ("Uploading to Readest…", the download progress) the
    /// List gets a new cell sized for it. Updated in place, the cell kept its old height and, at accessibility
    /// text sizes, squeezed the watch state to one truncated line ("Waiting for…").
    private func bookRows(_ shown: [MergedLibraryItem<LibraryEntry>]) -> some View {
        let rows: [ShapedItem] = shown.map { ShapedItem(id: rowShapeID($0), item: $0) }
        return ForEach(rows) { shaped in
            let item = shaped.item
            if let entry = item.local {
                row(entry, cloud: item.cloud)
            } else if let book = item.cloud {
                cloudRow(book)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let readest, readest.isAvailable {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Show", selection: $filterRaw) {
                        Label("All", systemImage: "books.vertical").tag(LibraryFilter.all.rawValue)
                        Label("On This iPhone", systemImage: "iphone").tag(LibraryFilter.onThisDevice.rawValue)
                        Label("In Readest", systemImage: "icloud").tag(LibraryFilter.inReadest.rawValue)
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle"
                                                                : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityValue(filterName)
                .accessibilityIdentifier("libraryFilterMenu")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if library.isImporting {
                ProgressView()
                    .accessibilityLabel("Importing book")
            } else {
                Button { showImporter = true } label: {
                    Label("Import EPUB", systemImage: "plus")
                }
            }
        }
    }

    /// Sheets, the file importer, alerts and confirmation dialogs of the Library.
    private func withPresentations<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showOtherSamples) {
            SampleBookPicker(library: library) { _ = library.addSample(language: $0) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [Self.epubType]) { result in
            switch result {
            case .success(let url): library.importEPUB(from: url)
            case .failure: library.importError = .pickerFailed()
            }
        }
        .alert(library.importError?.title ?? "",
               isPresented: Binding(get: { library.importError != nil },
                                    set: { if !$0 { library.importError = nil } }),
               presenting: library.importError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .alert(readest?.alert?.title ?? "",
               isPresented: Binding(get: { readest?.alert != nil },
                                    set: { if !$0 { readest?.alert = nil } }),
               presenting: readest?.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    private var filterName: String {
        switch filter {
        case .all: return String(localized: "All", comment: "Library filter: every book")
        case .onThisDevice: return String(localized: "On This iPhone", comment: "Library filter")
        case .inReadest: return String(localized: "In Readest", comment: "Library filter")
        }
    }

    private struct ShapedItem: Identifiable {
        let id: String
        let item: MergedLibraryItem<LibraryEntry>
    }

    private func rowShapeID(_ item: MergedLibraryItem<LibraryEntry>) -> String {
        let uploading = readest?.uploading.contains(item.hash) == true
        let downloading = readest?.downloads[item.hash] != nil
        return "\(item.hash)|\(item.availability)|\(uploading)|\(downloading)"
    }

    /// Delete: a book that is also in Readest asks where to delete it from.
    private func requestDelete(_ entry: LibraryEntry, inReadest: Bool) {
        deletion.request(entry, inReadest: inReadest)
    }

    private func row(_ entry: LibraryEntry, cloud: ReadestCloudBook?) -> some View {
        let state = BookWatchState(sentToWatch: entry.sentToWatch,
                                   inFlight: connectivity.outstandingHashes.contains(entry.documentHash))
        let canResend = connectivity.status.canSend && state != .sending
        let readestOn = readest?.isAvailable == true
        let inReadest = readestOn && cloud != nil
        let isUploading = readest?.uploading.contains(entry.documentHash) == true
        let canUpload = readestOn && !inReadest && !isUploading
        // Tapping the row opens the book's details (cover, description, series, actions); the swipe,
        // context-menu and rotor actions stay on the row.
        return NavigationLink(value: BookDetailRoute(hash: entry.documentHash)) {
            BookRow(entry: entry, state: state,
                    timeLeft: state == .onWatch ? connectivity.watchTimeRemaining[entry.documentHash] : nil,
                    inReadest: inReadest, isUploading: isUploading,
                    cover: entry.hasCover == true ? CoverImages.shared.cover(hash: entry.documentHash,
                                                                            in: library.booksDirectory) : nil)
        }
            // VoiceOver reads the row as one element ("title, author, size, watch state"); the swipe and
            // context-menu actions are offered in the Actions rotor.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("libraryRow")
            .accessibilityActions {
                if canResend {
                    Button("Send to Apple Watch Again") { sendToWatch(entry) }
                }
                if canUpload {
                    Button("Upload to Readest") { upload(entry) }
                }
                if inReadest {
                    Button("Remove Download") { library.delete(entry) }
                }
                Button("Delete") { requestDelete(entry, inReadest: inReadest) }
            }
            .swipeActions(edge: .trailing) {
                // Not `role: .destructive`: the row must stay until the deletion is confirmed.
                Button { requestDelete(entry, inReadest: inReadest) } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
                if inReadest {
                    Button { library.delete(entry) } label: { Label("Remove Download", systemImage: "xmark.icloud") }
                        .tint(.gray)
                }
            }
            .swipeActions(edge: .leading) {
                if canResend {
                    Button { sendToWatch(entry) } label: { Label("Send Again", systemImage: "applewatch.and.arrow.forward") }
                }
                if canUpload {
                    Button { upload(entry) } label: { Label("Upload", systemImage: "icloud.and.arrow.up") }
                        .tint(.blue)
                }
            }
            .contextMenu {
                if canResend {
                    Button { sendToWatch(entry) } label: {
                        Label("Send to Apple Watch Again", systemImage: "applewatch.and.arrow.forward")
                    }
                }
                if canUpload {
                    Button { upload(entry) } label: { Label("Upload to Readest", systemImage: "icloud.and.arrow.up") }
                }
                if inReadest {
                    Button { library.delete(entry) } label: { Label("Remove Download", systemImage: "xmark.icloud") }
                }
                Button(role: .destructive) { requestDelete(entry, inReadest: inReadest) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func upload(_ entry: LibraryEntry) {
        Task { await readest?.upload(entry, from: library) }
    }

    private func download(_ book: ReadestCloudBook) {
        Task { await readest?.download(book, into: library) }
    }

    /// A book that is only in Readest: tap the row (or its download button) to download it.
    private func cloudRow(_ book: ReadestCloudBook) -> some View {
        let progress = readest?.downloads[book.hash]
        let offline = readest?.isOffline == true
        let button = Button { download(book) } label: {
            CloudBookRow(book: book, cover: readest?.covers[book.hash], progress: progress, offline: offline)
        }
        .disabled(progress != nil)
        return cloudRowActions(cloudRowAccessibility(button, book: book, progress: progress, offline: offline),
                               book: book, downloading: progress != nil)
    }

    private func cloudRowAccessibility<Content: View>(_ content: Content, book: ReadestCloudBook,
                                                      progress: Double?, offline: Bool) -> some View {
        let hint = progress == nil && !offline ? Text("Double-tap to download.") : Text(verbatim: "")
        return content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(book.title), \(book.author)"))
            .accessibilityValue(cloudStatus(progress: progress, offline: offline))
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("libraryCloudRow")
    }

    private func cloudRowActions<Content: View>(_ content: Content, book: ReadestCloudBook, downloading: Bool) -> some View {
        content
            .accessibilityActions {
                if !downloading { Button("Download") { download(book) } }
                Button("Delete from Readest") { deletion.readestBook = book }
            }
            .swipeActions(edge: .trailing) {
                Button { deletion.readestBook = book } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
            .swipeActions(edge: .leading) {
                if !downloading {
                    Button { download(book) } label: { Label("Download", systemImage: "icloud.and.arrow.down") }
                        .tint(.blue)
                }
            }
            .contextMenu {
                if !downloading {
                    Button { download(book) } label: { Label("Download", systemImage: "icloud.and.arrow.down") }
                }
                Button(role: .destructive) { deletion.readestBook = book } label: {
                    Label("Delete from Readest", systemImage: "trash")
                }
            }
    }

    private func cloudStatus(progress: Double?, offline: Bool) -> String {
        if let progress {
            return String(localized: "Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))",
                          comment: "VoiceOver value of a book being downloaded from Readest; the placeholder is a percentage")
        }
        if offline {
            return String(localized: "In Readest, not downloaded. Needs an internet connection.",
                          comment: "VoiceOver value of a Readest book while offline")
        }
        return String(localized: "In Readest, not downloaded", comment: "VoiceOver value of a book that is only in Readest")
    }
}

/// A book that is only in Readest, like a not-downloaded file in Files: cover, title, author and a trailing
/// download accessory (`icloud.and.arrow.down`), or the download progress.
private struct CloudBookRow: View {
    let book: ReadestCloudBook
    let cover: UIImage?
    let progress: Double?
    let offline: Bool

    var body: some View {
        // The cover shows at every text size: a layout that switches at `isAccessibilitySize` is replaced under
        // the Dynamic Type audits (docs/ACCESSIBILITY.md).
        HStack(spacing: 12) {
            CoverThumbnail(image: cover, title: book.title, author: book.author)
                .opacity(offline ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: book.title)
                    .font(.headline)
                    .foregroundStyle(offline ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.primary))
                Text(verbatim: book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                Group {
                    if let progress {
                        Text("Downloading… \(progress.formatted(.percent.precision(.fractionLength(0))))",
                             comment: "Status of a book being downloaded from Readest; the placeholder is a percentage")
                    } else if offline {
                        Text("Needs an internet connection to download")
                    } else {
                        Text("In Readest")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 8)
            Group {
                if let progress {
                    DownloadRing(fraction: progress)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(offline ? AnyShapeStyle(.secondaryText) : AnyShapeStyle(.tint))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Determinate progress ring (the circular `ProgressView` style is indeterminate on iOS).
private struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
        .animation(.linear(duration: 0.2), value: fraction)
        .accessibilityHidden(true)
    }
}

/// Under the book list: Readest states (offline, refresh error, sign in again).
private struct ReadestFooter: View {
    let readest: ReadestLibraryModel?
    let hasCloudOnly: Bool

    /// True when `body` shows a message (sign in again, offline, or a refresh error).
    @MainActor
    static func hasMessage(_ readest: ReadestLibraryModel?, hasCloudOnly: Bool) -> Bool {
        guard let readest else { return false }
        if readest.needsSignIn { return true }
        guard readest.isAvailable else { return false }
        return (readest.isOffline && hasCloudOnly) || readest.refreshError != nil
    }

    var body: some View {
        if let readest {
            VStack(alignment: .leading, spacing: 6) {
                if readest.needsSignIn {
                    Text("To see your Readest library here, sign out of Readest in Settings › Progress Sync and sign in again.")
                } else if readest.isAvailable {
                    if readest.isOffline && hasCloudOnly {
                        Label("You’re offline. Books in Readest need a connection to download.", systemImage: "wifi.slash")
                    } else if let error = readest.refreshError {
                        Label {
                            Text(verbatim: error)
                        } icon: {
                            Image(systemName: "exclamationmark.icloud")
                        }
                    }
                }
            }
            .foregroundStyle(.secondaryText)
        }
    }
}

/// One library row: title, author, then watch state, time left (once the watch reports it) and size (stacked at accessibility text sizes).
private struct BookRow: View {
    let entry: LibraryEntry
    let state: BookWatchState
    /// Reading time left as estimated by the watch; nil until the book has been opened there.
    var timeLeft: TimeInterval? = nil
    /// Also in the user's Readest library: a small `checkmark.icloud`, like a downloaded item in Files.
    var inReadest = false
    var isUploading = false
    /// The stored cover; nil draws the placeholder.
    var cover: UIImage? = nil

    var body: some View {
        // The cover shows at every text size, as in the Readest rows (CloudBookRow).
        HStack(spacing: 12) {
            CoverThumbnail(image: cover, title: entry.title, author: entry.author)
            details
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
            Text(entry.author)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            WrappingHStack(spacing: 12, lineSpacing: 4) {
                TintedLabel(verbatim: state.text, systemImage: state.systemImage,
                            tint: state == .onWatch ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                if let timeLeft {
                    Text(DisplayFormat.timeLeft(timeLeft))
                        .accessibilityLabel(Text(DisplayFormat.timeLeft(timeLeft, style: .full)))
                }
                // The Readest icon stays next to the size, so the two never wrap apart.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DisplayFormat.fileSize(entry.size))
                    if inReadest && !isUploading {
                        Image(systemName: "checkmark.icloud")
                            .accessibilityLabel(Text("In Readest"))
                    }
                }
                if entry.isSample { SampleBadge() }
                if isUploading {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Uploading to Readest…")
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
    }
}

/// Lays its children out left to right and wraps to a new line when the next one does not fit, at every text
/// size. A switch between an `HStack` and a `VStack` at `isAccessibilitySize` is replaced under the Dynamic Type
/// audits, which flagged the whole row (docs/ACCESSIBILITY.md, "Layouts that switch at a fixed text size").
private struct WrappingHStack: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Frames relative to the top leading corner; each child is centred vertically on its line.
    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = width ?? .infinity
        let childProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
        var frames: [CGRect] = []
        var lines: [(range: Range<Int>, height: CGFloat)] = []
        var lineStart = 0, x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(childProposal)
            if x > 0, x + size.width > maxWidth {
                lines.append((lineStart..<index, lineHeight))
                lineStart = index
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        lines.append((lineStart..<frames.count, lineHeight))
        for line in lines {
            for index in line.range {
                frames[index].origin.y += (line.height - frames[index].height) / 2
            }
        }
        return (CGSize(width: min(usedWidth, maxWidth), height: frames.isEmpty ? 0 : y + lineHeight), frames)
    }
}

/// Top of the Library: what the user needs to know about the Apple Watch.
private struct WatchStatusSection: View {
    let status: WatchStatus

    var body: some View {
        switch status {
        case .unsupported, .activating:
            EmptyView()
        case .notPaired:
            Section {
                ContentUnavailableView {
                    Label("No Apple Watch", systemImage: "applewatch.slash")
                } description: {
                    Text("Pair an Apple Watch with this iPhone to read on your wrist. Books you import stay here and are sent once a watch is paired.").foregroundStyle(.secondaryText)
                }
            }
        case .appNotInstalled:
            Section {
                ContentUnavailableView {
                    Label("Folito Isn’t on Your Apple Watch", systemImage: "applewatch")
                } description: {
                    Text("Open the Watch app on this iPhone, find Folito under Available Apps and tap Install. Your books are sent automatically once it’s installed.").foregroundStyle(.secondaryText)
                }
            }
        case .ready(let reachable):
            Section {
                if reachable {
                    Label("Apple Watch connected", systemImage: "applewatch.radiowaves.left.and.right")
                } else {
                    Label("Books are sent to your Apple Watch in the background.", systemImage: "applewatch")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView(library: LibraryStore(rootDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("preview-library")),
                    connectivity: PhoneConnectivity(), sendToWatch: { _ in })
    }
}

private extension View {
    /// Borderless buttons only hit-test their text; keep the 44 pt minimum target.
    func minimumHitArea() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}
