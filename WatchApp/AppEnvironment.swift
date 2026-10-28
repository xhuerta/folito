import Foundation
import SwiftUI

/// Composition root: owns the long-lived services.
@MainActor
final class AppEnvironment: ObservableObject {
    let positions: PositionStore
    let library: BookLibrary
    let sync: SyncCoordinator
    private var connectivity: ConnectivityReceiver?

    init() {
        let positions = PositionStore()
        self.positions = positions
        self.library = BookLibrary(positions: positions)
        self.sync = SyncCoordinator()
    }

    func start() {
        guard connectivity == nil else { return }
        let sync = self.sync
        let receiver = ConnectivityReceiver(library: library) { sync.configurationChanged() }
        library.onBookDeleted = { sync.discard(document: $0) }
        library.onLibraryChanged = { [weak receiver] in receiver?.publishLibrary() }
        receiver.start()
        connectivity = receiver
    }

    /// Settings > Reset: clears preferences, positions, pending sync and credentials. Books are kept.
    func resetAll() {
        ReaderSettings.resetPreferences()
        positions.removeAll()
        sync.resetPending()
        CredentialsStore.clear()
        sync.configurationChanged()
        library.reloadProgress()
    }
}
