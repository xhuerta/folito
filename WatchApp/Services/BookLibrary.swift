import Foundation
import SwiftUI

/// Observable library index. Heavy work (decompress/decode) happens off the main actor.
@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    /// documentHash -> 0...1 read fraction.
    @Published private(set) var progress: [String: Double] = [:]

    /// Called after a book was removed (watch UI or iPhone request): used to drop its pending sync.
    var onBookDeleted: ((String) -> Void)?
    /// Called whenever the set of stored books changed (import / delete) so the phone can be told.
    var onLibraryChanged: (() -> Void)?

    let storage: BookStorage
    let positions: PositionStore

    init(storage: BookStorage = BookStorage(), positions: PositionStore) {
        self.storage = storage
        self.positions = positions
        entries = storage.loadIndex().sorted { $0.addedAt > $1.addedAt }
        reloadProgress()
    }

    func reloadProgress() {
        var map: [String: Double] = [:]
        for e in entries { map[e.documentHash] = positions.load(e.documentHash)?.percentage ?? 0 }
        progress = map
    }

    /// Imports a file received from the phone. `fileURL` must be a copy we own; it is removed afterwards.
    func importReceivedFile(at fileURL: URL) async {
        let storage = self.storage
        let result: LibraryEntry? = await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            return try? storage.importBook(from: fileURL)
        }.value
        guard let entry = result else { return }
        entries.removeAll { $0.documentHash == entry.documentHash }
        entries.insert(entry, at: 0)
        storage.saveIndex(entries)
        reloadProgress()
        onLibraryChanged?()
    }

    func loadBook(_ entry: LibraryEntry) async throws -> ProcessedBookBox {
        let storage = self.storage
        let hash = entry.documentHash
        return try await Task.detached(priority: .userInitiated) {
            ProcessedBookBox(book: try storage.load(documentHash: hash))
        }.value
    }

    func delete(documentHash: String) {
        entries.removeAll { $0.documentHash == documentHash }
        storage.delete(documentHash: documentHash)
        storage.saveIndex(entries)
        positions.remove(documentHash)
        progress.removeValue(forKey: documentHash)
        onBookDeleted?(documentHash)
        onLibraryChanged?()
    }

    func deleteAll() {
        let hashes = entries.map(\.documentHash)
        entries = []
        progress = [:]
        storage.deleteAll()
        hashes.forEach { onBookDeleted?($0) }
        onLibraryChanged?()
    }
}
