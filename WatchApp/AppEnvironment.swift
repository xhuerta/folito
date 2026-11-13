import Foundation
import SwiftUI
import ReaderCore
import WatchKit

/// Composition root: owns the long-lived services.
@MainActor
final class AppEnvironment: ObservableObject {
    let positions: PositionStore
    let library: BookLibrary
    let sync: SyncCoordinator
    let typography: TypographyModel
    /// Offline dictionaries sent by the iPhone (see docs/DICTIONARIES.md).
    let dictionaries: InstalledDictionaries
    let dictionary: DictionaryProviding
    /// What Settings shows; refreshed whenever a dictionary is installed or removed.
    @Published private(set) var dictionaryInfos: [CompactDictionaryInfo] = []
    /// Writes what the complications / Smart Stack widget show (see WatchWidgets/).
    let complications: ComplicationPublisher
    /// Shows a newer position from the sync service in the complications and the Library (#132).
    let syncedProgress: SyncedProgressRefresher
    /// Latest deep link from a complication (`widgetURL`), consumed by LibraryView.
    @Published var deepLink: DeepLinkRequest?

    struct DeepLinkRequest: Equatable {
        let token = UUID()
        let link: FolitoDeepLink
    }
    private var connectivity: ConnectivityReceiver?

    init() {
        // UITesting.* return the normal services unless a Debug build is launched by the UI tests.
        let positions = PositionStore(defaults: UITesting.defaults)
        self.positions = positions
        let library = BookLibrary(storage: UITesting.makeBookStorage(), positions: positions)
        self.library = library
        let sync = SyncCoordinator()
        self.sync = sync
        self.typography = TypographyModel(store: TypographyStore(defaults: UITesting.defaults))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The online lookup's cache of earlier versions is no longer used.
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Folito/Dictionary"))
        let dictionaries = InstalledDictionaries(directory: UITesting.dictionaryDirectory
            ?? support.appendingPathComponent("Folito/Dictionaries"))
        self.dictionaries = dictionaries
        self.dictionary = OfflineDictionaryService(installed: dictionaries)
        self.dictionaryInfos = dictionaries.infos
        // UI tests must not touch the real complication snapshot.
        let complications = ComplicationPublisher(
            store: UITesting.isActive ? ReadingSnapshotStore(defaults: nil) : .shared,
            localStore: ReadingSnapshotStore(defaults: UITesting.isActive ? nil : .standard,
                                             key: "complication.localSnapshot"))
        self.complications = complications
        library.syncedFraction = { sync.remoteMemory.synced(for: $0)?.percentage }
        let refresher = SyncedProgressRefresher(
            sync: sync, complications: complications, positions: positions,
            resolveCFI: { bookID, raw in
                // Only for a Readest row with a CFI: the book is decoded to place it.
                guard let entry = library.entries.first(where: { $0.documentHash == bookID }),
                      let box = try? await library.loadBook(entry) else { return raw }
                return raw.resolvingCFI(in: box.book)
            })
        refresher.onChange = { library.reloadProgress() }
        self.syncedProgress = refresher
    }

    /// A complication was tapped (`folito://book/<id>` or `folito://library`).
    func handle(url: URL) {
        guard let link = FolitoDeepLink(url: url) else { return }
        deepLink = DeepLinkRequest(link: link)
    }

    /// Launch and foreground: refresh the synced position of the complications' book, then ask watchOS for
    /// the next background refresh. Nothing is asked while sync is off (UI tests: never).
    func refreshSyncedProgress() {
        guard !UITesting.isActive else { return }
        Task {
            await syncedProgress.refresh()
            scheduleBackgroundRefresh()
        }
    }

    /// The scheduled background refresh (`.backgroundTask(.appRefresh(SyncedProgressRefresher.taskID))`).
    func backgroundRefresh() async {
        guard !UITesting.isActive else { return }
        await syncedProgress.refresh(force: true)
        scheduleBackgroundRefresh()
    }

    /// One pending background refresh at a time, only while sync is on and a book is on the complications.
    func scheduleBackgroundRefresh() {
        guard !UITesting.isActive, sync.isConfigured, complications.current != nil else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: SyncedProgressRefresher.backgroundInterval),
            userInfo: SyncedProgressRefresher.taskID as NSString) { _ in }
    }

    /// Re-reads the installed dictionaries (after the iPhone installed or removed one).
    func dictionariesChanged() {
        dictionaryInfos = dictionaries.infos
    }

    func start() {
        // UI tests run on a seeded, isolated library: nothing may arrive from the iPhone meanwhile.
        guard connectivity == nil, !UITesting.isActive else { return }
        let sync = self.sync
        let typography = self.typography
        let receiver = ConnectivityReceiver(library: library,
                                            dictionaries: dictionaries,
                                            onDictionariesChanged: { [weak self] in self?.dictionariesChanged() },
                                            typography: { typography.value },
                                            onTypography: { typography.applyRemote($0) },
                                            onSettingsChanged: { sync.configurationChanged() })
        typography.onLocalChange = { [weak receiver] _ in receiver?.publishLibrary() }
        let complications = self.complications
        library.onBookDeleted = { sync.discard(document: $0); complications.bookRemoved($0) }
        library.onUserDeletedBook = { [weak receiver] in receiver?.reportUserRemoval(of: $0) }
        library.onLibraryChanged = { [weak receiver] in receiver?.publishLibrary() }
        receiver.start()
        connectivity = receiver
    }

    /// Settings > Remove credentials: turns sync off on the watch (keychain + pending queue). Local
    /// reading positions and books are untouched.
    func removeSyncCredentials() {
        CredentialsStore.clear()
        sync.configurationChanged()
    }

    /// Settings > Reset: clears preferences, positions, pending sync and credentials. Books and
    /// dictionaries are kept.
    func resetAll() {
        ReaderSettings.resetPreferences()
        typography.reset()
        AttributedBlockCache.shared.removeAll()
        positions.removeAll()
        complications.clear()
        sync.remoteMemory.removeAll()
        sync.resetPending()
        CredentialsStore.clear()
        sync.configurationChanged()
        library.reloadProgress()
    }
}
