import SwiftUI
import ReaderCore

@main
struct WristReaderApp: App {
    // Debug builds honour the UI-testing launch arguments (isolated, optionally seeded library); Release
    // builds always use the real library. See UITestingSupport.swift.
    @StateObject private var library = UITesting.makeLibrary()
    @StateObject private var connectivity = PhoneConnectivity()
    @StateObject private var settings = SyncSettings()
    @StateObject private var typography = TypographyModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    LibraryView(library: library, connectivity: connectivity, sendToWatch: sendToWatch)
                }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                NavigationStack { TypographySettingsView(typography: typography) }
                    .tabItem { Label("Reading", systemImage: "textformat.size") }
                NavigationStack { SettingsView(settings: settings) }
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .onOpenURL { url in
                if url.isFileURL { library.importEPUB(from: url) }
            }
            .onAppear(perform: wire)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connectivity.syncWatchState() }
            }
        }
    }

    private func wire() {
        library.onImported = { entry in
            sendToWatch(entry) // auto-send
            Announcer.announce(String(localized: "Imported “\(entry.title)”.",
                                      comment: "VoiceOver announcement after an import; the placeholder is the book title"))
        }
        library.onDeleted = { connectivity.sendDelete(hash: $0.documentHash) }
        connectivity.onTransferFinished = { library.markSent(hash: $0) }
        // Settings and unconfirmed books are (re)sent whenever the session activates, the watch app
        // gets installed, reachability changes, the app returns to foreground or the watch reports
        // its library; Save just triggers the same path.
        connectivity.settingsProvider = { settings.savedForWatch() }
        connectivity.unsentBooksProvider = { library.unsentBooks }
        connectivity.onWatchLibrary = { library.reconcile(watchHashes: $0, inFlight: connectivity.outstandingHashes) }
        connectivity.clearedStampProvider = { settings.clearedStamp }
        settings.onSave = { _ in connectivity.syncWatchState() }
        settings.onTurnOff = { connectivity.syncWatchState() }
        // Typography: edits on the phone are pushed with their stamp; the watch's copy wins if newer.
        connectivity.typographyProvider = { typography.value }
        connectivity.onWatchTypography = { typography.applyRemote($0) }
        typography.onLocalChange = { _ in connectivity.syncWatchState() }
        connectivity.activate()
    }

    private func sendToWatch(_ entry: LibraryEntry) {
        connectivity.send(book: entry, fileURL: library.fileURL(for: entry),
                          formatVersion: ProcessedBook.currentFormatVersion)
    }
}
