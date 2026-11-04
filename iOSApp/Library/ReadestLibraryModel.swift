import Foundation
import Network
import Observation
import UIKit
import ReaderCore

/// What the Library needs from Readest Cloud. The live implementation is `LiveReadestLibraryService`; UI tests use
/// `MockReadestLibraryService` (Debug builds only, `-UITestingMockReadest`).
protocol ReadestLibraryService: Sendable {
    func fetchBooks() async throws -> [ReadestCloudBook]
    /// Downloads the book's EPUB to a temporary file and returns its URL.
    func downloadBook(hash: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// The book's `cover.png`, or nil when it has none.
    func cover(hash: String) async throws -> Data?
    func upload(epubAt url: URL, book: ReadestUploadBook, existing: ReadestCloudBook?) async throws -> ReadestCloudBook
    func delete(_ book: ReadestCloudBook) async throws
    func storageUsage() async throws -> ReadestStorageUsage
}

/// Readest Cloud through `ReadestLibraryClient`, with the iPhone's own library session (see
/// `SyncSettings.libraryCredentialStore`; the watch keeps the sync session).
struct LiveReadestLibraryService: ReadestLibraryService {
    let client: ReadestLibraryClient

    init(store: SyncCredentialStore, session: URLSession = .shared) {
        let auth = ReadestAuth(session: session, store: store)
        client = ReadestLibraryClient(session: session, auth: auth)
    }

    func fetchBooks() async throws -> [ReadestCloudBook] { try await client.fetchBooks() }

    func downloadBook(hash: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = try await client.bookDownloadURL(hash: hash) else { throw ReadestError.notFound }
        let delegate = DownloadProgress(onProgress: progress)
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw status == 404 ? ReadestError.notFound : ReadestError.server(status: status, message: nil)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(hash)-\(UUID().uuidString).epub")
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    func cover(hash: String) async throws -> Data? {
        guard let url = try await client.coverDownloadURL(hash: hash) else { return nil }
        do { return try await client.get(url) } catch ReadestError.notFound { return nil }
    }

    func upload(epubAt url: URL, book: ReadestUploadBook, existing: ReadestCloudBook?) async throws -> ReadestCloudBook {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try await client.uploadBook(data, book: book, existing: existing)
    }

    func delete(_ book: ReadestCloudBook) async throws { try await client.deleteBook(book) }
    func storageUsage() async throws -> ReadestStorageUsage { try await client.storageUsage() }
}

/// Reports a download task's progress (task-specific delegate of `URLSession.download(for:delegate:)`).
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = onProgress
        observation = task.progress.observe(\.fractionCompleted) { p, _ in report(p.fractionCompleted) }
    }
}

/// The Readest side of the unified Library: the account's book rows (cached for offline use), covers,
/// downloads, uploads, deletions and storage usage. Nil service = Readest not connected on this iPhone.
@MainActor
@Observable
final class ReadestLibraryModel {
    static let autoUploadKey = "readest.autoUploadImported"

    private(set) var cloudBooks: [ReadestCloudBook] = []
    private(set) var covers: [String: UIImage] = [:]
    /// hash -> download fraction (0...1).
    private(set) var downloads: [String: Double] = [:]
    private(set) var uploading: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isOffline = false
    private(set) var usage: ReadestStorageUsage?
    /// The last refresh failed (shown under the list; the cached rows stay).
    private(set) var refreshError: String?
    /// An action failed (download, upload, deletion): presented as an alert.
    var alert: UserFacingError?
    /// Readest is the active sync service but this iPhone has no library session (signed in before the library
    /// existed): the Library asks to sign in again.
    private(set) var needsSignIn = false
    /// "Upload Imported Books Automatically" (off by default).
    var autoUpload: Bool {
        didSet { defaults.set(autoUpload, forKey: Self.autoUploadKey) }
    }

    private var service: ReadestLibraryService?
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let coverDirectory: URL
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastRefresh: Date?
    private let isFixed: Bool

    var isAvailable: Bool { service != nil }

    /// `fixedService` (UI tests) ignores later `configure` calls.
    init(defaults: UserDefaults = .standard, rootDirectory: URL? = nil, fixedService: ReadestLibraryService? = nil,
         forceOffline: Bool = false, monitorNetwork: Bool = true) {
        self.defaults = defaults
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folito", isDirectory: true)
        cacheURL = root.appendingPathComponent("readest-library.json")
        coverDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rootDirectory == nil ? "ReadestCovers" : "ReadestCovers-\(root.lastPathComponent)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        isFixed = fixedService != nil
        autoUpload = defaults.bool(forKey: Self.autoUploadKey)
        service = fixedService
        isOffline = forceOffline
        if fixedService == nil { loadCache() }
        if monitorNetwork && !forceOffline { startMonitor() }
    }

    /// Called when the sync settings change: a library session store (Readest signed in on this iPhone) or nil.
    func configure(store: SyncCredentialStore?, readestActive: Bool) {
        guard !isFixed else { return }
        needsSignIn = readestActive && store == nil
        if let store {
            service = LiveReadestLibraryService(store: store)
            lastRefresh = nil
        } else {
            service = nil
            cloudBooks = []
            covers = [:]
            usage = nil
            refreshError = nil
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: coverDirectory)
            try? FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        }
    }

    func cloudBook(hash: String) -> ReadestCloudBook? {
        cloudBooks.first { $0.hash == hash && $0.isAvailable }
    }

    // MARK: Refresh

    /// Refreshes on appear when the list is older than five minutes.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300 { return }
        await refresh()
    }

    /// Pull-to-refresh: the account's rows, then the missing covers and the storage usage.
    func refresh() async {
        guard let service, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            cloudBooks = try await service.fetchBooks()
            refreshError = nil
            lastRefresh = Date()
            saveCache()
        } catch {
            refreshError = UserFacingError.readestLibraryMessage(for: error)
            return
        }
        await loadCovers()
        await refreshUsage()
    }

    func refreshUsage() async {
        guard let service else { return }
        if let u = try? await service.storageUsage() { usage = u }
    }

    private func loadCovers() async {
        guard let service else { return }
        for book in cloudBooks where book.isAvailable && covers[book.hash] == nil {
            let file = coverDirectory.appendingPathComponent("\(book.hash).png")
            if let image = UIImage(contentsOfFile: file.path) { covers[book.hash] = image; continue }
            guard let data = try? await service.cover(hash: book.hash), let image = UIImage(data: data) else { continue }
            try? data.write(to: file, options: .atomic)
            covers[book.hash] = image
        }
    }

    // MARK: Actions

    /// Downloads a cloud-only book and imports it through the normal pipeline (same file, same hash, so its
    /// reading position matches exactly); the library then sends it to the watch as usual.
    func download(_ book: ReadestCloudBook, into library: LibraryStore) async {
        guard let service, downloads[book.hash] == nil else { return }
        guard !isOffline else { alert = .readestOffline(); return }
        downloads[book.hash] = 0
        defer { downloads[book.hash] = nil }
        do {
            let file = try await service.downloadBook(hash: book.hash) { fraction in
                Task { @MainActor [weak self] in
                    if self?.downloads[book.hash] != nil { self?.downloads[book.hash] = min(fraction, 0.99) }
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let name = book.title.isEmpty ? "\(book.hash).epub" : "\(book.title).epub"
            if await library.importDownloaded(from: file, fileName: name) != nil {
                Announcer.announce(String(localized: "Downloaded “\(book.title)”.",
                                          comment: "VoiceOver announcement after a book was downloaded from Readest; the placeholder is the title"))
            }
        } catch {
            alert = .readestFailed(.download, title: book.title, error: error)
        }
    }

    /// Uploads a local book's original EPUB to Readest (explicit action, or the opt-in automatic upload).
    func upload(_ entry: LibraryEntry, from library: LibraryStore) async {
        guard let service, !uploading.contains(entry.documentHash) else { return }
        guard let file = library.originalFileURL(for: entry) else { alert = .readestNoOriginal(title: entry.title); return }
        guard !isOffline else { alert = .readestOffline(); return }
        uploading.insert(entry.documentHash)
        defer { uploading.remove(entry.documentHash) }
        let existing = cloudBooks.first { $0.hash == entry.documentHash }
        let book = ReadestUploadBook(hash: entry.documentHash, metaHash: entry.metaHash, title: entry.title,
                                     author: entry.author)
        do {
            let row = try await service.upload(epubAt: file, book: book, existing: existing)
            replace(row.isAvailable ? row : Self.markedUploaded(existing, book: book))
            Announcer.announce(String(localized: "Uploaded “\(entry.title)” to Readest.",
                                      comment: "VoiceOver announcement after an upload; the placeholder is the title"))
            await refreshUsage()
        } catch {
            alert = .readestFailed(.upload, title: entry.title, error: error)
        }
    }

    /// The opt-in automatic upload after an import: only the user's own books, only when not already in Readest.
    func autoUploadIfNeeded(_ entry: LibraryEntry, from library: LibraryStore) {
        guard autoUpload, isAvailable, !entry.isSample, cloudBook(hash: entry.documentHash) == nil,
              library.originalFileURL(for: entry) != nil else { return }
        Task { await upload(entry, from: library) }
    }

    /// Deletes the book from the user's Readest account (files and row). Local copies are not touched.
    func deleteFromReadest(_ book: ReadestCloudBook) async {
        guard let service else { return }
        guard !isOffline else { alert = .readestOffline(); return }
        do {
            try await service.delete(book)
            var gone = book
            gone.deletedAt = Date()
            gone.uploadedAt = nil
            replace(gone)
            covers[book.hash] = nil
            try? FileManager.default.removeItem(at: coverDirectory.appendingPathComponent("\(book.hash).png"))
            await refreshUsage()
        } catch {
            alert = .readestFailed(.delete, title: book.title, error: error)
        }
    }

    private static func markedUploaded(_ existing: ReadestCloudBook?, book: ReadestUploadBook) -> ReadestCloudBook {
        var b = existing ?? ReadestCloudBook(hash: book.hash, metaHash: book.metaHash, title: book.title, author: book.author)
        b.uploadedAt = Date()
        b.deletedAt = nil
        b.updatedAt = Date()
        return b
    }

    private func replace(_ book: ReadestCloudBook) {
        if let i = cloudBooks.firstIndex(where: { $0.hash == book.hash }) { cloudBooks[i] = book } else { cloudBooks.insert(book, at: 0) }
        saveCache()
    }

    // MARK: Offline cache and network

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let books = try? JSONDecoder().decode([ReadestCloudBook].self, from: data) else { return }
        cloudBooks = books
        for b in books where b.isAvailable {
            if let image = UIImage(contentsOfFile: coverDirectory.appendingPathComponent("\(b.hash).png").path) {
                covers[b.hash] = image
            }
        }
    }

    private func saveCache() {
        guard !isFixed, let data = try? JSONEncoder().encode(cloudBooks) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOffline != offline else { return }
                self.isOffline = offline
                if !offline { await self.refresh() }
            }
        }
        m.start(queue: DispatchQueue(label: "folito.readest.network"))
        monitor = m
    }
}

extension UserFacingError {
    enum ReadestAction { case download, upload, delete }

    /// Message for a failed Readest library request (quota, connection, session...).
    static func readestLibraryMessage(for error: Error) -> String {
        switch error as? ReadestError {
        case .quotaExceeded:
            return String(localized: "Your Readest storage is full. Delete books from Readest, or get more storage in the Readest app, then try again.",
                          comment: "Readest library error: storage quota exceeded")
        case .fileTooLarge:
            return String(localized: "This book is too large for your Readest storage.",
                          comment: "Readest library error: file too large")
        case .notFound:
            return String(localized: "Readest no longer has this book’s file. Pull down to refresh the library.",
                          comment: "Readest library error: the file is missing on the server")
        case .some(let e):
            return readestMessage(for: e)
        case .none:
            if error is URLError {
                return readestMessage(for: .offline)
            }
            return String(localized: "Something went wrong. Try again later.", comment: "Generic error")
        }
    }

    static func readestFailed(_ action: ReadestAction, title: String, error: Error) -> UserFacingError {
        let alertTitle: String
        switch action {
        case .download:
            alertTitle = String(localized: "Couldn’t Download “\(title)”", comment: "Alert title; the placeholder is a book title")
        case .upload:
            alertTitle = String(localized: "Couldn’t Upload “\(title)”", comment: "Alert title; the placeholder is a book title")
        case .delete:
            alertTitle = String(localized: "Couldn’t Delete “\(title)” from Readest", comment: "Alert title; the placeholder is a book title")
        }
        return UserFacingError(title: alertTitle, message: readestLibraryMessage(for: error))
    }

    static func readestOffline() -> UserFacingError {
        UserFacingError(title: String(localized: "No Internet Connection", comment: "Alert title"),
                        message: String(localized: "Books in Readest need a connection. Connect to the internet and try again.",
                                        comment: "Alert message when a Readest action is tried offline"))
    }

    static func readestNoOriginal(title: String) -> UserFacingError {
        UserFacingError(title: String(localized: "Couldn’t Upload “\(title)”", comment: "Alert title; the placeholder is a book title"),
                        message: String(localized: "This book was imported before Folito kept the original EPUB file. Import the file again, then upload it.",
                                        comment: "Upload error: the original EPUB is not on this iPhone"))
    }
}
