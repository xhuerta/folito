import Foundation
import UIKit
import ReaderCore

/// The Catalogs list (presets and the catalogs the user added) and downloads from catalogs (docs/OPDS.md).
///
/// Nothing here contacts a server on its own: a catalog is read only when the user opens it (or adds it, to check
/// the address), and a book is downloaded only when the user taps Download.
@MainActor
final class CatalogStore: ObservableObject {
    /// Catalogs the user added, in the order they were added.
    @Published private(set) var custom: [OPDSCatalog] = []
    /// Entry ids being downloaded right now.
    @Published private(set) var downloading: Set<String> = []
    /// Entry ids downloaded into the library during this session (the detail screen shows "In Your Library").
    @Published private(set) var downloaded: Set<String> = []
    /// A failed download, shown by the screen that started it.
    @Published var alert: UserFacingError?

    let client: OPDSClient
    private let defaults: UserDefaults
    static let customKey = "catalogs.custom"

    init(client: OPDSClient = OPDSClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode([OPDSCatalog].self, from: data) {
            custom = saved
        }
    }

    var all: [OPDSCatalog] { OPDSCatalog.presets + custom }

    // MARK: Custom catalogs

    /// Checks the address by reading the catalog once, then adds it (named after the feed when `name` is empty).
    /// Returns the problem to show under the address field, or nil when the catalog was added.
    func add(address: String, name: String) async -> String? {
        guard let url = OPDSCatalogAddress.normalize(address) else {
            return String(localized: "Enter a web address that starts with https://, for example https://example.com/opds.",
                          comment: "Add Catalog: the address field does not contain a usable web address")
        }
        if let existing = all.first(where: { $0.url == url }) {
            return String(localized: "“\(existing.title)” already has this address.",
                          comment: "Add Catalog: the address is already in the list; the placeholder is the catalog's name")
        }
        do {
            let feed = try await client.feed(at: url)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            custom.append(OPDSCatalog(title: trimmed.isEmpty ? feed.title : trimmed, url: url))
            save()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return UserFacingError.catalogFailed(error).message
        }
    }

    func remove(_ catalog: OPDSCatalog) {
        custom.removeAll { $0.id == catalog.id }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        custom.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.customKey) }
    }

    // MARK: Downloads

    /// Downloads the entry's EPUB and imports it through the normal pipeline; the library then sends it to the
    /// watch as usual.
    func download(_ entry: OPDSEntry, into library: LibraryStore) async {
        guard let link = entry.epubLink, !downloading.contains(entry.id) else { return }
        downloading.insert(entry.id)
        defer { downloading.remove(entry.id) }
        let fileName = Self.fileName(for: entry)
        do {
            let data = try await client.download(link)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
            try data.write(to: temp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temp) }
            if await library.importDownloaded(from: temp, fileName: fileName) != nil {
                downloaded.insert(entry.id)
                Announcer.announce(String(localized: "Downloaded “\(entry.title)”.",
                                          comment: "VoiceOver announcement after a book was downloaded (from Readest or a catalog); the placeholder is the title"))
            } else if let error = library.importError {
                // The Library's own alert is behind the Catalogs sheet: show the import error here instead.
                library.importError = nil
                alert = error
            }
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingError.catalogDownloadFailed(title: entry.title, error: error)
        }
    }

    // MARK: Covers

    private let images = NSCache<NSURL, UIImage>()

    /// A cover or thumbnail from the catalog, loaded through the catalog client (ephemeral session) and kept in
    /// memory while the app runs. Nil when the catalog has none or it is not an image.
    func image(at url: URL) async -> UIImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let data = try? await client.image(at: url), let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    /// "Pride and Prejudice.epub": the title without characters a file name cannot hold.
    nonisolated static func fileName(for entry: OPDSEntry) -> String {
        let cleaned = entry.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Book" : String(cleaned.prefix(120))) + ".epub"
    }
}

/// One catalog page being browsed, with its following pages appended as the user asks for them.
@MainActor
final class CatalogFeedModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(UserFacingError)
    }

    let url: URL
    private let client: OPDSClient
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var title: String?
    @Published private(set) var entries: [OPDSEntry] = []
    @Published private(set) var nextURL: URL?
    @Published private(set) var isLoadingMore = false
    /// A failed "Load More"; the entries already shown stay.
    @Published var moreError: UserFacingError?
    private var hasLoaded = false

    init(url: URL, client: OPDSClient) {
        self.url = url
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        if entries.isEmpty { phase = .loading }
        do {
            let feed = try await client.feed(at: url)
            hasLoaded = true
            title = feed.title
            entries = OPDSPages.append(feed.entries, to: [])
            nextURL = feed.nextURL
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            if entries.isEmpty { phase = .failed(.catalogFailed(error)) } else { moreError = .catalogFailed(error) }
        }
    }

    func loadMore() async {
        guard let next = nextURL, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.feed(at: next)
            entries = OPDSPages.append(page.entries, to: entries)
            // A page pointing to itself (or back) would loop.
            nextURL = page.nextURL == next || page.nextURL == url ? nil : page.nextURL
        } catch is CancellationError {
            return
        } catch {
            moreError = .catalogFailed(error)
        }
    }
}
