import Foundation
import SwiftUI
import UIKit

/// Observable library index. Heavy work (decompress/decode) happens off the main actor.
@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    /// documentHash -> 0...1 read fraction.
    @Published private(set) var progress: [String: Double] = [:]
    /// Decoded cover thumbnails, loaded on first use. Not published: it is filled while rows render, and
    /// every change that matters (`hasCover`) already changes `entries`.
    private var covers: [String: UIImage] = [:]

    /// Called after a book was removed (watch UI or iPhone request): used to drop its pending sync.
    var onBookDeleted: ((String) -> Void)?
    /// Called when the user deleted a book on the watch (not on an iPhone request), before `onLibraryChanged`:
    /// the iPhone stops sending it automatically.
    var onUserDeletedBook: ((String) -> Void)?
    /// Called whenever the set of stored books changed (import / delete) so the phone can be told.
    var onLibraryChanged: (() -> Void)?
    /// A newer position the sync service holds for a book (#132, `SyncedProgressStore`); the row shows it
    /// when it is further than the local one.
    var syncedFraction: ((String) -> Double?)? {
        didSet { reloadProgress() }
    }

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
        for e in entries {
            let local = positions.load(e.documentHash)?.percentage ?? 0
            map[e.documentHash] = max(local, syncedFraction?(e.documentHash) ?? 0)
        }
        progress = map
    }

    /// Imports a file received from the phone. `fileURL` must be a copy we own; it is removed afterwards.
    /// `cover` is the thumbnail the phone sent in the file metadata (nil: the book has none).
    func importReceivedFile(at fileURL: URL, cover: Data? = nil) async {
        let storage = self.storage
        let result: LibraryEntry? = await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard var entry = try? storage.importBook(from: fileURL) else { return nil }
            try? FileManager.default.removeItem(at: storage.coverURL(entry.documentHash))
            if let cover { entry.hasCover = storage.saveCover(cover, documentHash: entry.documentHash) }
            return entry
        }.value
        guard let entry = result else { return }
        covers.removeValue(forKey: entry.documentHash)
        entries.removeAll { $0.documentHash == entry.documentHash }
        entries.insert(entry, at: 0)
        storage.saveIndex(entries)
        reloadProgress()
        onLibraryChanged?()
    }

    /// A cover for a book already on the watch (`book_cover` message).
    func setCover(_ data: Data, documentHash: String) {
        guard let i = entries.firstIndex(where: { $0.documentHash == documentHash }),
              storage.saveCover(data, documentHash: documentHash) else { return }
        entries[i].hasCover = true
        covers.removeValue(forKey: documentHash)
        storage.saveIndex(entries)
    }

    /// The cover of a book, or nil when it has none (the row then shows a plain coloured tile).
    func cover(for entry: LibraryEntry) -> UIImage? {
        guard entry.hasCover == true else { return nil }
        if let image = covers[entry.documentHash] { return image }
        guard let image = UIImage(contentsOfFile: storage.coverURL(entry.documentHash).path) else { return nil }
        covers[entry.documentHash] = image
        return image
    }

    func loadBook(_ entry: LibraryEntry) async throws -> ProcessedBookBox {
        let storage = self.storage
        let hash = entry.documentHash
        return try await Task.detached(priority: .userInitiated) {
            ProcessedBookBox(book: try storage.load(documentHash: hash))
        }.value
    }

    /// `byUser`: deleted in the watch UI (the iPhone is told, so it does not send the book back).
    func delete(documentHash: String, byUser: Bool = false) {
        entries.removeAll { $0.documentHash == documentHash }
        storage.delete(documentHash: documentHash)
        storage.saveIndex(entries)
        positions.remove(documentHash)
        progress.removeValue(forKey: documentHash)
        covers.removeValue(forKey: documentHash)
        onBookDeleted?(documentHash)
        if byUser { onUserDeletedBook?(documentHash) }
        onLibraryChanged?()
    }

    func deleteAll() {
        let hashes = entries.map(\.documentHash)
        entries = []
        progress = [:]
        covers = [:]
        storage.deleteAll()
        hashes.forEach { onBookDeleted?($0) }
        onLibraryChanged?()
    }
}
