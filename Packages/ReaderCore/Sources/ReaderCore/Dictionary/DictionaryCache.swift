import Foundation

/// Bounded on-disk LRU cache of dictionary entries, so words looked up once also work offline.
/// One JSON file; bounded by entry count and total encoded bytes. Thread-safe. A corrupt or unreadable
/// file is treated as empty. Recency changes from reads are kept in memory and written with the next
/// `put` (or `flush()`), so reading never costs a disk write.
public final class DictionaryCache: @unchecked Sendable {
    public static let defaultMaxEntries = 200
    public static let defaultMaxBytes = 600_000

    private struct Item: Codable {
        var key: String
        var entry: DictionaryEntry
        var tick: Int
        var size: Int
    }
    private struct Store: Codable {
        var version = 1
        var tick = 0
        var items: [Item] = []
    }

    private let fileURL: URL?
    private let maxEntries: Int
    private let maxBytes: Int
    private let lock = NSLock()
    private var store = Store()
    private var dirty = false

    /// `fileURL == nil` gives a memory-only cache.
    public init(fileURL: URL?, maxEntries: Int = DictionaryCache.defaultMaxEntries,
                maxBytes: Int = DictionaryCache.defaultMaxBytes) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1_000, maxBytes)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Store.self, from: data), loaded.version == 1 {
            store = loaded
        }
    }

    public static func key(word: String, language: String) -> String {
        language.lowercased() + "|" + word.lowercased()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return store.items.count }
    public var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return store.items.reduce(0) { $0 + $1.size } }

    public func get(_ key: String) -> DictionaryEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let i = store.items.firstIndex(where: { $0.key == key }) else { return nil }
        store.tick += 1
        store.items[i].tick = store.tick
        dirty = true
        return store.items[i].entry
    }

    public func put(_ entry: DictionaryEntry, for key: String) {
        lock.lock(); defer { lock.unlock() }
        let size = (try? JSONEncoder().encode(entry).count) ?? 0
        guard size > 0, size <= maxBytes else { return }
        store.tick += 1
        let item = Item(key: key, entry: entry, tick: store.tick, size: size)
        if let i = store.items.firstIndex(where: { $0.key == key }) { store.items[i] = item }
        else { store.items.append(item) }
        evict()
        persist()
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        store = Store()
        dirty = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Writes pending recency changes.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        if dirty { persist() }
    }

    private func evict() {
        var total = store.items.reduce(0) { $0 + $1.size }
        while store.items.count > maxEntries || total > maxBytes {
            guard let oldest = store.items.indices.min(by: { store.items[$0].tick < store.items[$1].tick }) else { break }
            total -= store.items[oldest].size
            store.items.remove(at: oldest)
        }
    }

    private func persist() {
        dirty = false
        guard let fileURL, let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
