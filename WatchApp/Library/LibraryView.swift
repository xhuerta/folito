import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: BookLibrary
    @State private var opened: LibraryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "book.closed").font(.title2)
                        Text("No books yet").font(.headline)
                        Text("Send a book from WristReader on your iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        ForEach(library.entries) { entry in
                            NavigationLink(value: entry) {
                                BookRow(entry: entry, fraction: library.progress[entry.documentHash] ?? 0)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.delete(documentHash: entry.documentHash)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryEntry.self) { entry in
                ReaderLoaderView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink(destination: SettingsView()) { Image(systemName: "gearshape") }
                }
            }
            .onAppear { library.reloadProgress() }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.headline).lineLimit(2)
            if !entry.author.isEmpty {
                Text(entry.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(Int((fraction * 100).rounded()))% read")
                .font(.caption2).foregroundStyle(.tint)
        }
    }
}

/// Loads and decodes the book off the main thread, then shows the reader.
struct ReaderLoaderView: View {
    let entry: LibraryEntry
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var model: ReaderViewModel?
    @State private var failed = false

    var body: some View {
        Group {
            if let model {
                ReaderView(model: model)
            } else if failed {
                Text("Could not open this book. Delete it and send it again.")
                    .font(.footnote).multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let box = try await library.loadBook(entry)
                model = ReaderViewModel(book: box.book, positions: env.positions, sync: sync,
                                        dictionary: env.dictionary)
            } catch {
                failed = true
            }
        }
    }
}
