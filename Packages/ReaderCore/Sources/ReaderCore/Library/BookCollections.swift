import Foundation

// User collections of the iPhone Library (#164): "To Read", "Book Club", "Sci-fi"... A book can be in several
// collections; deleting a collection never deletes a book. Pure rules, so they are unit-tested on Linux; the iPhone
// keeps one `BookCollections` next to its library index (`LibraryStore`, collections.json).

/// One collection: a name the user chose and the books in it, by their document hash, in the order they were added.
public struct BookCollection: Codable, Sendable, Equatable, Identifiable {
    /// Stable across renames and reorders (a UUID string for collections made on the iPhone).
    public var id: String
    public var name: String
    /// Document hashes, each once, in the order they were added.
    public var books: [String]

    public init(id: String = UUID().uuidString, name: String, books: [String] = []) {
        self.id = id
        self.name = name
        self.books = Self.unique(books)
    }

    public func contains(_ hash: String) -> Bool { books.contains(hash) }

    private enum CodingKeys: String, CodingKey { case id, name, books }

    /// Tolerant: missing `books` is an empty collection; repeated hashes are kept once.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        books = Self.unique((try? c.decode([String].self, forKey: .books)) ?? [])
    }

    static func unique(_ hashes: [String]) -> [String] {
        var seen = Set<String>()
        return hashes.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Every collection of the Library, in the order the user arranged them (the order of *By Collection*).
public struct BookCollections: Codable, Sendable, Equatable {
    /// The format written by `encoded()`. A file of another version is read as far as it can be.
    public static let currentVersion = 1

    public private(set) var collections: [BookCollection]

    public init(_ collections: [BookCollection] = []) {
        self.collections = []
        for collection in collections where !collection.id.isEmpty
            && !self.collections.contains(where: { $0.id == collection.id }) {
            self.collections.append(collection)
        }
    }

    public var isEmpty: Bool { collections.isEmpty }

    /// Why a name cannot be used.
    public enum NameProblem: Error, Equatable, Sendable {
        /// Blank once spaces are trimmed.
        case empty
        /// Another collection already has this name (case, accents and width ignored); its name as written.
        case duplicate(String)
    }

    public func collection(id: String) -> BookCollection? { collections.first { $0.id == id } }

    /// The collections that hold `hash`, in the user's order.
    public func collections(containing hash: String) -> [BookCollection] {
        collections.filter { $0.contains(hash) }
    }

    /// The ids of the collections that hold `hash`, in the user's order.
    public func ids(containing hash: String) -> [String] { collections(containing: hash).map(\.id) }

    /// The name trimmed, or the problem with it. `excluding` is the collection being renamed (it may keep its name
    /// or change only its case).
    public func validate(_ name: String, excluding id: String? = nil) -> Result<String, NameProblem> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let folded = LibrarySearch.normalize(trimmed)
        if let other = collections.first(where: { $0.id != id && LibrarySearch.normalize($0.name) == folded }) {
            return .failure(.duplicate(other.name))
        }
        return .success(trimmed)
    }

    /// Adds a collection at the end of the list, with `books` in it.
    @discardableResult
    public mutating func create(named name: String, id: String = UUID().uuidString,
                                books: [String] = []) -> Result<BookCollection, NameProblem> {
        switch validate(name) {
        case .failure(let problem): return .failure(problem)
        case .success(let trimmed):
            var newID = id
            while newID.isEmpty || collections.contains(where: { $0.id == newID }) { newID = UUID().uuidString }
            let collection = BookCollection(id: newID, name: trimmed, books: books)
            collections.append(collection)
            return .success(collection)
        }
    }

    /// Renames a collection; its books and place in the list do not change. Nil when renamed (or unknown).
    @discardableResult
    public mutating func rename(_ id: String, to name: String) -> NameProblem? {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return nil }
        switch validate(name, excluding: id) {
        case .failure(let problem): return problem
        case .success(let trimmed):
            collections[index].name = trimmed
            return nil
        }
    }

    /// Removes a collection. Its books stay in the Library (and in the other collections they are in).
    @discardableResult
    public mutating func delete(_ id: String) -> BookCollection? {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return nil }
        return collections.remove(at: index)
    }

    /// Moves the collections at `offsets` to before the collection at `destination` (as `List.onMove` reports a
    /// drag: `destination` counts the moved collections too). Offsets out of range are ignored.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filter { collections.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.sorted().map { collections[$0] }
        var rest = collections.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let target = min(max(0, destination), collections.count)
        let insertAt = target - valid.filter { $0 < target }.count
        rest.insert(contentsOf: moving, at: min(max(0, insertAt), rest.count))
        collections = rest
    }

    /// Moves one collection up (negative `by`) or down the list, as far as it can go. Returns whether it moved
    /// (VoiceOver's *Move Up* / *Move Down* actions).
    @discardableResult
    public mutating func move(_ id: String, by delta: Int) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(0, index + delta), collections.count - 1)
        guard target != index else { return false }
        let collection = collections.remove(at: index)
        collections.insert(collection, at: target)
        return true
    }

    /// Adds the books to a collection, after the ones already in it; a book already there keeps its place.
    /// Returns how many were added.
    @discardableResult
    public mutating func add(_ hashes: [String], to id: String) -> Int {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return 0 }
        let before = collections[index].books.count
        collections[index].books = BookCollection.unique(collections[index].books + hashes)
        return collections[index].books.count - before
    }

    /// Takes the books out of a collection (they stay in the Library). Returns how many were removed.
    @discardableResult
    public mutating func remove(_ hashes: [String], from id: String) -> Int {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return 0 }
        let drop = Set(hashes)
        let before = collections[index].books.count
        collections[index].books.removeAll { drop.contains($0) }
        return before - collections[index].books.count
    }

    /// Whether every one of `hashes` is in the collection (false for no hashes).
    public func containsAll(_ hashes: [String], in id: String) -> Bool {
        guard !hashes.isEmpty, let collection = collection(id: id) else { return false }
        return hashes.allSatisfy(collection.contains)
    }

    /// The choice in a collection picker: adds the books when some are not in the collection yet, else takes them
    /// all out. Returns true when they were added.
    @discardableResult
    public mutating func toggle(_ hashes: [String], in id: String) -> Bool {
        if containsAll(hashes, in: id) {
            remove(hashes, from: id)
            return false
        }
        add(hashes, to: id)
        return true
    }

    /// A book's id changed (a download re-linked to its Readest row): its memberships follow it.
    public mutating func replaceBook(_ old: String, with new: String) {
        guard old != new else { return }
        for i in collections.indices where collections[i].contains(old) {
            collections[i].books = BookCollection.unique(collections[i].books.map { $0 == old ? new : $0 })
        }
    }

    // MARK: Persistence

    private enum CodingKeys: String, CodingKey { case version, collections }

    /// Tolerant: a missing `collections` is none; a collection that cannot be read (no id) is skipped, the others
    /// are kept; a bare list of collections is read too.
    public init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([LossyCollection].self) {
            self.init(list.compactMap(\.value))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? c.decode([LossyCollection].self, forKey: .collections)) ?? []
        self.init(list.compactMap(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(collections, forKey: .collections)
    }

    /// The saved form (JSON).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a saved file; nil data (no file yet) or data that cannot be read at all is no collections.
    public static func decode(_ data: Data?) -> BookCollections {
        guard let data, let decoded = try? JSONDecoder().decode(BookCollections.self, from: data) else {
            return BookCollections()
        }
        return decoded
    }

    private struct LossyCollection: Decodable {
        let value: BookCollection?
        init(from decoder: Decoder) throws {
            value = try? BookCollection(from: decoder)
        }
    }
}
