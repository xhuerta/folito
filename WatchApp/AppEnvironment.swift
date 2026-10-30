import Foundation
import SwiftUI
import ReaderCore

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
    private var connectivity: ConnectivityReceiver?

    init() {
        // UITesting.* return the normal services unless a Debug build is launched by the UI tests.
        let positions = PositionStore(defaults: UITesting.defaults)
        self.positions = positions
        self.library = BookLibrary(storage: UITesting.makeBookStorage(), positions: positions)
        self.sync = SyncCoordinator()
        self.typography = TypographyModel(store: TypographyStore(defaults: UITesting.defaults))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The online lookup's cache of earlier versions is no longer used.
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Folito/Dictionary"))
        let dictionaries = InstalledDictionaries(directory: UITesting.dictionaryDirectory
            ?? support.appendingPathComponent("Folito/Dictionaries"))
        self.dictionaries = dictionaries
        self.dictionary = OfflineDictionaryService(installed: dictionaries)
        self.dictionaryInfos = dictionaries.infos
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
        library.onBookDeleted = { sync.discard(document: $0) }
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
        sync.resetPending()
        CredentialsStore.clear()
        sync.configurationChanged()
        library.reloadProgress()
    }
}
