import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: BookLibrary
    /// Book waiting for the user to confirm its deletion.
    @State private var pendingDelete: LibraryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    ScrollView {
                        ContentUnavailableView {
                            Label("No Books", systemImage: "books.vertical")
                        } description: {
                            Text("Send an EPUB from WristReader on your iPhone. Books you send can be read here offline.")
                        }
                    }
                } else {
                    List {
                        ForEach(library.entries) { entry in
                            NavigationLink(value: entry) {
                                BookRow(entry: entry, fraction: library.progress[entry.documentHash] ?? 0)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, titleVisibility: .visible,
                                presenting: pendingDelete) { entry in
                Button("Delete Book", role: .destructive) {
                    library.delete(documentHash: entry.documentHash)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its reading position on this watch is removed too. You can send the book again from your iPhone.")
            }
            .onAppear { library.reloadProgress() }
        }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 5 : 3)
            if !entry.author.isEmpty {
                Text(entry.author)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            Text(ReadingProgressFormat.read(fraction))
                .font(.footnote).foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
        // One VoiceOver element: "Title, Author, 43% read".
        .accessibilityElement(children: .combine)
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
                        library.delete(documentHash: entry.documentHash)
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
                model = ReaderViewModel(book: box.book, positions: env.positions, sync: sync,
                                        dictionary: env.dictionary)
            } catch {
                failure = WatchMessages.bookOpenFailure(error)
            }
        }
    }
}
