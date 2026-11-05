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
    /// `-UITestingSeedCovers` (implies `-UITesting`): the sample book (no cover: placeholder) plus two books with
    /// generated covers and full details (series, description, publisher), for the covers screenshots.
    static let seedCoversArgument = "-UITestingSeedCovers"
    /// `-UITestingMockOnlineMetadata`: *Find Details Online* asks `MockOnlineMetadataProvider` instead of Open
    /// Library (no network). With `-UITestingOnlineMetadataSeveral` it offers three matches, with
    /// `-UITestingOnlineMetadataEmpty` none, with `-UITestingOnlineMetadataOffline` it fails as if offline.
    static let mockOnlineMetadataArgument = "-UITestingMockOnlineMetadata"

    #if DEBUG
    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(isolateArgument) || args.contains(seedSampleBookArgument)
            || args.contains(OnboardingPolicy.showArgument) || args.contains(seedCoversArgument)
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
        if ProcessInfo.processInfo.arguments.contains(seedCoversArgument) {
            seedCovers(into: store)
        }
        return store
    }

    /// Public-domain books with generated covers (no cover art ships in the app).
    @MainActor
    private static func seedCovers(into store: LibraryStore) {
        try? store.addForUITesting(sampleBook, fileName: "sample.epub")
        func book(_ hash: String, _ title: String, _ author: String) -> ProcessedBook {
            let text = "Chapter one." // i18n-ignore: UI-test fixture (Debug only)
            return ProcessedBook(metadata: BookMetadata(title: title, authors: [author]), documentHash: hash, metaHash: hash + "m",
                                 chapters: [Chapter(spineIndex: 1, title: nil, blocks: [
                                     Block(text: text, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0)])],
                                 totalCharacters: text.count)
        }
        let emma = book("00000000000000000000000000e00a01", "Emma", "Jane Austen") // i18n-ignore: UI-test fixture
        try? store.addForUITesting(emma, fileName: "emma.epub", coverPNG: generatedCover(.systemTeal),
                                   details: EPUBDetails(title: "Emma", creators: [BookCreator(name: "Jane Austen", role: "aut")], // i18n-ignore: UI-test fixture
                                                        publisher: "John Murray", year: 1815, language: "en"), // i18n-ignore: UI-test fixture
                                   sentToWatch: true)
        let mars = book("00000000000000000000000000e00a02", "The Gods of Mars", "Edgar Rice Burroughs") // i18n-ignore: UI-test fixture
        let blurb = "John Carter returns to Barsoom after ten years on Earth, only to find himself in the Valley Dor, the paradise every Martian hopes to reach at the end of life. It is a trap: the valley is ruled by plant men and great white apes, and the holy therns who guard it prey on the pilgrims who come there.\n\nWith Tars Tarkas at his side, Carter fights his way out and sets out to expose the false religion of Mars." // i18n-ignore: UI-test fixture
        try? store.addForUITesting(mars, fileName: "mars.epub", coverPNG: generatedCover(.systemOrange),
                                   details: EPUBDetails(title: "The Gods of Mars", // i18n-ignore: UI-test fixture
                                                        creators: [BookCreator(name: "Edgar Rice Burroughs", role: "aut")], // i18n-ignore: UI-test fixture
                                                        description: blurb, publisher: "A. C. McClurg", year: 1918, // i18n-ignore: UI-test fixture
                                                        language: "en", subjects: ["Science fiction"], // i18n-ignore: UI-test fixture
                                                        series: BookSeries(name: "Barsoom", index: 2)), // i18n-ignore: UI-test fixture
                                   sentToWatch: true)
    }

    /// A simple, recognisable cover: a colour field with two "title" bars and a disc.
    static func generatedCover(_ color: UIColor) -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.black.withAlphaComponent(0.25).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 40, y: 130, width: 120, height: 120))
            UIColor.white.withAlphaComponent(0.9).setFill()
            ctx.fill(CGRect(x: 24, y: 36, width: 152, height: 16))
            ctx.fill(CGRect(x: 24, y: 64, width: 100, height: 12))
        }.pngData()
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

    /// The online lookup, with a mocked provider and throw-away defaults (the setting starts off) when asked.
    @MainActor
    static func makeOnlineMetadata() -> OnlineMetadataModel {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(mockOnlineMetadataArgument) else {
            return isActive ? OnlineMetadataModel(defaults: UserDefaults(suiteName: "uitesting-online-\(UUID().uuidString)") ?? .standard)
                            : OnlineMetadataModel()
        }
        let mode: MockOnlineMetadataProvider.Mode = args.contains("-UITestingOnlineMetadataOffline") ? .offline
            : args.contains("-UITestingOnlineMetadataEmpty") ? .empty
            : args.contains("-UITestingOnlineMetadataSeveral") ? .several : .one
        return OnlineMetadataModel(provider: MockOnlineMetadataProvider(mode: mode),
                                   defaults: UserDefaults(suiteName: "uitesting-online-\(UUID().uuidString)") ?? .standard)
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
    @MainActor
    static func makeOnlineMetadata() -> OnlineMetadataModel { OnlineMetadataModel() }
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

/// Fixed Open Library answers for UI tests and screenshots: public-domain books, generated covers, no network.
struct MockOnlineMetadataProvider: OnlineMetadataProviding {
    enum Mode: Sendable { case one, several, empty, offline }
    let mode: Mode

    static let alice = OnlineBookMatch(
        key: "/works/OL138052W", title: "Alice’s Adventures in Wonderland", authors: ["Lewis Carroll"], // i18n-ignore: UI-test fixture
        year: 1865, publisher: "Macmillan", subjects: ["Fantasy fiction", "Children’s stories"], // i18n-ignore: UI-test fixture
        description: "Alice follows a White Rabbit down a rabbit hole into a world of nonsense, where she meets the Cheshire Cat, the Mad Hatter and the Queen of Hearts, and grows and shrinks by turns.", // i18n-ignore: UI-test fixture
        coverID: 1)

    var matches: [OnlineBookMatch] {
        switch mode {
        case .one: return [Self.alice]
        case .several:
            return [Self.alice,
                    OnlineBookMatch(key: "/works/OL2W", title: "Alice’s Adventures in Wonderland and Through the Looking-Glass", // i18n-ignore: UI-test fixture
                                    authors: ["Lewis Carroll"], year: 1871, coverID: 2), // i18n-ignore: UI-test fixture
                    OnlineBookMatch(key: "/works/OL3W", title: "The Annotated Alice", authors: ["Lewis Carroll", "Martin Gardner"], // i18n-ignore: UI-test fixture
                                    year: 1960)]
        case .empty, .offline: return []
        }
    }

    func lookup(_ query: OnlineLookupQuery) async throws -> [OnlineBookMatch] {
        try await Task.sleep(nanoseconds: 300_000_000)
        if mode == .offline { throw OnlineMetadataError.offline }
        return matches
    }

    func description(for match: OnlineBookMatch) async throws -> String? { match.description }

    func cover(for match: OnlineBookMatch) async throws -> Data? {
        guard let id = match.coverID else { return nil }
        return UITesting.generatedCover(id == 1 ? .systemPurple : .systemGreen)
    }
}
#endif
