import Foundation
import ReaderCore

/// Where online book details come from. The app uses Open Library; UI tests use a mock (`UITesting`).
protocol OnlineMetadataProviding: Sendable {
    func lookup(_ query: OnlineLookupQuery) async throws -> [OnlineBookMatch]
    func description(for match: OnlineBookMatch) async throws -> String?
    func cover(for match: OnlineBookMatch) async throws -> Data?
}

/// Open Library through one shared client, so the etiquette (one request at a time, spaced, backoff) holds
/// across the background lookup, the bulk lookup and the detail screen.
struct OpenLibraryProvider: OnlineMetadataProviding {
    static let sharedClient = OpenLibraryClient()
    private let client = OpenLibraryProvider.sharedClient

    func lookup(_ query: OnlineLookupQuery) async throws -> [OnlineBookMatch] { try await client.lookup(query) }
    func description(for match: OnlineBookMatch) async throws -> String? { try await client.description(for: match) }
    func cover(for match: OnlineBookMatch) async throws -> Data? { try await client.cover(for: match) }
}

/// *Settings › Book Details* and the background lookup (docs/ONLINE_METADATA.md). Nothing goes online unless the
/// user turns *Find Missing Details Online* on (off by default), taps *Look Up Missing Details Now*, or taps
/// *Find Details Online* on a book.
@MainActor
final class OnlineMetadataModel: ObservableObject {
    static let autoLookupKey = "onlineMetadata.autoLookup"

    /// *Find Missing Details Online*: books imported from then on with a missing cover or description are looked up
    /// once, in the background. Off by default.
    @Published var autoLookup: Bool {
        didSet { defaults.set(autoLookup, forKey: Self.autoLookupKey) }
    }

    enum BulkState: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// `updated` books gained details out of `total` looked up; `cancelled` when the user stopped it.
        case finished(updated: Int, total: Int, cancelled: Bool)
        /// Stopped by an error (offline, Open Library unavailable).
        case failed(UserFacingError)
    }

    @Published private(set) var bulk: BulkState = .idle

    let provider: OnlineMetadataProviding
    private let defaults: UserDefaults
    private var backgroundQueue: [String] = []
    private var backgroundRunning = false
    private var bulkTask: Task<Void, Never>?

    init(provider: OnlineMetadataProviding = OpenLibraryProvider(), defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        autoLookup = defaults.bool(forKey: Self.autoLookupKey)
    }

    var isBulkRunning: Bool {
        if case .running = bulk { return true }
        return false
    }

    // MARK: Background lookup (opt-in)

    /// After an import: looks the book up once if the setting is on and it lacks a cover or a description.
    /// Quiet: errors and uncertain matches change nothing.
    func bookImported(_ entry: LibraryEntry, library: LibraryStore) {
        guard autoLookup, entry.needsOnlineLookup, entry.onlineLookupAt == nil else { return }
        backgroundQueue.append(entry.documentHash)
        guard !backgroundRunning else { return }
        backgroundRunning = true
        Task {
            while !backgroundQueue.isEmpty {
                let hash = backgroundQueue.removeFirst()
                guard autoLookup, let entry = library.entries.first(where: { $0.documentHash == hash }),
                      entry.needsOnlineLookup else { continue }
                _ = try? await fillAutomatically(entry, library: library)
                library.markLookedUpOnline(hash: hash)
            }
            backgroundRunning = false
        }
    }

    // MARK: Bulk lookup (explicit)

    /// The books *Look Up Missing Details Now* would look up.
    func bulkCandidates(in library: LibraryStore) -> [LibraryEntry] {
        library.entries.filter { $0.needsOnlineLookup && $0.online == nil }
    }

    func startBulk(library: LibraryStore) {
        guard !isBulkRunning else { return }
        let hashes = bulkCandidates(in: library).map(\.documentHash)
        bulk = .running(done: 0, total: hashes.count)
        bulkTask = Task {
            var updated = 0
            for (index, hash) in hashes.enumerated() {
                if Task.isCancelled { break }
                if let entry = library.entries.first(where: { $0.documentHash == hash }), entry.needsOnlineLookup {
                    do {
                        if try await fillAutomatically(entry, library: library) { updated += 1 }
                        library.markLookedUpOnline(hash: hash)
                    } catch is CancellationError {
                        break
                    } catch {
                        bulk = .failed(.onlineLookupFailed(error))
                        Announcer.announce(UserFacingError.onlineLookupFailed(error).message)
                        return
                    }
                }
                bulk = .running(done: index + 1, total: hashes.count)
            }
            let cancelled = Task.isCancelled
            bulk = .finished(updated: updated, total: hashes.count, cancelled: cancelled)
            Announcer.announce(Self.summary(updated: updated, total: hashes.count, cancelled: cancelled))
        }
    }

    func cancelBulk() {
        bulkTask?.cancel()
    }

    static func summary(updated: Int, total: Int, cancelled: Bool) -> String {
        if total == 0 {
            return String(localized: "Every book already has a cover and a description.",
                          comment: "Settings › Book Details: result of the lookup when nothing is missing")
        }
        let found = String(localized: "Added details to \(updated) of \(total) books.",
                           comment: "Settings › Book Details: result of the lookup; placeholders: books updated, books looked up")
        return cancelled
            ? found + " " + String(localized: "Stopped.", comment: "Settings › Book Details: the lookup was cancelled")
            : found
    }

    // MARK: Shared

    /// Looks a book up and applies the best match only when it is unambiguous (`MatchScoring.isConfident`):
    /// cover, description and publication details, each only where the EPUB has none. Returns whether anything
    /// was added. Throws network errors (the caller decides whether to show them).
    @discardableResult
    func fillAutomatically(_ entry: LibraryEntry, library: LibraryStore) async throws -> Bool {
        let query = entry.lookupQuery
        let matches = try await provider.lookup(query)
        guard MatchScoring.isConfident(matches, for: query), var match = matches.first else { return false }
        var wanted = OnlineMetadataMerge.missing(details: entry.details, hasEPUBCover: entry.hasEPUBCover)
        if wanted.contains(.description), match.description == nil {
            match.description = try await provider.description(for: match)
        }
        wanted = OnlineMetadataMerge.applicable(match, details: entry.details, hasEPUBCover: entry.hasEPUBCover,
                                                online: entry.online).intersection(wanted)
        guard !wanted.isEmpty else { return false }
        var cover: Data?
        if wanted.contains(.cover) { cover = try await provider.cover(for: match) }
        let applied = await library.applyOnline(match, selection: wanted, coverData: cover, to: entry.documentHash)
        return applied.contains(.cover) || applied.contains(.description)
    }
}
