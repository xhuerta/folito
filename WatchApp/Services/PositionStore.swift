import Foundation
import ReaderCore

struct StoredPosition: Codable, Equatable {
    var position: BookPosition
    /// 0...1 of the whole book, kept for the library list.
    var percentage: Double
}

/// Per-book local reading position (keyed by documentHash), persisted in UserDefaults.
final class PositionStore: @unchecked Sendable {
    private static let prefix = "position."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(_ documentHash: String) -> StoredPosition? {
        guard let data = defaults.data(forKey: Self.prefix + documentHash) else { return nil }
        return try? JSONDecoder().decode(StoredPosition.self, from: data)
    }

    func save(_ value: StoredPosition, for documentHash: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.prefix + documentHash)
    }

    func remove(_ documentHash: String) {
        defaults.removeObject(forKey: Self.prefix + documentHash)
    }

    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
