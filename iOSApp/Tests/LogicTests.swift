import XCTest
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
        XCTAssertEqual(cleared?["sync_cleared"] as? Bool, true)
        // Never configured: nothing is sent at all.
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, clearedStamp: nil, typography: nil))
        XCTAssertNil(WatchSchema.settingsContext(kosync: nil, clearedStamp: 0, typography: nil))
    }

    func testGenericConnectorSettingsSchema() {
        let readest = SyncCredentials([ReadestConnectorFactory.Key.email: "a@b.c",
                                       ReadestConnectorFactory.Key.session: "{}"])
        let info = WatchSchema.settingsContext(sync: (connectorID: "readest", credentials: readest, stamp: 3),
                                               typography: nil)
        XCTAssertEqual(info?["sync_connector"] as? String, "readest")
        XCTAssertEqual(info?["settingsVersion"] as? Int, 2)
        XCTAssertEqual(info?["settingsStamp"] as? Int, 3)
        XCTAssertNil(info?["kosync_user"], "KOSync legacy keys only for KOSync")
        XCTAssertEqual(SyncSettingsWire.decode(info ?? [:])?.1, readest)
        // KOSync also carries the legacy keys for watch builds from before connectors.
        let kosync = WatchSchema.settingsContext(kosync: ("s", "u", "p", 5), typography: nil)
        XCTAssertEqual(kosync?["sync_connector"] as? String, "kosync")
        XCTAssertEqual(kosync?["kosync_password"] as? String, "p")
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

    func testLegacyKeychainLoginIsMigratedToKOSyncConnector() throws {
        let kc = KeychainStore(service: "test.folito.\(UUID().uuidString)")
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        do { try kc.set("https://sync.example.org", account: "server"); try kc.set("bob", account: "username")
             try kc.set("pw", account: "password") } catch { throw XCTSkip("Keychain unavailable in this test host") }
        let s = SyncSettings(keychain: kc, defaults: d, clientFactory: { _ in MockKOSyncClient() })
        XCTAssertEqual(s.activeConnectorID, KOSyncConnectorFactory.id)
        XCTAssertEqual(s.username, "bob")
        XCTAssertNil(kc.get(account: "username"))
        XCTAssertEqual(kc.get(account: KOSyncConnectorFactory.Key.password), "pw")
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
