import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var connectivity: PhoneConnectivity
    var sendToWatch: (LibraryEntry) -> Void
    @State private var showImporter = false

    private static let epubType = UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub") ?? .data

    var body: some View {
        List {
            Section {
                Label(connectivity.statusText, systemImage: connectivity.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                    .font(.footnote)
            }
            Section("Books") {
                if library.entries.isEmpty {
                    Text("No books yet. Tap + to import an EPUB.").foregroundStyle(.secondary)
                }
                ForEach(library.entries) { entry in
                    row(entry)
                }
                .onDelete { offsets in offsets.map { library.entries[$0] }.forEach(library.delete) }
            }
        }
        .navigationTitle("WristReader")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if library.isImporting { ProgressView() }
                else { Button { showImporter = true } label: { Image(systemName: "plus") } }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [Self.epubType]) { result in
            if case .success(let url) = result { library.importEPUB(from: url) }
            else if case .failure(let e) = result { library.errorMessage = e.localizedDescription }
        }
        .alert("Error", isPresented: Binding(get: { library.errorMessage != nil },
                                              set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(library.errorMessage ?? "") }
    }

    @ViewBuilder private func row(_ entry: LibraryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(2)
                Text(entry.author).font(.subheadline).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if connectivity.outstandingHashes.contains(entry.documentHash) {
                ProgressView()
            } else {
                Button { sendToWatch(entry) } label: {
                    Image(systemName: entry.sentToWatch ? "checkmark.circle.fill" : "applewatch.and.arrow.forward")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Send to watch")
            }
        }
    }
}
