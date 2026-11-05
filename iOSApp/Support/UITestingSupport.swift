import Foundation
import ReaderCore
import UIKit

/// Launch arguments used by the UI test target (FolitoUITests). Compiled into Debug builds only, so
/// a Release / App Store build has no test hooks at all.
///
/// - `-UITesting`: the library lives in a fresh temporary directory, so every launch starts empty and the
///   user's real library is never touched.
/// - `-UITestingSeedSampleBook` (implies `-UITesting`): also adds one small built-in sample book, so the
///   non-empty library can be audited.
/// - `-UITestingMockReadest` (with `-UITesting...`): Readest is signed in (in-memory Keychain and throw-away defaults)
///   and the Library shows a fixed, mocked Readest library (`MockReadestLibraryService`); no network.
///   `-UITestingReadestOffline` also shows the offline state.
/// - `-UITestingShowOnboarding` (implies `-UITesting`): opens the welcome tour on launch. Every other UI-testing
///   launch skips it (`-UITestingSkipOnboarding` says so explicitly); see `OnboardingPolicy`.
enum UITesting {
    static let isolateArgument = "-UITesting"
    static let seedSampleBookArgument = "-UITestingSeedSampleBook"
    static let mockReadestArgument = "-UITestingMockReadest"
    static let readestOfflineArgument = "-UITestingReadestOffline"

    #if DEBUG
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument)
            || args.contains(OnboardingPolicy.showArgument)
    }

    /// Root directory for `LibraryStore`; nil means the normal Application Support location.
    static var libraryRoot: URL? {
        guard isActive else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("UITesting-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    static func makeLibrary() -> LibraryStore {
        let store = LibraryStore(rootDirectory: libraryRoot)
        if ProcessInfo.processInfo.arguments.contains(seedSampleBookArgument) {
            try? store.addForUITesting(sampleBook, fileName: "sample.epub")
        }
        return store
    }

    private static var mockReadest: Bool { ProcessInfo.processInfo.arguments.contains(mockReadestArgument) }

    /// Readest signed in, in a throw-away Keychain service and defaults suite, when mocking Readest.
    @MainActor
    static func makeSyncSettings() -> SyncSettings {
        guard mockReadest else { return SyncSettings() }
        let keychain = KeychainStore(service: "com.xlahuerta.folito.uitesting", memory: MemoryKeychain())
        let suite = "uitesting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let key = ReadestConnectorFactory.Key.self
        let session = ReadestSession(accessToken: "ui-test", refreshToken: "ui-test", expiresAt: .distantFuture,
                                     lifetime: 3600, userID: "00000000-0000-0000-0000-000000000000",
                                     email: "reader@example.com") // i18n-ignore: UI-test fixture (Debug only)
        try? keychain.set("reader@example.com", account: key.email) // i18n-ignore: UI-test fixture
        try? keychain.set(session.jsonString(), account: key.session)
        try? keychain.set(session.jsonString(), account: SyncSettings.librarySessionAccount)
        defaults.set(ReadestConnectorFactory.id, forKey: SyncSettings.connectorKey)
        return SyncSettings(keychain: keychain, defaults: defaults)
    }

    @MainActor
    static func makeReadestLibrary() -> ReadestLibraryModel {
        guard mockReadest else { return ReadestLibraryModel(rootDirectory: libraryRoot) }
        let offline = ProcessInfo.processInfo.arguments.contains(readestOfflineArgument)
        return ReadestLibraryModel(defaults: UserDefaults(suiteName: "uitesting-readest-\(UUID().uuidString)") ?? .standard,
                                   rootDirectory: libraryRoot, fixedService: MockReadestLibraryService(),
                                   forceOffline: offline, monitorNetwork: false)
    }

    /// Dictionaries live next to the isolated library when UI testing (none installed).
    @MainActor
    static func makeDictionaryManager() -> DictionaryManager {
        DictionaryManager(rootDirectory: libraryRoot)
    }

    /// A tiny public-domain text (Lewis Carroll, 1865), built in code: no EPUB file ships in the app.
    static let sampleBook: ProcessedBook = {
        let text = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do." // i18n-ignore: UI-test fixture (Debug only)
        let blocks = [
            Block(text: "Down the Rabbit-Hole", style: .heading1, xpointer: "/body/DocFragment[1]/body/h1", globalOffset: 0),
            Block(text: text, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 20),
        ]
        return ProcessedBook(metadata: BookMetadata(title: "Alice’s Adventures in Wonderland", authors: ["Lewis Carroll"]),
                             documentHash: "00000000000000000000000000a11ce0",
                             metaHash: "00000000000000000000000000a11ce1",
                             chapters: [Chapter(spineIndex: 0, title: "Down the Rabbit-Hole", blocks: blocks)],
                             totalCharacters: 20 + text.count)
    }()
    #else
    @MainActor
    static func makeLibrary() -> LibraryStore { LibraryStore() }
    @MainActor
    static func makeSyncSettings() -> SyncSettings { SyncSettings() }
    @MainActor
    static func makeReadestLibrary() -> ReadestLibraryModel { ReadestLibraryModel() }
    @MainActor
    static func makeDictionaryManager() -> DictionaryManager { DictionaryManager() }
    #endif
}

#if DEBUG
/// A fixed Readest library for UI tests and screenshots: the seeded sample book (so it shows as "in Readest")
/// and three public-domain books only in Readest, with generated covers. Downloads stop at 45 % so the
/// downloading state can be captured; uploads and deletions succeed.
struct MockReadestLibraryService: ReadestLibraryService {
    static let books: [ReadestCloudBook] = {
        let now = Date()
        func book(_ hash: String, _ title: String, _ author: String, _ age: TimeInterval) -> ReadestCloudBook {
            ReadestCloudBook(hash: hash, title: title, author: author, updatedAt: now.addingTimeInterval(-age),
                             uploadedAt: now.addingTimeInterval(-age))
        }
        return [
            book(UITesting.sampleBook.documentHash, "Alice’s Adventures in Wonderland", "Lewis Carroll", 10), // i18n-ignore: UI-test fixture
            book("00000000000000000000000000b00c01", "Pride and Prejudice", "Jane Austen", 20), // i18n-ignore: UI-test fixture
            book("00000000000000000000000000b00c02", "The Time Machine", "H. G. Wells", 30), // i18n-ignore: UI-test fixture
            book("00000000000000000000000000b00c03", "Frankenstein", "Mary Shelley", 40), // i18n-ignore: UI-test fixture
        ]
    }()

    func fetchBooks() async throws -> [ReadestCloudBook] { Self.books }

    func downloadBook(hash: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        for step in 1...9 {
            try await Task.sleep(nanoseconds: 150_000_000)
            progress(Double(step) * 0.05)
        }
        try await Task.sleep(nanoseconds: 600_000_000_000)
        throw CancellationError()
    }

    func cover(hash: String) async throws -> Data? {
        let colors: [UIColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink]
        let color = colors[(Int(hash.suffix(1), radix: 16) ?? 0) % colors.count]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
            UIColor.white.withAlphaComponent(0.85).setFill()
            ctx.fill(CGRect(x: 12, y: 30, width: 56, height: 6))
            ctx.fill(CGRect(x: 12, y: 44, width: 40, height: 6))
        }
        return image.pngData()
    }

    func upload(epubAt url: URL, book: ReadestUploadBook, existing: ReadestCloudBook?) async throws -> ReadestCloudBook {
        ReadestCloudBook(hash: book.hash, title: book.title, author: book.author, updatedAt: Date(), uploadedAt: Date())
    }

    func delete(_ book: ReadestCloudBook) async throws {}

    func storageUsage() async throws -> ReadestStorageUsage {
        ReadestStorageUsage(usage: 126_000_000, quota: 524_288_000)
    }
}
#endif
