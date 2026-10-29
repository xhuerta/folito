import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    var sendToWatch: (LibraryEntry) -> Void
    @State private var showImporter = false
    @State private var pendingDelete: LibraryEntry?

    private static let epubType = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data

    var body: some View {
        List {
            WatchStatusSection(status: connectivity.status)
            if library.entries.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Books", systemImage: "books.vertical")
                    } description: {
                        Text("Import an EPUB file to read it on your Apple Watch. You can also open EPUB files from the Files app or the share sheet. Books are sent to your watch automatically.").systemSecondaryText()
                    } actions: {
                        Button("Import EPUB") { showImporter = true }
                            .disabled(library.isImporting)
                    }
                }
            } else {
                Section {
                    ForEach(library.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text("Books").systemSecondaryText()
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
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
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                              set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("Delete Book", role: .destructive) { library.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The book is also removed from your Apple Watch, together with its reading position there.")
        }
    }

    private var deleteTitle: String {
        guard let entry = pendingDelete else { return "" }
        return String(localized: "Delete “\(entry.title)”?", comment: "Confirmation title; the placeholder is the book title")
    }

    private func row(_ entry: LibraryEntry) -> some View {
        let state = BookWatchState(sentToWatch: entry.sentToWatch,
                                   inFlight: connectivity.outstandingHashes.contains(entry.documentHash))
        let canResend = connectivity.status.canSend && state != .sending
        return BookRow(entry: entry, state: state)
            // VoiceOver reads the row as one element ("title, author, size, watch state"); the swipe and
            // context-menu actions are offered in the Actions rotor.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("libraryRow")
            .accessibilityActions {
                if canResend {
                    Button("Send to Apple Watch Again") { sendToWatch(entry) }
                }
                Button("Delete") { pendingDelete = entry }
            }
            .swipeActions(edge: .trailing) {
                // Not `role: .destructive`: the row must stay until the deletion is confirmed.
                Button { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
            .swipeActions(edge: .leading) {
                if canResend {
                    Button { sendToWatch(entry) } label: { Label("Send Again", systemImage: "applewatch.and.arrow.forward") }
                }
            }
            .contextMenu {
                if canResend {
                    Button { sendToWatch(entry) } label: {
                        Label("Send to Apple Watch Again", systemImage: "applewatch.and.arrow.forward")
                    }
                }
                Button(role: .destructive) { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
            }
    }
}

/// One library row: title, author, then size and watch state (stacked at accessibility text sizes).
private struct BookRow: View {
    let entry: LibraryEntry
    let state: BookWatchState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
            Text(entry.author)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                TintedLabel(verbatim: state.text, systemImage: state.systemImage,
                            tint: state == .onWatch ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                Text(DisplayFormat.fileSize(entry.size))
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
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
                    Text("Pair an Apple Watch with this iPhone to read on your wrist. Books you import stay here and are sent once a watch is paired.").systemSecondaryText()
                }
            }
        case .appNotInstalled:
            Section {
                ContentUnavailableView {
                    Label("Folito Isn’t on Your Apple Watch", systemImage: "applewatch")
                } description: {
                    Text("Open the Watch app on this iPhone, find Folito under Available Apps and tap Install. Your books are sent automatically once it’s installed.").systemSecondaryText()
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
