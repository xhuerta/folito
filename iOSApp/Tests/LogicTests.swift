import XCTest
import UIKit
import ReaderCore
@testable import Folito

final class LogicTests: XCTestCase {
    func testCredentialsDefaultsAndNormalises() {
        let c = SyncSettingsValidator.credentials(server: "", user: " bob ", password: "pw")
        XCTAssertEqual(c?.serverURL.absoluteString, "https://sync.koreader.rocks")
        XCTAssertEqual(c?.username, "bob")
        XCTAssertEqual(SyncSettingsValidator.credentials(server: "example.com/", user: "a", password: "b")?.serverURL.absoluteString,
                       "https://example.com")
    }

    func testCredentialsRejectMissingFields() {
        XCTAssertNil(SyncSettingsValidator.credentials(server: "", user: "", password: "x"))
        XCTAssertNil(SyncSettingsValidator.credentials(server: "", user: "a", password: ""))
        XCTAssertNil(SyncSettingsValidator.credentials(server: "ftp://x", user: "a", password: "b"))
    }

    func testBookDisplay() {
        XCTAssertEqual(BookDisplay.author(from: []), "Unknown author")
        XCTAssertEqual(BookDisplay.author(from: ["A", " B "]), "A, B")
        XCTAssertEqual(BookDisplay.title("  ", fallbackFileName: "x.epub"), "x")
    }

    func testSchema() {
        let e = LibraryEntry(documentHash: "h", title: "T", author: "A", fileName: "h.wrbook", size: 5,
                             importedAt: Date(), sentToWatch: false)
        let m = WatchSchema.bookMetadata(for: e, formatVersion: 1)
        XCTAssertEqual(m["documentHash"] as? String, "h")
        XCTAssertEqual(m["size"] as? Int, 5)
        XCTAssertEqual(WatchSchema.deleteBook(hash: "h")["type"] as? String, "delete_book")
    }

    func testSchemaCarriesCoverAndReadsProgress() {
        let e = LibraryEntry(documentHash: "h", title: "T", author: "A", fileName: "h.wrbook", size: 5,
                             importedAt: Date(), sentToWatch: false)
        XCTAssertNil(WatchSchema.bookMetadata(for: e, formatVersion: 1)["cover"])
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        XCTAssertEqual(WatchSchema.bookMetadata(for: e, formatVersion: 1, cover: jpeg)["cover"] as? Data, jpeg)
        let c = WatchSchema.bookCover(hash: "h", cover: jpeg)
        XCTAssertEqual(c["type"] as? String, "book_cover")
        XCTAssertEqual(c["documentHash"] as? String, "h")
        let progress = WatchSchema.libraryProgress(from: ["type": "library", "progress": ["a": 43, "b": 101, "c": -1]])
        XCTAssertEqual(progress, ["a": 0.43])
        XCTAssertNil(WatchSchema.libraryProgress(from: ["type": "settings"]))
    }

    @MainActor
    func testSeriesText() {
        XCTAssertEqual(BookDetailView.seriesText(BookSeries(name: "Dune", index: 2)), "Book 2 of Dune")
        XCTAssertEqual(BookDetailView.seriesText(BookSeries(name: "Tales", index: 2.5)).contains("2"), true)
        XCTAssertEqual(BookDetailView.seriesText(BookSeries(name: "Dune")), "Part of Dune")
    }

    @MainActor
    func testCoverThumbnailsAndPlaceholder() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1800)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 100, y: 200, width: 1000, height: 120))
        }
        let png = try XCTUnwrap(big.pngData())
        let watch = try XCTUnwrap(CoverStore.watchJPEG(from: png))
        XCTAssertLessThanOrEqual(watch.count, CoverStore.watchMaxBytes)
        let thumb = try XCTUnwrap(CoverStore.thumbnail(png, maxPixels: CoverStore.libraryPixels))
        XCTAssertEqual(max(thumb.width, thumb.height), CoverStore.libraryPixels)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cover = EPUBCover(data: png, mediaType: "image/png", path: "c.png", source: .coverImageProperty)
        XCTAssertTrue(CoverStore.storeCover(cover, hash: "h", in: dir))
        XCTAssertNotNil(CoverImages.shared.cover(hash: "h", in: dir))
        let svg = EPUBCover(data: Data("<svg/>".utf8), mediaType: "image/svg+xml", path: "c.svg", source: .coverImageProperty)
        XCTAssertFalse(CoverStore.storeCover(svg, hash: "h", in: dir), "SVG covers get the placeholder")
        CoverImages.shared.invalidate(hash: "h")
        XCTAssertNil(CoverImages.shared.cover(hash: "h", in: dir))
        let placeholder = CoverImages.shared.placeholder(title: "Emma", author: "Jane Austen", size: CGSize(width: 40, height: 60))
        XCTAssertEqual(placeholder.size, CGSize(width: 40, height: 60))
    }

    func testInsecureWarning() {
        XCTAssertNil(SyncSettingsValidator.insecureWarning(server: "https://sync.example.org"))
        XCTAssertNil(SyncSettingsValidator.insecureWarning(server: "sync.example.org"))
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://192.168.1.5:8081")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://nas.local")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://nas")?.contains("home network") == true)
        XCTAssertTrue(SyncSettingsValidator.insecureWarning(server: "http://sync.example.org")?.contains("blocks") == true)
    }

    func testATSErrorMessage() {
        let msg = SyncSettingsValidator.message(for: URLError(.appTransportSecurityRequiresSecureConnection))
        XCTAssertTrue(msg.contains("https"))
    }

    func testSettingsSchemaAndLibraryContext() {
        let info = WatchSchema.clearedInfo(stamp: 7)
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertEqual(info["settingsStamp"] as? Int, 7)
        XCTAssertEqual(WatchSchema.librarySettingsStamp(from: ["type": "library", "hashes": [String](), "settingsStamp": 7]), 7)
        XCTAssertEqual(WatchSchema.librarySettingsStamp(from: ["type": "library", "hashes": [String]()]), 0)
        XCTAssertNil(WatchSchema.librarySettingsStamp(from: ["type": "settings", "settingsStamp": 7]))
        XCTAssertEqual(WatchSchema.libraryHashes(from: ["type": "library", "hashes": ["a", "b"]]), ["a", "b"])
        XCTAssertNil(WatchSchema.libraryHashes(from: ["type": "settings"]))
        XCTAssertEqual(WatchSchema.libraryTimeRemaining(from: ["type": "library", "hashes": ["a"]]), [:])
        XCTAssertEqual(WatchSchema.libraryTimeRemaining(from: ["type": "library",
                                                               "timeRemaining": ["a": 600.0, "b": -1.0, "c": 60]]),
                       ["a": 600, "c": 60])
        XCTAssertNil(WatchSchema.libraryTimeRemaining(from: ["type": "settings", "timeRemaining": ["a": 600.0]]))
    }

    @MainActor
    func testReconcileMarksUnsentWhenWatchLacksBook() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootDirectory: dir)
        XCTAssertTrue(store.unsentBooks.isEmpty)
        store.reconcile(watchHashes: [], inFlight: [])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearedSettingsSchema() {
        let info = WatchSchema.clearedInfo(stamp: 42)
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertEqual(info["sync_cleared"] as? Bool, true)
        XCTAssertEqual(info["settingsStamp"] as? Int, 42)
        XCTAssertEqual(info["settingsVersion"] as? Int, 1)
        XCTAssertNil(info["sync_connector"])
        XCTAssertNil(info["sync_credentials"])
        let cleared = WatchSchema.settingsContext(clearedStamp: 9, typography: nil)
        XCTAssertEqual(cleared["sync_cleared"] as? Bool, true)
        XCTAssertEqual(cleared["settingsStamp"] as? Int, 9)
        // Never turned off: the context says nothing about sync.
        for context in [WatchSchema.settingsContext(clearedStamp: nil, typography: nil),
                        WatchSchema.settingsContext(clearedStamp: 0, typography: nil)] {
            XCTAssertEqual(context["type"] as? String, "settings")
            XCTAssertEqual(context["settingsVersion"] as? Int, 1)
            XCTAssertNil(context["sync_cleared"])
            XCTAssertNil(context["settingsStamp"])
        }
    }

    func testCredentialsMessageSchema() {
        let readest = SyncCredentials([ReadestConnectorFactory.Key.email: "a@b.c",
                                       ReadestConnectorFactory.Key.session: "{}"])
        let info = WatchSchema.credentialsMessage(connectorID: "readest", credentials: readest, stamp: 3)
        XCTAssertEqual(info["type"] as? String, "credentials")
        XCTAssertEqual(info["sync_connector"] as? String, "readest")
        XCTAssertEqual(info["settingsVersion"] as? Int, 1)
        XCTAssertEqual(info["settingsStamp"] as? Int, 3)
        XCTAssertEqual(SyncSettingsWire.decode(info)?.1, readest)
        XCTAssertEqual(WatchSchema.credentialsStamp(from: info), 3)
        XCTAssertNil(WatchSchema.credentialsStamp(from: WatchSchema.clearedInfo(stamp: 3)))
        XCTAssertNil(WatchSchema.credentialsStamp(from: WatchSchema.deleteBook(hash: "a")))
    }

    func testCredentialsAreSentUntilTheWatchReportsTheirStamp() {
        XCTAssertTrue(WatchSchema.needsCredentials(watchStamp: nil, phoneStamp: 5), "watch has not reported yet")
        XCTAssertTrue(WatchSchema.needsCredentials(watchStamp: 0, phoneStamp: 5), "new or reinstalled watch app")
        XCTAssertTrue(WatchSchema.needsCredentials(watchStamp: 4, phoneStamp: 5))
        XCTAssertFalse(WatchSchema.needsCredentials(watchStamp: 5, phoneStamp: 5))
        XCTAssertFalse(WatchSchema.needsCredentials(watchStamp: 6, phoneStamp: 5))
    }

    /// Issue #57: nothing the phone sends to the watch may contain the password the user typed.
    func testNothingSentToTheWatchContainsThePlaintextPassword() async throws {
        let password = "Plaintext-Pässword-1234"
        let factory = KOSyncConnectorFactory()
        typealias Key = KOSyncConnectorFactory.Key
        let stored = try await factory.signIn(fields: [Key.server: "https://sync.example.org", Key.user: "alice",
                                                       Key.password: password], session: .shared)
        XCTAssertEqual(stored[Key.password], password, "the iPhone Keychain copy keeps it for the form")
        let settings = SyncSettings.watchSettings(factory: factory, credentials: stored, stamp: 7)
        XCTAssertNil(settings.credentials[Key.password])
        XCTAssertEqual(settings.credentials[Key.authKey], KOSyncClient.authKey(forPassword: password))
        XCTAssertEqual(settings.credentials[Key.user], "alice")
        var typography = ReaderTypography.default
        typography.stamp = 3
        let payloads: [[String: Any]] = [
            WatchSchema.credentialsMessage(connectorID: settings.connectorID, credentials: settings.credentials,
                                           stamp: settings.stamp),
            WatchSchema.settingsContext(clearedStamp: nil, typography: typography),
            WatchSchema.settingsContext(clearedStamp: 9, typography: typography),
            WatchSchema.clearedInfo(stamp: 9),
        ]
        for payload in payloads {
            XCTAssertNil(payload[Key.password])
            for (key, value) in payload {
                XCTAssertFalse("\(key) \(value)".contains(password), "\(key) carries the plaintext password")
            }
            // What WatchConnectivity actually writes: a property list.
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(password))
        }
        // The settings context (kept on disk by the system) carries no credentials of any connector.
        for context in payloads.dropFirst() {
            XCTAssertNil(context["sync_credentials"])
            XCTAssertNil(context["sync_connector"])
        }
    }
}

@MainActor
final class SyncOptionalTests: XCTestCase {
    private func make() -> (SyncSettings, KeychainStore, UserDefaults) {
        let kc = KeychainStore(service: "test.folito.\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (SyncSettings(keychain: kc, defaults: d, clientFactory: { _ in MockKOSyncClient() }), kc, d)
    }

    func testPrefilledDefaultServerDoesNotMeanConfigured() {
        let (s, _, _) = make()
        XCTAssertEqual(s.selectedConnectorID, "", "sync starts on None")
        s.selectedConnectorID = KOSyncConnectorFactory.id
        XCTAssertEqual(s.server, SyncSettingsValidator.defaultServer)
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNil(s.savedForWatch())
        XCTAssertNil(s.clearedStamp)
        s.username = "u" // typing without saving does not turn sync on
        XCTAssertFalse(s.isSyncOn)
    }

    func testSaveTurnsOnAndTurnOffClearsEverything() async throws {
        let (s, kc, _) = make()
        s.selectedConnectorID = KOSyncConnectorFactory.id
        s.username = "u"; s.password = "p"
        await s.save()
        try XCTSkipUnless(s.isSyncOn, "Keychain unavailable in this test host")
        XCTAssertEqual(s.savedForWatch()?.connectorID, KOSyncConnectorFactory.id)
        XCTAssertEqual(s.savedForWatch()?.credentials[KOSyncConnectorFactory.Key.user], "u")
        XCTAssertNil(s.savedForWatch()?.credentials[KOSyncConnectorFactory.Key.password], "the watch never gets the password")
        XCTAssertEqual(s.savedForWatch()?.credentials[KOSyncConnectorFactory.Key.authKey], KOSyncClient.authKey(forPassword: "p"))
        XCTAssertNil(s.clearedStamp)
        var turnedOff = 0
        s.onTurnOff = { turnedOff += 1 }
        s.turnOff()
        XCTAssertEqual(turnedOff, 1)
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNil(kc.get(account: KOSyncConnectorFactory.Key.user))
        XCTAssertNil(kc.get(account: KOSyncConnectorFactory.Key.password))
        XCTAssertNil(s.savedForWatch())
        XCTAssertEqual(s.selectedConnectorID, "")
        XCTAssertEqual(s.username, "")
        XCTAssertEqual(s.password, "")
        let cleared = s.clearedStamp
        XCTAssertNotNil(cleared)
        // Saving again supersedes the cleared state with a strictly newer stamp.
        s.selectedConnectorID = KOSyncConnectorFactory.id
        s.username = "u"; s.password = "p"
        await s.save()
        XCTAssertNil(s.clearedStamp)
        XCTAssertGreaterThan(s.savedForWatch()?.stamp ?? 0, cleared ?? Int.max)
        s.turnOff()
    }

    func testSwitchingServiceShowsItsOwnForm() {
        let (s, _, _) = make()
        s.selectedConnectorID = ReadestConnectorFactory.id
        XCTAssertEqual(Set(s.fields.keys), [ReadestConnectorFactory.Key.email, ReadestConnectorFactory.Key.password])
        XCTAssertFalse(s.selectedFactory?.descriptor.supportsConnectionTest ?? true,
                       "the phone never refreshes a Readest session (the watch owns it)")
        XCTAssertNil(s.insecureWarning)
        s.selectedConnectorID = ""
        XCTAssertTrue(s.fields.isEmpty)
    }

    func testReadestMissingFields() async {
        let (s, _, _) = make()
        s.selectedConnectorID = ReadestConnectorFactory.id
        await s.save()
        XCTAssertEqual(s.status, .missingFieldsStatus(for: ReadestConnectorFactory.id))
        XCTAssertFalse(s.isSyncOn)
    }

    func testTurnOffWithoutEverConfiguringStillProducesClearedState() {
        let (s, _, _) = make()
        s.turnOff()
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNotNil(s.clearedStamp)
    }
}
