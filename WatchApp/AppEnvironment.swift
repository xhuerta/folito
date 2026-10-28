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
    let dictionaryCache: DictionaryCache
    let dictionary: DictionaryProviding
    private var connectivity: ConnectivityReceiver?

    init() {
        let positions = PositionStore()
        self.positions = positions
        self.library = BookLibrary(positions: positions)
        self.sync = SyncCoordinator()
        self.typography = TypographyModel()
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristReader/Dictionary/cache.json")
        let cache = DictionaryCache(fileURL: cacheURL)
        self.dictionaryCache = cache
        self.dictionary = DictionaryService.online(cache: cache)
    }

    func start() {
        guard connectivity == nil else { return }
        let sync = self.sync
        let typography = self.typography
        let receiver = ConnectivityReceiver(library: library,
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

    /// Settings > Reset: clears preferences, positions, pending sync and credentials. Books are kept.
    func resetAll() {
        ReaderSettings.resetPreferences()
        typography.reset()
        dictionaryCache.removeAll()
        AttributedBlockCache.shared.removeAll()
        positions.removeAll()
        sync.resetPending()
        CredentialsStore.clear()
        sync.configurationChanged()
        library.reloadProgress()
    }
}
