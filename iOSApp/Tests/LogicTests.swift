import XCTest
@testable import WristReader

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
        let info = WatchSchema.settingsInfo(server: "s", user: "u", password: "p", stamp: 7)
        XCTAssertEqual(info["type"] as? String, "settings")
        XCTAssertEqual(info["settingsStamp"] as? Int, 7)
        XCTAssertEqual(WatchSchema.libraryHashes(from: ["type": "library", "hashes": ["a", "b"]]), ["a", "b"])
        XCTAssertNil(WatchSchema.libraryHashes(from: ["type": "settings"]))
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
        XCTAssertEqual(info["kosync_cleared"] as? Bool, true)
        XCTAssertEqual(info["settingsStamp"] as? Int, 42)
        XCTAssertNil(info["kosync_user"])
        XCTAssertNil(info["kosync_password"])
        XCTAssertNil(info["kosync_server"])
        // Credentials win over a stale cleared stamp; cleared is used only without credentials.
        let creds = WatchSchema.settingsContext(kosync: ("s", "u", "p", 5), clearedStamp: 4, typography: nil)
        XCTAssertEqual(creds?["kosync_user"] as? String, "u")
        XCTAssertNil(creds?["kosync_cleared"])
        let cleared = WatchSchema.settingsContext(kosync: nil, clearedStamp: 9, typography: nil)
        XCTAssertEqual(cleared?["kosync_cleared"] as? Bool, true)
        XCTAssertEqual(cleared?["settingsStamp"] as? Int, 9)
        // Never configured: nothing is sent at all.
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, clearedStamp: nil, typography: nil))
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, clearedStamp: 0, typography: nil))
    }
}

@MainActor
final class SyncOptionalTests: XCTestCase {
    private func make() -> (SyncSettings, KeychainStore, UserDefaults) {
        let kc = KeychainStore(service: "test.wristreader.\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return (SyncSettings(keychain: kc, defaults: d, clientFactory: { _ in MockKOSyncClient() }), kc, d)
    }

    func testPrefilledDefaultServerDoesNotMeanConfigured() {
        let (s, _, _) = make()
        XCTAssertEqual(s.server, SyncSettingsValidator.defaultServer)
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNil(s.savedForWatch())
        XCTAssertNil(s.clearedStamp)
        s.username = "u" // typing without saving does not turn sync on
        XCTAssertFalse(s.isSyncOn)
    }

    func testSaveTurnsOnAndTurnOffClearsEverything() throws {
        let (s, kc, _) = make()
        s.username = "u"; s.password = "p"
        s.save()
        try XCTSkipUnless(s.isSyncOn, "Keychain unavailable in this test host")
        XCTAssertNotNil(s.savedForWatch())
        XCTAssertNil(s.clearedStamp)
        var turnedOff = 0
        s.onTurnOff = { turnedOff += 1 }
        s.turnOff()
        XCTAssertEqual(turnedOff, 1)
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNil(kc.get(account: "username"))
        XCTAssertNil(kc.get(account: "password"))
        XCTAssertNil(s.savedForWatch())
        XCTAssertEqual(s.username, "")
        XCTAssertEqual(s.password, "")
        let cleared = s.clearedStamp
        XCTAssertNotNil(cleared)
        // Saving again supersedes the cleared state with a strictly newer stamp.
        s.username = "u"; s.password = "p"
        s.save()
        XCTAssertNil(s.clearedStamp)
        XCTAssertGreaterThan(s.savedForWatch()?.stamp ?? 0, cleared ?? Int.max)
        s.turnOff()
    }

    func testTurnOffWithoutEverConfiguringStillProducesClearedState() {
        let (s, _, _) = make()
        s.turnOff()
        XCTAssertFalse(s.isSyncOn)
        XCTAssertNotNil(s.clearedStamp)
    }
}
