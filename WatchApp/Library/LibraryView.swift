import SwiftUI
import ReaderCore

struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: BookLibrary
    /// Book waiting for the user to confirm its deletion.
    @State private var pendingDelete: LibraryEntry?
    @State private var path = NavigationPath()
    @AppStorage(ReaderSettings.showCoversKey) private var showCovers = true

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.entries.isEmpty {
                    ScrollView {
                        ContentUnavailableView {
                            Label("No Books", systemImage: "books.vertical")
                        } description: {
                            Text("Add books in the Folito app on your iPhone. They arrive on this watch automatically and can be read offline.")
                        }
                    }
                } else {
                    List {
                        // Finished books after the others (newest first within each group).
                        ForEach(library.displayedEntries) { entry in
                            NavigationLink(value: entry) {
                                BookRow(entry: entry, fraction: library.progress[entry.documentHash] ?? 0,
                                        cover: showCovers ? library.cover(for: entry) : nil, showCover: showCovers)
                            }
                            .accessibilityIdentifier("libraryRow")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    pendingDelete = entry
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            // Same action for VoiceOver users (actions rotor), who cannot swipe the row.
                            .accessibilityAction(named: Text("Delete")) { pendingDelete = entry }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryEntry.self) { entry in
                ReaderLoaderView(entry: entry)
            }
            .navigationDestination(for: SettingsRoute.self) { $0.destination }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SettingsRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, titleVisibility: .visible,
                                presenting: pendingDelete) { entry in
                Button("Delete Book", role: .destructive) {
                    library.delete(documentHash: entry.documentHash, byUser: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its reading position on this watch is removed too. You can send the book again from your iPhone.")
            }
            .onAppear {
                library.reloadProgress()
                // Back from the reader: the iPhone library shows the updated time left (library context).
                library.onLibraryChanged?()
                consumeDeepLink()
            }
            .onChange(of: env.deepLink) { _ in consumeDeepLink() }
        }
    }

    private func consumeDeepLink() {
        guard let request = env.deepLink else { return }
        env.deepLink = nil
        open(request.link)
    }

    /// Complication tap: the book at its saved position (a fresh reader), or the library itself.
    private func open(_ link: FolitoDeepLink) {
        var newPath = NavigationPath()
        if case .book(let id) = link, let entry = library.entries.first(where: { $0.documentHash == id }) {
            newPath.append(entry)
        }
        path = newPath
    }

    private var deleteTitle: Text {
        Text("Delete \u{201C}\(pendingDelete?.title ?? "")\u{201D}?",
             comment: "Confirmation title before deleting a book from the watch. The argument is the book title.")
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

extension LibraryEntry: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(documentHash) }
    static func == (lhs: LibraryEntry, rhs: LibraryEntry) -> Bool {
        lhs.documentHash == rhs.documentHash && lhs.title == rhs.title
    }
}

struct BookRow: View {
    let entry: LibraryEntry
    let fraction: Double
    /// The cover thumbnail from the iPhone; nil (with `showCover`) draws a plain tile in the book's colour.
    var cover: UIImage? = nil
    /// Settings > Show Covers. Off: exactly the text-only row.
    var showCover = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if showCover {
            // The cover keeps its size at every text size; the text wraps beside it.
            HStack(alignment: .top, spacing: 8) {
                WatchCover(image: cover, title: entry.title)
                    .padding(.top, 2)
                text
            }
            // One VoiceOver element, as without covers: the cover is decorative.
            .accessibilityElement(children: .combine)
        } else {
            text
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.isNew {
                // First in the row, so VoiceOver reads "New, Title, Author, 0% read" (like Mail's "Unread").
                NewBadge()
            }
            Text(entry.title)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 3)
            if !entry.author.isEmpty {
                Text(entry.author)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            if entry.isFinished {
                // A check mark and the word, never colour only.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityHidden(true)
                    Text("Finished", comment: "Library row: the book has been read to the end")
                }
                .font(.footnote).foregroundStyle(.tint)
                .accessibilityIdentifier("finishedLabel")
            } else {
                Text(ReadingProgressFormat.read(fraction))
                    .font(.footnote).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        // One VoiceOver element: "Title, Author, 43% read" (or "…, Finished"; "New, …" for a book not opened yet).
        .accessibilityElement(children: .combine)
    }
}

/// The "New" badge of a book that arrived from the iPhone and has not been opened yet (#156): the word on a capsule
/// in the accent colour. Black on the accent (#4DA6FF) is about 8:1 (checked in AccessibilityTests); the word
/// carries the meaning, not the colour. A text style, so it scales with Dynamic Type.
struct NewBadge: View {
    /// The watch app's AccentColor (Assets.xcassets/AccentColor), for the contrast test.
    static let accent = ThemePalette.RGB(0.302, 0.651, 1.0)

    var body: some View {
        Text("New", comment: "Library row badge (and its VoiceOver label): the book arrived from the iPhone and has not been opened yet")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityIdentifier("newBadge")
    }
}

/// A book cover in a watch Library row: the thumbnail from the iPhone, or a tile in the colour the iPhone uses
/// for the book's placeholder (`CoverPalette`) with a book symbol. Decorative.
struct WatchCover: View {
    let image: UIImage?
    let title: String
    static let size = CGSize(width: 30, height: 45)

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let c = CoverPalette.rgb(for: title)
                ZStack {
                    Color(red: c.red, green: c.green, blue: c.blue)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// Loads and decodes the book off the main thread, then shows the reader.
struct ReaderLoaderView: View {
    let entry: LibraryEntry
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderViewModel?
    @State private var failure: String?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let model {
                ReaderView(model: model)
            } else if let failure {
                ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title3).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(failure)
                            .font(.footnote).multilineTextAlignment(.center)
                        Button("Delete Book", role: .destructive) { confirmDelete = true }
                    }
                }
                .navigationTitle(entry.title)
                .confirmationDialog(Text("Delete \u{201C}\(entry.title)\u{201D}?",
                                         comment: "Confirmation title before deleting a book from the watch. The argument is the book title."),
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Book", role: .destructive) {
                        library.delete(documentHash: entry.documentHash, byUser: true)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                ProgressView {
                    Text("Opening\u{2026}")
                }
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let box = try await library.loadBook(entry)
                let reader = ReaderViewModel(book: box.book, positions: env.positions, sync: sync,
                                             dictionary: env.dictionary, complications: env.complications)
                let hash = entry.documentHash
                library.markOpened(hash)
                reader.isFinished = library.isFinished(hash)
                reader.haptics = WatchHaptics()
                let store = library
                reader.onSetReadStatus = { [weak store] status in
                    store?.setReadStatus(status, documentHash: hash)
                }
                model = reader
            } catch {
                failure = WatchMessages.bookOpenFailure(error)
            }
        }
    }
}
