import XCTest
@testable import Folito
import ReaderCore

final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testFirstLaunchShowsTheTour() {
        let model = OnboardingModel(defaults: defaults, arguments: [])
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.isCompleted)
    }

    @MainActor
    func testFinishingRecordsCompletionAndIsNotShownAgain() {
        let model = OnboardingModel(defaults: defaults, arguments: [])
        model.finish()
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.isCompleted)
        XCTAssertEqual(defaults.integer(forKey: OnboardingPolicy.completedVersionKey), OnboardingPolicy.currentVersion)
        XCTAssertFalse(OnboardingModel(defaults: defaults, arguments: []).isPresented, "second launch")
    }

    @MainActor
    func testCanBeReopenedFromSettings() {
        let model = OnboardingModel(defaults: defaults, arguments: [])
        model.finish()
        model.show()
        XCTAssertTrue(model.isPresented)
        model.finish()
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.isCompleted)
    }

    @MainActor
    func testOlderCompletedVersionShowsAgain() {
        defaults.set(OnboardingPolicy.currentVersion - 1, forKey: OnboardingPolicy.completedVersionKey)
        XCTAssertTrue(OnboardingModel(defaults: defaults, arguments: []).isPresented)
    }

    @MainActor
    func testLaunchArguments() {
        XCTAssertNil(OnboardingPolicy.launchOverride(arguments: []))
        XCTAssertNil(OnboardingPolicy.launchOverride(arguments: ["-SomethingElse"]))
        // Existing UI tests (-UITesting / -UITestingSeedSampleBook) skip the tour by default.
        XCTAssertEqual(OnboardingPolicy.launchOverride(arguments: ["-UITesting"]), .skip)
        XCTAssertEqual(OnboardingPolicy.launchOverride(arguments: ["-UITestingSeedSampleBook"]), .skip)
        XCTAssertEqual(OnboardingPolicy.launchOverride(arguments: ["-UITestingSkipOnboarding"]), .skip)
        XCTAssertEqual(OnboardingPolicy.launchOverride(arguments: ["-UITesting", "-UITestingShowOnboarding"]), .show)

        XCTAssertFalse(OnboardingModel(defaults: defaults, arguments: ["-UITesting"]).isPresented)
        defaults.set(OnboardingPolicy.currentVersion, forKey: OnboardingPolicy.completedVersionKey)
        XCTAssertTrue(OnboardingModel(defaults: defaults, arguments: ["-UITestingShowOnboarding"]).isPresented)
    }

    func testPolicy() {
        XCTAssertTrue(OnboardingPolicy.shouldShowOnLaunch(completedVersion: 0, override: nil))
        XCTAssertFalse(OnboardingPolicy.shouldShowOnLaunch(completedVersion: OnboardingPolicy.currentVersion, override: nil))
        XCTAssertTrue(OnboardingPolicy.shouldShowOnLaunch(completedVersion: OnboardingPolicy.currentVersion, override: .show))
        XCTAssertFalse(OnboardingPolicy.shouldShowOnLaunch(completedVersion: 0, override: .skip))
    }

    func testPagesInOrder() {
        XCTAssertEqual(OnboardingPage.allCases.map(\.number), [1, 2, 3, 4])
        XCTAssertNil(OnboardingPage.welcome.previous)
        XCTAssertEqual(OnboardingPage.welcome.next, .howItWorks)
        XCTAssertNil(OnboardingPage.extras.next)
    }
}

final class SampleBookSelectionTests: XCTestCase {
    func testLanguageSelection() {
        XCTAssertEqual(SampleBooks.language(for: "en"), "en")
        XCTAssertEqual(SampleBooks.language(for: "en-GB"), "en")
        XCTAssertEqual(SampleBooks.language(for: "es-MX"), "es")
        XCTAssertEqual(SampleBooks.language(for: "fr-CA"), "fr")
        XCTAssertEqual(SampleBooks.language(for: "de-AT"), "de")
        XCTAssertEqual(SampleBooks.language(for: "it"), "it")
        XCTAssertEqual(SampleBooks.language(for: "pt-BR"), "pt-BR")
        XCTAssertEqual(SampleBooks.language(for: "pt-PT"), "pt-BR")
        XCTAssertEqual(SampleBooks.language(for: "ja-JP"), "ja")
        XCTAssertEqual(SampleBooks.language(for: "zh-Hans"), "zh-Hans")
        XCTAssertEqual(SampleBooks.language(for: "zh-CN"), "zh-Hans")
        XCTAssertEqual(SampleBooks.language(for: "zh-Hant"), "en", "no Traditional Chinese sample")
        XCTAssertEqual(SampleBooks.language(for: "ko"), "en")
        XCTAssertEqual(SampleBooks.language(for: nil), "en")
        XCTAssertEqual(SampleBooks.language(for: ""), "en")
    }

    /// Every language's EPUB is bundled in the app.
    func testEverySampleIsBundled() {
        let appBundle = Bundle(for: LibraryStore.self)
        for language in SampleBooks.languages {
            XCTAssertNotNil(SampleBooks.url(for: language, in: appBundle), language)
        }
    }

    /// The "Other Languages…" list has one sample per app language, the preferred one first.
    func testOrderedListPutsPreferredLanguageFirst() {
        XCTAssertEqual(SampleBooks.all.map(\.language), SampleBooks.languages)
        XCTAssertEqual(SampleBooks.ordered(preferred: "en").map(\.language), SampleBooks.languages)
        let spanishFirst = SampleBooks.ordered(preferred: "es").map(\.language)
        XCTAssertEqual(spanishFirst, ["es", "en", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"])
        XCTAssertEqual(SampleBooks.ordered(preferred: "zh-Hans").first?.language, "zh-Hans")
        XCTAssertEqual(Set(SampleBooks.ordered(preferred: "ja").map(\.language)).count, SampleBooks.languages.count)
    }

    func testNativeLanguageNames() {
        XCTAssertEqual(SampleBooks.nativeName(for: "en"), "English")
        XCTAssertEqual(SampleBooks.nativeName(for: "es"), "Español")
        XCTAssertEqual(SampleBooks.nativeName(for: "fr"), "Français")
        XCTAssertEqual(SampleBooks.nativeName(for: "de"), "Deutsch")
        XCTAssertEqual(SampleBooks.nativeName(for: "it"), "Italiano")
        XCTAssertEqual(SampleBooks.nativeName(for: "ja"), "日本語")
        XCTAssertTrue(SampleBooks.nativeName(for: "pt-BR").hasPrefix("Português"), SampleBooks.nativeName(for: "pt-BR"))
        XCTAssertTrue(SampleBooks.nativeName(for: "zh-Hans").contains("中文"), SampleBooks.nativeName(for: "zh-Hans"))
    }

    /// Every sample imports through the real pipeline with the title and author the list shows.
    @MainActor
    func testEverySampleImportsWithListedTitleAndAuthor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(rootDirectory: dir)
        var imported: LibraryEntry?
        store.onImported = { imported = $0 }
        for sample in SampleBooks.all {
            imported = nil
            XCTAssertTrue(store.addSample(language: sample.language, bundle: Bundle(for: LibraryStore.self)))
            for _ in 0..<200 where imported == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            let entry = try XCTUnwrap(imported, sample.language)
            XCTAssertEqual(entry.title, sample.title, sample.language)
            XCTAssertEqual(entry.author, sample.author, sample.language)
            XCTAssertEqual(store.sampleEntry(language: sample.language), entry)
        }
        XCTAssertEqual(store.entries.count, SampleBooks.all.count)
    }

    /// Issue #103: a book downloaded from Readest takes the row's ids (not the partial MD5 of the bytes served),
    /// in the library and in the payload the watch syncs its position with; a copy downloaded before that takes
    /// them when relinked, and replaces itself (on the watch too).
    @MainActor
    func testReadestDownloadAndRelinkTakeTheRowsIds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epub = try XCTUnwrap(SampleBooks.url(for: "en", in: Bundle(for: LibraryStore.self)))
        let row = ReadestCloudBook(hash: "9b1c4f0e2d7a6b3c8e5f1a2d4c6b8e0f", metaHash: "c2a7d05b8e9f41a3b6d2e4f8a1c3e5d7",
                                   title: "The Hunger Games", author: "Suzanne Collins", uploadedAt: Date())
        let store = LibraryStore(rootDirectory: dir)

        let imported = await store.importDownloaded(from: epub, fileName: "The Hunger Games.epub",
                                                    identity: BookIdentityOverride(row))
        let downloaded = try XCTUnwrap(imported)
        XCTAssertEqual(downloaded.documentHash, row.hash)
        XCTAssertEqual(downloaded.metaHash, row.metaHash)
        let payload = try BookCodec.decode(Data(contentsOf: store.fileURL(for: downloaded)))
        XCTAssertEqual(payload.documentHash, row.hash, "the watch pulls the position by this id")
        XCTAssertEqual(payload.metaHash, row.metaHash)
        XCTAssertNotNil(store.originalFileURL(for: downloaded))
        store.delete(downloaded)

        // Downloaded before the fix: the id of the bytes. Relinking gives it the row's ids.
        let importedBeforeFix = await store.importDownloaded(from: epub, fileName: "The Hunger Games.epub")
        let old = try XCTUnwrap(importedBeforeFix)
        XCTAssertNotEqual(old.documentHash, row.hash)
        store.markSent(hash: old.documentHash)
        var deleted: [String] = []
        var resent: [String] = []
        store.onDeleted = { deleted.append($0.documentHash) }
        store.onRelinked = { entry, wasOnWatch in if wasOnWatch { resent.append(entry.documentHash) } }
        let current = try XCTUnwrap(store.entries.first)
        let result = await store.relink(current, to: BookIdentityOverride(row))
        let relinked = try XCTUnwrap(result)
        XCTAssertEqual(store.entries.map(\.documentHash), [row.hash])
        XCTAssertEqual(relinked.importedAt, old.importedAt)
        XCTAssertEqual(try BookCodec.decode(Data(contentsOf: store.fileURL(for: relinked))).documentHash, row.hash)
        XCTAssertNotNil(store.originalFileURL(for: relinked))
        XCTAssertNil(store.originalFileURL(for: old))
        XCTAssertEqual(deleted, [old.documentHash])
        XCTAssertEqual(resent, [row.hash])
        let again = await store.relink(relinked, to: BookIdentityOverride(row))
        XCTAssertNil(again, "already linked")
    }

    func testLegacyLibraryEntryDecodesWithoutSampleField() throws {
        let json = #"[{"documentHash":"h","title":"T","author":"A","fileName":"h.wrbook","size":5,"importedAt":0,"sentToWatch":true}]"#
        let entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.isSample, false)
    }

    /// The sample goes through the real import pipeline and is marked as a sample.
    @MainActor
    func testAddSampleImportsAndMarksIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(rootDirectory: dir)
        var imported: LibraryEntry?
        store.onImported = { imported = $0 }
        XCTAssertTrue(store.addSample(language: "de", bundle: Bundle(for: LibraryStore.self)))
        for _ in 0..<200 where imported == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let entry = try XCTUnwrap(imported)
        XCTAssertEqual(entry.title, "Die Verwandlung")
        XCTAssertEqual(entry.sampleLanguage, "de")
        XCTAssertTrue(entry.isSample)
        XCTAssertEqual(store.sampleEntry(language: "de"), entry)
        XCTAssertEqual(store.lastImported, entry)
        XCTAssertNil(store.sampleEntry(language: "en"))
    }
}
