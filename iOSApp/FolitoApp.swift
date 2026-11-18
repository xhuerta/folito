import SwiftUI
import ReaderCore

@main
struct FolitoApp: App {
    // Debug builds honour the UI-testing launch arguments (isolated, optionally seeded library); Release
    // builds always use the real library. See UITestingSupport.swift.
    @StateObject private var library = UITesting.makeLibrary()
    @StateObject private var connectivity = PhoneConnectivity()
    @StateObject private var settings = UITesting.makeSyncSettings()
    // Readest books in the Library (browse, download, upload); see docs/READEST_SYNC.md.
    @State private var readest = UITesting.makeReadestLibrary()
    @StateObject private var typography = TypographyModel()
    @StateObject private var dictionaries = UITesting.makeDictionaryManager()
    // Optional lookup of missing covers and descriptions on Open Library; off by default (docs/ONLINE_METADATA.md).
    @StateObject private var onlineMetadata = UITesting.makeOnlineMetadata()
    // Welcome tour: opens by itself on the first launch (UI-testing launches skip it unless asked; see
    // OnboardingPolicy) and from Settings › About.
    @StateObject private var onboarding = OnboardingModel()
    // App Store rating prompt after real reading (ReviewPromptPolicy); the Library asks at a calm moment.
    @StateObject private var reviewPrompt = ReviewPromptModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    LibraryView(library: library, connectivity: connectivity, sendToWatch: sendToWatchExplicitly,
                                reviewPrompt: reviewPrompt, isOnboardingShown: onboarding.isPresented)
                }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                NavigationStack { TypographySettingsView(typography: typography) }
                    .tabItem { Label("Reading", systemImage: "textformat.size") }
                NavigationStack { SettingsView(settings: settings, dictionaries: dictionaries, connectivity: connectivity) }
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .environment(\.showWelcomeTour, ShowWelcomeTourAction { onboarding.show() })
            .environment(readest)
            .environment(\.activeSyncConnectorID, settings.activeConnectorID)
            .environmentObject(onlineMetadata)
            .environmentObject(library)
            .environmentObject(dictionaries)
            .fullScreenCover(isPresented: $onboarding.isPresented) {
                OnboardingView(model: onboarding, library: library, connectivity: connectivity,
                               settings: settings, dictionaries: dictionaries)
                    .environment(readest)
            }
            .onOpenURL { url in
                if url.isFileURL { library.importEPUB(from: url) }
            }
            .onAppear(perform: wire)
            .onChange(of: connectivity.watchProgress) { _, progress in
                reviewPrompt.watchReported(progress: progress)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    connectivity.syncWatchState()
                    // Until the Readest rows are known the watch cannot tell which books are in the library and
                    // syncs every book (#167): load them now rather than when the Library is next shown.
                    if readest.isAvailable && !readest.hasListing { Task { await readest.refresh() } }
                }
            }
        }
    }

    private func wire() {
        library.onImported = { entry in
            sendToWatch(entry) // auto-send
            // The settings context again, so the watch knows at once whether the new book is in the Readest
            // library (#167) instead of keeping a list from before the import.
            connectivity.syncWatchState()
            readest.autoUploadIfNeeded(entry, from: library) // opt-in, off by default
            onlineMetadata.bookImported(entry, library: library) // opt-in, off by default
            Announcer.announce(String(localized: "Imported “\(entry.title)”.",
                                      comment: "VoiceOver announcement after an import; the placeholder is the book title"))
        }
        library.onDeleted = { connectivity.sendDelete(hash: $0.documentHash) }
        // A book that took its Readest row's id replaces its old copy on the watch (deleted just before).
        library.onRelinked = { entry, wasOnWatch in if wasOnWatch { sendToWatch(entry) } }
        // Covers: sent with each book; a book that gained one later (lazy fill) gets just the cover.
        connectivity.coverProvider = { library.watchCover(for: $0) }
        library.onCoverAdded = { entry in
            if entry.sentToWatch, let cover = library.watchCover(for: entry) {
                connectivity.send(cover: cover, hash: entry.documentHash)
            }
        }
        // An Open Library cover that was removed again: re-send the book, which replaces its cover on the watch with
        // the placeholder (the same transfer as "Send to Apple Watch Again").
        library.onCoverRemoved = { entry in
            if entry.sentToWatch { sendToWatch(entry) }
        }
        connectivity.onTransferFinished = { library.markSent(hash: $0) }
        // Settings and unconfirmed books are (re)sent whenever the session activates, the watch app
        // gets installed, reachability changes, the app returns to foreground or the watch reports
        // its library; Save just triggers the same path.
        connectivity.settingsProvider = { settings.savedForWatch() }
        connectivity.unsentBooksProvider = { library.unsentBooks }
        connectivity.onWatchLibrary = { report in
            library.reconcile(watchHashes: report.hashes, removed: report.removed, watchID: report.watchID,
                              inFlight: connectivity.outstandingHashes)
        }
        // Deleted on the watch by the user: shown at once and no longer sent automatically.
        connectivity.onWatchRemovedBook = { library.markRemovedOnWatch(hash: $0, watchID: $1) }
        connectivity.clearedStampProvider = { settings.clearedStamp }
        settings.onSave = { _ in
            connectivity.syncWatchState()
            configureReadest()
            Task { await readest.refresh() }
        }
        settings.onTurnOff = {
            connectivity.syncWatchState()
            configureReadest()
        }
        configureReadest()
        // Typography: edits on the phone are pushed with their stamp; the watch's copy wins if newer.
        connectivity.typographyProvider = { typography.value }
        connectivity.onWatchTypography = { typography.applyRemote($0) }
        typography.onLocalChange = { _ in connectivity.syncWatchState() }
        // Read status (Finished): mirrored on the watch, newer mark wins per book; books in Readest also sync
        // with the row's reading_status (ReadestLibraryModel.reconcileReadStatus).
        connectivity.readStatusProvider = { library.readStatusMarks }
        library.onReadStatusChanged = { connectivity.syncWatchState() }
        connectivity.onWatchReadStatus = { marks in
            if !library.mergeReadStatus(marks).isEmpty {
                Task { await readest.reconcileReadStatus(in: library) }
            }
        }
        // Which books sync (#167): the per-book switch, mirrored on the watch (newer wins per book), and, with
        // Readest, the books linked to a Readest row (only those sync there; an upload turns a book on).
        connectivity.bookSyncProvider = { library.bookSyncSwitches }
        connectivity.readestLinkedProvider = {
            settings.isReadestActive ? readest.linkedHashes(in: library.entries) : nil
        }
        library.onBookSyncChanged = { connectivity.syncWatchState() }
        connectivity.onWatchBookSync = { _ = library.mergeBookSyncSwitches($0) }
        readest.onRowsChanged = { connectivity.syncWatchState() }
        // Dictionaries: a new or updated one is sent right away; missing ones whenever the watch reports.
        connectivity.dictionariesProvider = { dictionaries.transferList() }
        dictionaries.onInstalled = { id in
            if let item = dictionaries.transferList().first(where: { $0.id == id }) {
                connectivity.send(dictionary: id, fileURL: item.fileURL, sha256: item.sha256, size: item.size)
            }
        }
        dictionaries.onDeleted = { connectivity.sendDeleteDictionary(id: $0) }
        connectivity.activate()
    }

    private func configureReadest() {
        readest.configure(store: settings.libraryCredentialStore, readestActive: settings.isReadestActive)
    }

    /// "Send to Apple Watch (Again)": also undoes a deletion made on the watch, so the book is sent automatically
    /// again (e.g. when the watch is not reachable right now).
    private func sendToWatchExplicitly(_ entry: LibraryEntry) {
        library.clearRemovedOnWatch(hash: entry.documentHash)
        sendToWatch(entry)
    }

    private func sendToWatch(_ entry: LibraryEntry) {
        connectivity.send(book: entry, fileURL: library.fileURL(for: entry),
                          formatVersion: ProcessedBook.currentFormatVersion)
    }
}
