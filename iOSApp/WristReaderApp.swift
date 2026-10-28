import SwiftUI
import ReaderCore

@main
struct WristReaderApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var connectivity = PhoneConnectivity()
    @StateObject private var settings = SyncSettings()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    LibraryView(library: library, connectivity: connectivity, sendToWatch: sendToWatch)
                }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                NavigationStack { SettingsView(settings: settings) }
                    .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            .onOpenURL { url in
                if url.isFileURL { library.importEPUB(from: url) }
            }
            .onAppear(perform: wire)
        }
    }

    private func wire() {
        connectivity.activate()
        library.onImported = { entry in sendToWatch(entry) } // auto-send
        library.onDeleted = { connectivity.sendDelete(hash: $0.documentHash) }
        connectivity.onTransferFinished = { library.markSent(hash: $0) }
        settings.onSave = { c in
            connectivity.sendSettings(server: c.serverURL.absoluteString, user: c.username, password: c.password)
        }
    }

    private func sendToWatch(_ entry: LibraryEntry) {
        connectivity.send(book: entry, fileURL: library.fileURL(for: entry),
                          formatVersion: ProcessedBook.currentFormatVersion)
    }
}
