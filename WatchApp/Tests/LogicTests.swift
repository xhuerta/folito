import XCTest
import ReaderCore
@testable import FolitoWatch

private func makeBook() -> ProcessedBook {
    // Chapter 0: blocks of 10, 20 chars; chapter 1: empty; chapter 2: one block of 70 chars.
    func b(_ n: Int, offset: Int) -> Block {
        Block(text: String(repeating: "x", count: n), xpointer: "/p\(offset)", globalOffset: offset)
    }
    return ProcessedBook(
        metadata: BookMetadata(title: "T", authors: ["A"]),
        documentHash: "h", metaHash: "m",
        chapters: [Chapter(spineIndex: 1, title: "One", blocks: [b(10, offset: 0), b(20, offset: 10)]),
                   Chapter(spineIndex: 2, title: nil, blocks: []),
                   Chapter(spineIndex: 3, title: nil, blocks: [b(70, offset: 30)])],
        totalCharacters: 100)
}

final class FlatBookTests: XCTestCase {
    func testFlatteningAndChapterRefs() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.count, 3)
        XCTAssertEqual(flat.chapterRefs.map(\.title), ["One", "Chapter 3"])
        XCTAssertEqual(flat.chapterRefs.map(\.startIndex), [0, 2])
    }

    func testPositionRoundTripAndClamping() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 0, blockIndex: 1)), 1)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 2, blockIndex: 0)), 2)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 0, blockIndex: 99)), 1)
        XCTAssertEqual(flat.flatIndex(for: BookPosition(chapterIndex: 9, blockIndex: 0)), 2)
        XCTAssertEqual(flat.position(at: 2), BookPosition(chapterIndex: 2, blockIndex: 0))
    }

    func testPercentage() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.percentage(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(flat.percentage(at: 1), 0.1, accuracy: 1e-9)
        XCTAssertEqual(flat.percentage(at: 2), 0.3, accuracy: 1e-9)
    }

    func testIndexForPercentage() {
        let flat = FlatBook(makeBook())
        XCTAssertEqual(flat.index(forPercentage: 0), 0)
        XCTAssertEqual(flat.index(forPercentage: 0.09), 0)
        XCTAssertEqual(flat.index(forPercentage: 0.1), 1)
        XCTAssertEqual(flat.index(forPercentage: 0.5), 2)
        XCTAssertEqual(flat.index(forPercentage: 1.5), 2)
    }
}

final class VisibleBlockResolverTests: XCTestCase {
    private func f(_ minY: CGFloat, _ maxY: CGFloat) -> BlockFrame { BlockFrame(minY: minY, maxY: maxY) }

    func testNoFramesMeansNoPosition() {
        XCTAssertNil(VisibleBlockResolver.topIndex(frames: [:]))
    }

    func testTopIsFirstBlockWhoseBottomIsBelowViewportTop() {
        // Blocks 3 and 4 are laid out above the viewport (lazy buffer), 5 is partly scrolled off.
        let frames = [3: f(-300, -200), 4: f(-190, -100), 5: f(-90, 40), 6: f(50, 120), 7: f(130, 400)]
        XCTAssertEqual(VisibleBlockResolver.topIndex(frames: frames), 5)
    }

    func testBlockJustTouchingTopEdgeIsNotCounted() {
        let frames = [1: f(-50, 2), 2: f(10, 90)]
        XCTAssertEqual(VisibleBlockResolver.topIndex(frames: frames), 2)
    }

    func testOnlyOffscreenFramesGiveNil() {
        XCTAssertNil(VisibleBlockResolver.topIndex(frames: [1: f(-100, -10)]))
    }
}

final class BlockTextTests: XCTestCase {
    func testRunsClampAndSkipInvalid() {
        let spans = [StyleSpan(location: 0, length: 3, bold: true, italic: false),
                     StyleSpan(location: 4, length: 100, bold: false, italic: true),
                     StyleSpan(location: 50, length: 2, bold: true, italic: false),
                     StyleSpan(location: 0, length: 2, bold: false, italic: false)]
        let runs = BlockText.runs(text: "abc defg", spans: spans)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(String("abc defg"[runs[0].range]), "abc")
        XCTAssertEqual(String("abc defg"[runs[1].range]), "defg")
    }

    func testUTF16RangesWithEmoji() {
        // "a😀b": emoji is 2 UTF-16 units; bold "b" is at UTF-16 location 3.
        let text = "a😀b"
        let runs = BlockText.runs(text: text, spans: [StyleSpan(location: 3, length: 1, bold: true, italic: false)])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(String(text[runs[0].range]), "b")
    }

    func testAttributedContainsIntent() {
        let attr = BlockText.attributed(text: "ab", spans: [StyleSpan(location: 0, length: 1, bold: true, italic: true)])
        let first = attr.runs.first
        XCTAssertEqual(first?.inlinePresentationIntent, [.stronglyEmphasized, .emphasized])
    }
}

final class SyncCoordinatorTests: XCTestCase {
    private final class Recorder: KOSyncClientProtocol, @unchecked Sendable {
        let lock = NSLock()
        var pushed: [KOSyncProgress] = []
        func authorize() async throws {}
        func createUser() async throws {}
        func fetchProgress(document: String) async throws -> KOSyncProgress? { nil }
        func pushProgress(_ p: KOSyncProgress) async throws { lock.lock(); pushed.append(p); lock.unlock() }
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test.\(UUID().uuidString)")! }

    private final class Spy: KOSyncClientProtocol, @unchecked Sendable {
        let lock = NSLock()
        private(set) var calls: [String] = []
        private func note(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
        func authorize() async throws { note("authorize") }
        func createUser() async throws { note("createUser") }
        func fetchProgress(document: String) async throws -> KOSyncProgress? { note("fetch"); return nil }
        func pushProgress(_ p: KOSyncProgress) async throws { note("push") }
    }

    /// Credentials that can be switched on and off while the coordinator lives.
    private final class Creds: @unchecked Sendable {
        let lock = NSLock()
        private var value: KOSyncCredentials?
        init(_ v: KOSyncCredentials?) { value = v }
        func get() -> KOSyncCredentials? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: KOSyncCredentials?) { lock.lock(); value = v; lock.unlock() }
    }

    @MainActor
    func testUnconfiguredNeverQueuesNorTouchesTheNetwork() async throws {
        let d = defaults()
        let spy = Spy()
        let made = Creds(nil) // reused as a counter-free flag: makeClient must never be called
        let sync = SyncCoordinator(defaults: d, credentials: { nil }, makeClient: { _ in
            made.set(KOSyncCredentials(username: "called", password: "x")); return spy })
        sync.report(document: "a", xpointer: "/p1", percentage: 0.1, immediately: true)
        sync.report(document: "b", xpointer: "/p2", percentage: 0.2, immediately: false)
        sync.retryPending()
        let decision = await sync.decisionOnOpen(document: "a", localPercentage: 0.3)
        XCTAssertEqual(decision, .keepLocal)
        let test = await sync.testConnection()
        XCTAssertEqual(test, .notConfigured)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(spy.calls, [])
        XCTAssertNil(made.get())
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertFalse(sync.hasPending)
        XCTAssertEqual(sync.status, .idle)
        XCTAssertFalse(sync.isConfigured)
        let snapshot = try await sync.queue.snapshot()
        XCTAssertEqual(try JSONDecoder().decode([PendingProgress].self, from: snapshot).count, 0)
        let stored = d.data(forKey: SyncCoordinator.queueKey).flatMap { try? JSONDecoder().decode([PendingProgress].self, from: $0) }
        XCTAssertTrue((stored ?? []).isEmpty)
    }

    @MainActor
    func testRemovingCredentialsClearsQueueAndStopsSync() async throws {
        let d = defaults()
        let spy = Spy()
        let creds = Creds(KOSyncCredentials(username: "u", password: "p"))
        var config = SyncQueue.Config(); config.debounce = 3600
        let sync = SyncCoordinator(defaults: d, config: config, credentials: { creds.get() }, makeClient: { _ in spy })
        XCTAssertTrue(sync.isConfigured)
        sync.report(document: "a", xpointer: "/p1", percentage: 0.1, immediately: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sync.pendingCount, 1)

        creds.set(nil)
        sync.configurationChanged()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(sync.isConfigured)
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertEqual(sync.status, .idle)
        let stored = d.data(forKey: SyncCoordinator.queueKey).flatMap { try? JSONDecoder().decode([PendingProgress].self, from: $0) }
        XCTAssertTrue((stored ?? []).isEmpty)

        let before = spy.calls
        sync.report(document: "a", xpointer: "/p2", percentage: 0.2, immediately: true)
        sync.retryPending()
        _ = await sync.decisionOnOpen(document: "a", localPercentage: 0.2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(spy.calls, before)
        XCTAssertEqual(sync.pendingCount, 0)
    }

    @MainActor
    func testCredentialsArrivingLaterEnableSync() async throws {
        let spy = Spy()
        let creds = Creds(nil)
        let sync = SyncCoordinator(defaults: defaults(), credentials: { creds.get() }, makeClient: { _ in spy })
        sync.report(document: "a", xpointer: "/p1", percentage: 0.1, immediately: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(spy.calls, [])
        creds.set(KOSyncCredentials(username: "u", password: "p"))
        sync.configurationChanged()
        XCTAssertTrue(sync.isConfigured)
        _ = await sync.decisionOnOpen(document: "a", localPercentage: 0.1)
        XCTAssertEqual(spy.calls, ["fetch"])
    }

    func testClearRequestDetection() {
        XCTAssertTrue(CredentialsStore.isClearRequest(["type": "settings", "sync_cleared": true, "settingsStamp": 9]))
        XCTAssertFalse(CredentialsStore.isClearRequest(["type": "settings", "sync_cleared": false]))
        XCTAssertFalse(CredentialsStore.isClearRequest(["type": "settings", "typography": "{}"]))
    }

    func testSyncSettingsAction() {
        typealias R = ConnectivityReceiver
        var creds: [String: Any] = ["type": "credentials", "settingsStamp": 9]
        creds.merge(SyncSettingsWire.encode(connectorID: "kosync", credentials: SyncCredentials(
            ["kosync_server": "https://s", "kosync_user": "u", "kosync_key": "5ebe2294ecd0e0f08eab7690d2a6ee69"]))) { _, n in n }
        XCTAssertEqual(R.syncSettingsAction(for: creds, lastApplied: 8), .store)
        XCTAssertEqual(R.syncSettingsAction(for: creds, lastApplied: 0), .store, "fresh install")
        XCTAssertEqual(R.syncSettingsAction(for: creds, lastApplied: 9), R.SyncSettingsAction.none, "a resend, or after Reset on the watch")
        let cleared: [String: Any] = ["type": "settings", "sync_cleared": true, "settingsStamp": 10, "settingsVersion": 1]
        XCTAssertEqual(R.syncSettingsAction(for: cleared, lastApplied: 9), .clear)
        XCTAssertEqual(R.syncSettingsAction(for: cleared, lastApplied: 10), R.SyncSettingsAction.none)
        // A turn-off that arrives after newer credentials (the two travel on different channels) is ignored.
        XCTAssertEqual(R.syncSettingsAction(for: cleared, lastApplied: 11), R.SyncSettingsAction.none)
        // Credentials are accepted only as a `credentials` message, never from the settings context.
        var inContext = creds
        inContext["type"] = "settings"
        XCTAssertEqual(R.syncSettingsAction(for: inContext, lastApplied: 0), R.SyncSettingsAction.none)
        var noStamp = creds
        noStamp["settingsStamp"] = nil
        XCTAssertEqual(R.syncSettingsAction(for: noStamp, lastApplied: 0), R.SyncSettingsAction.none)
        var future = creds
        future["settingsVersion"] = 99
        XCTAssertEqual(R.syncSettingsAction(for: future, lastApplied: 0), R.SyncSettingsAction.none)
        XCTAssertEqual(R.syncSettingsAction(for: ["type": "credentials", "settingsStamp": 9], lastApplied: 0), R.SyncSettingsAction.none)
        XCTAssertEqual(R.syncSettingsAction(for: ["type": "settings", "typography": "{}"], lastApplied: 0), R.SyncSettingsAction.none)
        XCTAssertEqual(R.syncSettingsAction(for: ["type": "delete_book", "documentHash": "a"], lastApplied: 0), R.SyncSettingsAction.none)
    }

    func testLibraryContextReportsTheAppliedSettingsStamp() {
        XCTAssertEqual(ConnectivityReceiver.libraryContext(hashes: [])["settingsStamp"] as? Int, 0)
        XCTAssertEqual(ConnectivityReceiver.libraryContext(hashes: ["a"], settingsStamp: 42)["settingsStamp"] as? Int, 42)
    }

    @MainActor
    func testImmediateReportIsPushedAndQueueEmptied() async throws {
        let rec = Recorder()
        let creds = KOSyncCredentials(username: "u", password: "p")
        let sync = SyncCoordinator(defaults: defaults(), credentials: { creds }, makeClient: { _ in rec })
        sync.report(document: "a", xpointer: "/p1", percentage: 0.1, immediately: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rec.pushed.map(\.document), ["a"])
        XCTAssertEqual(sync.pendingCount, 0)
    }

    /// Connector-neutral path (Readest-like connector without device ids): the open-time offer and the
    /// pushed position carry the full book identity and Folito's pagination.
    @MainActor
    func testConnectorReceivesBookIdentityAndPagination() async throws {
        final class Rec: SyncConnector, @unchecked Sendable {
            let lock = NSLock()
            var pushed: [(ReadingPosition, BookIdentity)] = []
            var descriptor: SyncConnectorDescriptor { ReadestConnectorFactory().descriptor }
            func authorize() async throws {}
            func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
                ReadingPosition(xpointer: "/body/DocFragment[2]/body/p", percentage: 0.6)
            }
            func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
                lock.lock(); pushed.append((position, book)); lock.unlock()
            }
        }
        let rec = Rec()
        let sync = SyncCoordinator(defaults: defaults(), connector: { rec })
        let book = BookIdentity(partialMD5: "abc", metaHash: "meta", title: "T", authors: ["A"])
        let decision = await sync.decisionOnOpen(book: book, localPercentage: 0.1)
        guard case .offerRemote(let remote) = decision else { return XCTFail("expected an offer") }
        XCTAssertEqual(remote.percentage, 0.6)
        sync.report(book: book, xpointer: "/body/p", percentage: 0.3, page: 3, pageCount: 10, immediately: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        let pushed = rec.lock.withLock { rec.pushed }
        XCTAssertEqual(pushed.first?.1, book)
        XCTAssertEqual(pushed.first?.0.page, 3)
        XCTAssertEqual(pushed.first?.0.pageCount, 10)
        XCTAssertEqual(pushed.first?.0.deviceID, sync.device.id)
        let test = await sync.testConnection()
        XCTAssertEqual(test, .ok)
    }

}

final class MiscLogicTests: XCTestCase {
    func testFontSizeClamp() {
        XCTAssertEqual(ReaderSettings.clampFontSize(2), ReaderSettings.minFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(99), ReaderSettings.maxFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(.nan), ReaderSettings.defaultFontSize)
    }

    func testErrorClassification() {
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.offline), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.unauthorized), .error)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.badServerResponse)), .error)
    }

    func testDeleteMessageSchema() {
        // Shape sent by the iPhone (WatchSchema.deleteBook).
        XCTAssertEqual(ConnectivityReceiver.deleteHash(from: ["type": "delete_book", "documentHash": "abc"]), "abc")
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["delete_book": "abc"]))
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "settings", "documentHash": "abc"]))
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "delete_book"]))
    }

    func testDictionaryMessageSchema() {
        // Shapes sent by the iPhone (WatchSchema.dictionaryMetadata / deleteDictionary).
        let sha = String(repeating: "ab", count: 32)
        let t = ConnectivityReceiver.dictionaryTransfer(from: ["type": "dictionary", "dictionaryId": "readerdict-en",
                                                              "sha256": sha, "size": NSNumber(value: 1234)])
        XCTAssertEqual(t?.id, "readerdict-en")
        XCTAssertEqual(t?.sha256, sha)
        XCTAssertEqual(t?.size, 1234)
        XCTAssertNil(ConnectivityReceiver.dictionaryTransfer(from: nil))
        XCTAssertNil(ConnectivityReceiver.dictionaryTransfer(from: ["type": "book", "documentHash": "abc"]), "books are not dictionaries")
        XCTAssertNil(ConnectivityReceiver.dictionaryTransfer(from: ["type": "dictionary", "dictionaryId": "x", "sha256": "short", "size": 1]))
        XCTAssertNil(ConnectivityReceiver.dictionaryTransfer(from: ["type": "dictionary", "dictionaryId": "x", "sha256": sha]))
        XCTAssertEqual(ConnectivityReceiver.deleteDictionaryId(from: ["type": "delete_dictionary", "dictionaryId": "x"]), "x")
        XCTAssertNil(ConnectivityReceiver.deleteDictionaryId(from: ["type": "delete_book", "dictionaryId": "x"]))
        XCTAssertNil(ConnectivityReceiver.deleteDictionaryId(from: ["type": "delete_dictionary"]))
    }

    func testSettingsStampPolicy() {
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: nil, lastApplied: 50))
        XCTAssertTrue(ConnectivityReceiver.shouldApplySettings(incomingStamp: 51, lastApplied: 50))
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: 50, lastApplied: 50))
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: 10, lastApplied: 50))
    }

    func testLibraryContext() {
        let c = ConnectivityReceiver.libraryContext(hashes: ["b", "a"])
        XCTAssertEqual(c["type"] as? String, "library")
        XCTAssertEqual(c["hashes"] as? [String], ["a", "b"])
        XCTAssertEqual(c["dictionaries"] as? [String], [])
        let d = ConnectivityReceiver.libraryContext(hashes: [], dictionaries: ["readerdict-fr", "readerdict-en"])
        XCTAssertEqual(d["dictionaries"] as? [String], ["readerdict-en", "readerdict-fr"])
        XCTAssertEqual(c["removed"] as? [String], [])
        XCTAssertNil(c["watchID"])
        let r = ConnectivityReceiver.libraryContext(hashes: ["a"], removed: ["z", "y"], watchID: "W")
        XCTAssertEqual(r["removed"] as? [String], ["y", "z"])
        XCTAssertEqual(r["watchID"] as? String, "W")
    }

    func testUserRemovedBooksList() {
        XCTAssertEqual(ConnectivityReceiver.userRemoved([], adding: "a", stored: []), ["a"])
        // No duplicates; a book sent to the watch again is no longer "removed".
        XCTAssertEqual(ConnectivityReceiver.userRemoved(["a", "b"], adding: "a", stored: ["b"]), ["a"])
        let many = (0..<600).map(String.init)
        XCTAssertEqual(ConnectivityReceiver.userRemoved(many, stored: []).count, ConnectivityReceiver.maxRemembered)
        let message = ConnectivityReceiver.bookRemovedMessage(hash: "h", watchID: "W")
        XCTAssertEqual(message["type"] as? String, "book_removed")
        XCTAssertEqual(message["documentHash"] as? String, "h")
        XCTAssertEqual(message["watchID"] as? String, "W")
        let defaults = UserDefaults(suiteName: "watchID-\(UUID().uuidString)")!
        XCTAssertEqual(ConnectivityReceiver.watchID(in: defaults), ConnectivityReceiver.watchID(in: defaults))
    }

    func testLibraryContextCarriesTimeRemainingOfStoredBooks() {
        func t(_ hash: String, _ seconds: TimeInterval) -> ReadingTimeRemaining {
            ReadingTimeRemaining(documentHash: hash, bookTitle: hash, chapterSeconds: 60, bookSeconds: seconds,
                                 fractionRead: 0.5, updatedAt: Date())
        }
        let c = ConnectivityReceiver.libraryContext(hashes: ["a"], timeRemaining: ["a": t("a", 125), "gone": t("gone", 60)])
        XCTAssertEqual(c["timeRemaining"] as? [String: Double], ["a": 180])
        XCTAssertNil(ConnectivityReceiver.libraryContext(hashes: ["a"])["timeRemaining"])
    }

    func testLibraryContextCarriesProgressOfOpenedBooks() {
        let c = ConnectivityReceiver.libraryContext(hashes: ["a", "b"], progress: ["a": 0.434, "b": 0, "gone": 0.5])
        XCTAssertEqual(c["progress"] as? [String: Int], ["a": 43])
        XCTAssertNil(ConnectivityReceiver.libraryContext(hashes: ["a"])["progress"])
    }

    func testBookCoverMessage() {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let parsed = ConnectivityReceiver.bookCover(from: ["type": "book_cover", "documentHash": "h", "cover": jpeg])
        XCTAssertEqual(parsed?.hash, "h")
        XCTAssertEqual(parsed?.cover, jpeg)
        XCTAssertNil(ConnectivityReceiver.bookCover(from: ["type": "book_cover", "documentHash": "h"]))
        XCTAssertNil(ConnectivityReceiver.cover(from: ["cover": Data(count: BookStorage.maxCoverBytes + 1)]))
        XCTAssertEqual(ConnectivityReceiver.cover(from: ["documentHash": "h", "cover": jpeg]), jpeg)
    }

    func testCoverStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookStorage(root: root)
        XCTAssertTrue(storage.saveCover(Data([1, 2, 3]), documentHash: "a/b"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.coverURL("a/b").path))
        XCTAssertFalse(storage.saveCover(Data(), documentHash: "a/b"))
        storage.delete(documentHash: "a/b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.coverURL("a/b").path))
    }

    func testSafeName() {
        XCTAssertEqual(BookStorage.safeName("ab12/../x"), "ab12____x")
    }

    func testBookCompressionRoundTrip() throws {
        let book = makeBook()
        let json = try JSONEncoder().encode(book)
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        XCTAssertEqual(try BookStorage.decode(compressed: compressed), book)
    }
}

/// Issue #105: reopening a book restores the exact block and never offers this watch's own progress.
final class ReopenPositionTests: XCTestCase {
    private func f(_ minY: CGFloat, _ maxY: CGFloat) -> BlockFrame { BlockFrame(minY: minY, maxY: maxY) }

    private func suite() -> (UserDefaults, String) {
        let name = "ReopenPositionTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// `crengine: true` gives the blocks real KOReader/crengine XPointers (`/body/DocFragment[1]/body/p[n]`)
    /// that `XPointerResolver` can resolve; the short `/body/p[n]` form does not parse, so a remote position
    /// in that form only ever resolves through its percentage.
    private func book(_ hash: String = "h", crengine: Bool = false) -> ProcessedBook {
        let base = crengine ? "/body/DocFragment[1]/body" : "/body"
        let blocks = (0..<100).map { Block(text: String(repeating: "x", count: 10), xpointer: "\(base)/p[\($0 + 1)]",
                                           globalOffset: $0 * 10) }
        return ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: hash, metaHash: "",
                             chapters: [Chapter(spineIndex: 1, title: nil, blocks: blocks)], totalCharacters: 1_000)
    }

    func testViewportTopSkipsBlocksUnderTheNavigationBar() {
        // Block 4 is still partly on screen, but only under a 30 pt navigation bar.
        let frames = [4: f(-20, 25), 5: f(30, 90)]
        XCTAssertEqual(VisibleBlockResolver.topIndex(frames: frames), 4)
        XCTAssertEqual(VisibleBlockResolver.topIndex(frames: frames, viewportTop: 30), 5)
    }

    func testRestoreCheck() {
        XCTAssertTrue(RestoreCheck.needsRetry(top: nil, target: 3, attempts: 0))
        XCTAssertTrue(RestoreCheck.needsRetry(top: 1, target: 3, attempts: 0))
        XCTAssertFalse(RestoreCheck.needsRetry(top: 3, target: 3, attempts: 0))
        XCTAssertFalse(RestoreCheck.needsRetry(top: 1, target: 3, attempts: RestoreCheck.maxRetries))
    }

    /// The first jump lands a few blocks off (lazy layout): it is re-issued, and the wrong landing block
    /// never replaces the saved position.
    @MainActor
    func testReopenRestoresTheSavedBlockEvenWhenTheFirstJumpLandsOff() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let positions = PositionStore(defaults: defaults)
        let sync = SyncCoordinator(defaults: defaults, credentials: { nil })
        let first = ReaderViewModel(book: book(), positions: positions, sync: sync)
        first.settleDelay = 10_000_000
        first.openSettleDelay = 10_000_000
        first.restoreInitialPosition()
        try await Task.sleep(nanoseconds: 300_000_000)
        first.blockFramesChanged([41: f(-10, 3), 42: f(3, 60)])
        XCTAssertEqual(first.currentIndex, 42)
        first.leave()

        let reopened = ReaderViewModel(book: book(), positions: positions, sync: sync)
        reopened.settleDelay = 30_000_000
        reopened.openSettleDelay = 30_000_000
        XCTAssertEqual(reopened.startIndex, 42)
        reopened.restoreInitialPosition()
        let firstJump = try XCTUnwrap(reopened.jumpRequest)
        reopened.blockFramesChanged([38: f(0, 60), 39: f(60, 120)])
        try await Task.sleep(nanoseconds: 60_000_000)
        let retry = try XCTUnwrap(reopened.jumpRequest)
        XCTAssertNotEqual(retry, firstJump, "the jump is re-issued")
        XCTAssertEqual(retry.index, 42)
        XCTAssertEqual(reopened.currentIndex, 42)
        reopened.blockFramesChanged([42: f(0, 60), 43: f(60, 120)])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ReaderViewModel(book: book(), positions: positions, sync: sync).startIndex, 42)
        // Restoring is over: scrolling moves the position again.
        reopened.blockFramesChanged([43: f(0, 60)])
        XCTAssertEqual(reopened.currentIndex, 43)
    }

    /// A Readest-like service: stores what is pushed, returns it without a device id and with the
    /// percentage rebuilt from `page / pageCount`.
    private final class EchoService: SyncConnector, @unchecked Sendable {
        let lock = NSLock()
        var stored: ReadingPosition?
        var descriptor: SyncConnectorDescriptor { ReadestConnectorFactory().descriptor }
        func authorize() async throws {}
        func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
            lock.lock(); defer { lock.unlock() }
            guard var p = stored else { return nil }
            p.deviceID = ""; p.deviceName = ""
            if let page = p.page, let count = p.pageCount { p.percentage = Double(page) / Double(count) }
            return p
        }
        func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {
            lock.lock(); stored = position; lock.unlock()
        }
    }

    @MainActor
    func testOwnProgressRoundTripsWithoutAPrompt() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = EchoService()
        let sync = SyncCoordinator(defaults: defaults, connector: { service })
        let book = BookIdentity(partialMD5: "h")
        let local = ReadingPosition(xpointer: "/body/p[1]", percentage: 0, page: 1, pageCount: 100)
        sync.report(book: book, xpointer: local.xpointer, percentage: 0, page: 1, pageCount: 100, immediately: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(sync.ownProgress.lastPushed(connectorID: "readest", bookKey: "h")?.xpointer, "/body/p[1]")
        let own = await sync.decisionOnOpen(book: book, local: local)
        XCTAssertEqual(own, .keepLocal)
        // Moved back afterwards without pushing: the old own position is still not offered.
        let back = ReadingPosition(xpointer: "/body/p[1]", percentage: 0, page: 1, pageCount: 100)
        service.lock.withLock { service.stored = ReadingPosition(xpointer: "/body/p[50]", percentage: 0.49,
                                                                 page: 50, pageCount: 100) }
        sync.ownProgress.record(ReadingPosition(xpointer: "/body/p[50]", percentage: 0.49, page: 50, pageCount: 100),
                                connectorID: "readest", bookKey: "h")
        let afterMovingBack = await sync.decisionOnOpen(book: book, local: back)
        XCTAssertEqual(afterMovingBack, .keepLocal)
    }

    @MainActor
    func testADifferentDevicesPositionStillPrompts() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = EchoService()
        let sync = SyncCoordinator(defaults: defaults, connector: { service })
        let book = BookIdentity(partialMD5: "h")
        sync.report(book: book, xpointer: "/body/p[1]", percentage: 0, page: 1, pageCount: 100, immediately: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        service.lock.withLock { service.stored = ReadingPosition(xpointer: "/body/DocFragment[3]/body/p[7]",
                                                                 percentage: 0.4, page: 120, pageCount: 300) }
        let local = ReadingPosition(xpointer: "/body/p[1]", percentage: 0, page: 1, pageCount: 100)
        let decision = await sync.decisionOnOpen(book: book, local: local)
        guard case .offerRemote(let remote) = decision else {
            return XCTFail("another device's position must be offered")
        }
        XCTAssertEqual(remote.page, 120)
    }

    // MARK: Forward-only sync (#112)

    @MainActor
    func testRemoteAheadPromptsAndRemoteBehindStaysSilent() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = EchoService()
        let sync = SyncCoordinator(defaults: defaults, connector: { service })
        let book = BookIdentity(partialMD5: "h")
        let local = ReadingPosition(xpointer: "/body/p[50]", percentage: 0.49, page: 50, pageCount: 100)
        // Another device is further on: "Continue where you left off?".
        service.lock.withLock { service.stored = ReadingPosition(xpointer: "/body/p[80]", percentage: 0.79,
                                                                 page: 80, pageCount: 100) }
        guard case .offerRemote(let ahead) = await sync.decisionOnOpen(book: book, local: local) else {
            return XCTFail("a remote position ahead must be offered")
        }
        XCTAssertEqual(ahead.page, 80)
        // Another device is behind: no prompt, the local position stays.
        service.lock.withLock { service.stored = ReadingPosition(xpointer: "/body/p[20]", percentage: 0.19,
                                                                 page: 20, pageCount: 100) }
        let behind = await sync.decisionOnOpen(book: book, local: local)
        XCTAssertEqual(behind, .keepLocal)
    }

    @MainActor
    func testGoToSyncedPositionJumpsEvenWhenBehind() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = EchoService()
        let sync = SyncCoordinator(defaults: defaults, connector: { service })
        let model = ReaderViewModel(book: book(crengine: true), positions: PositionStore(defaults: defaults), sync: sync)
        XCTAssertTrue(model.canGoToSyncedPosition)
        model.jump(to: 60)
        // Nothing on the service yet: no jump.
        let nothing = await model.goToSyncedPosition()
        XCTAssertEqual(nothing, .noPosition)
        XCTAssertEqual(model.currentIndex, 60)
        // A position behind the local one: not offered on open, but the menu item still goes there.
        // `p[21]` is block 20 (XPath is 1-based, and `page` is `index + 1` as ReaderViewModel reports it).
        // The XPointer must resolve: the Readest-like service rebuilds the percentage as page / pageCount
        // (0.21, the end of block 20), so a percentage-only fallback would land on the start of block 21.
        service.lock.withLock { service.stored = ReadingPosition(xpointer: "/body/DocFragment[1]/body/p[21]",
                                                                 percentage: 0.2, page: 21, pageCount: 100) }
        let open = await sync.decisionOnOpen(book: BookIdentity(partialMD5: "h"), local: model.localPosition)
        XCTAssertEqual(open, .keepLocal)
        let jumped = await model.goToSyncedPosition()
        XCTAssertEqual(jumped, .jumped)
        XCTAssertEqual(model.currentIndex, 20)
        XCTAssertEqual(model.jumpRequest?.index, 20)
    }

    @MainActor
    func testGoToSyncedPositionIsHiddenWhenSyncIsOff() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let sync = SyncCoordinator(defaults: defaults, credentials: { nil })
        let model = ReaderViewModel(book: book(), positions: PositionStore(defaults: defaults), sync: sync)
        XCTAssertFalse(model.canGoToSyncedPosition)
        let result = await model.goToSyncedPosition()
        XCTAssertEqual(result, .noPosition)
        XCTAssertEqual(model.currentIndex, 0)
    }
}

/// Position inside a block (#108).
final class InBlockReaderTests: XCTestCase {
    private func book() -> ProcessedBook {
        let long = String(repeating: "word ", count: 40)   // 200 characters
        let chapters = [Chapter(spineIndex: 1, title: "One",
                                blocks: [Block(text: long, xpointer: "/body/DocFragment[1]/body/p", globalOffset: 0),
                                         Block(text: long, xpointer: "/body/DocFragment[1]/body/p[2]", globalOffset: 200)])]
        return ProcessedBook(metadata: BookMetadata(title: "Book", authors: []), documentHash: "inblock",
                             metaHash: "", chapters: chapters, totalCharacters: 400)
    }

    func testFlatPositionCarriesAClampedOffset() {
        let flat = FlatBook(book())
        XCTAssertEqual(flat.position(at: 1, characterOffset: 55), BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 55))
        XCTAssertEqual(flat.position(at: 1, characterOffset: 999)?.characterOffset, 200)
        XCTAssertEqual(flat.position(at: 1, characterOffset: -3)?.characterOffset, 0)
    }

    func testInBlockRetryOnlyWhenOffByMoreThanTheTolerance() {
        XCTAssertFalse(RestoreCheck.needsInBlockRetry(landedMinY: -100, wantedMinY: -104, attempts: 0))
        XCTAssertTrue(RestoreCheck.needsInBlockRetry(landedMinY: -100, wantedMinY: -130, attempts: 0))
        XCTAssertFalse(RestoreCheck.needsInBlockRetry(landedMinY: -100, wantedMinY: -130, attempts: RestoreCheck.maxRetries))
    }

    @MainActor
    func testOffsetIsSavedRestoredAndSynced() {
        let defaults = UserDefaults(suiteName: "InBlockReaderTests.\(UUID().uuidString)")!
        let positions = PositionStore(defaults: defaults)
        let sync = SyncCoordinator(defaults: defaults, credentials: { nil })
        let model = ReaderViewModel(book: book(), positions: positions, sync: sync, settings: defaults)
        model.jump(to: 1, characterOffset: 50)
        XCTAssertEqual(positions.load("inblock")?.position, BookPosition(chapterIndex: 0, blockIndex: 1, characterOffset: 50))
        XCTAssertEqual(model.localPercentage, 250.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(model.localPosition.xpointer, "/body/DocFragment[1]/body/p[2]/text().50")
        let reopened = ReaderViewModel(book: book(), positions: positions, sync: sync, settings: defaults)
        XCTAssertEqual(reopened.startIndex, 1)
        XCTAssertEqual(reopened.startOffset, 50)
    }

    private func f(_ minY: CGFloat, _ maxY: CGFloat) -> BlockFrame { BlockFrame(minY: minY, maxY: maxY) }

    /// Where a book opens (#125): computed once, before the first render, from the saved position.
    func testOpenPosition() {
        let flat = FlatBook(book())
        func open(_ block: Int, _ offset: Int, chapter: Int = 0) -> (index: Int, offset: Int) {
            ReaderViewModel.openPosition(saved: StoredPosition(position: BookPosition(chapterIndex: chapter, blockIndex: block,
                                                                                      characterOffset: offset),
                                                               percentage: 0.5), in: flat)
        }
        let none = ReaderViewModel.openPosition(saved: nil, in: flat)
        XCTAssertEqual(none.index, 0)
        XCTAssertEqual(none.offset, 0)
        XCTAssertEqual(open(1, 50).index, 1)
        XCTAssertEqual(open(1, 50).offset, 50)
        XCTAssertEqual(open(1, 999).offset, 200, "the offset is clamped to the block's text")
        // A block past the end of the chapter is clamped to its last block, at that block's top.
        XCTAssertEqual(open(7, 50).index, 1)
        XCTAssertEqual(open(7, 50).offset, 0)
        XCTAssertEqual(open(0, 0, chapter: 5).index, 0, "an out-of-range chapter is clamped")
    }

    /// Reopening at a line inside a block (#125): the text stays transparent while the reader scrolls to
    /// the block and then to the line, and appears once the line is at the top edge, so nothing moves on
    /// screen after the first visible frame. The saved position is the line, not the block's top.
    @MainActor
    func testOpeningKeepsTheTextHiddenUntilTheSavedLineIsAtTheTop() async throws {
        let defaults = UserDefaults(suiteName: "InBlockReaderTests.\(UUID().uuidString)")!
        let positions = PositionStore(defaults: defaults)
        let sync = SyncCoordinator(defaults: defaults, credentials: { nil })
        ReaderViewModel(book: book(), positions: positions, sync: sync, settings: defaults).jump(to: 1, characterOffset: 100)

        let model = ReaderViewModel(book: book(), positions: positions, sync: sync, settings: defaults)
        model.openSettleDelay = 30_000_000
        model.viewportHeight = 200
        XCTAssertFalse(model.isPositioned)
        model.restoreInitialPosition()
        XCTAssertTrue(model.isRestoring, "the opening scroll is programmatic: the bar must not hide")
        let first = try XCTUnwrap(model.jumpRequest)
        XCTAssertEqual(first.index, 1)
        model.blockFramesChanged([1: f(0, 400)]) // the block's top at the top edge, the line not yet
        try await Task.sleep(nanoseconds: 90_000_000)
        let inBlock = try XCTUnwrap(model.jumpRequest)
        XCTAssertNotEqual(inBlock, first)
        XCTAssertNotNil(inBlock.anchorY, "the second scroll brings the saved line to the top edge")
        XCTAssertFalse(model.isPositioned, "the text is still hidden between the two scrolls")

        let wanted = InBlockPosition.wantedMinY(fraction: InBlockPosition.fraction(forCharacterOffset: 100,
                                                                                    in: model.flat.blocks[1].text),
                                                blockHeight: 400, viewportTop: 0)
        model.blockFramesChanged([1: f(CGFloat(wanted), CGFloat(wanted) + 400)])
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(model.isPositioned, "the text appears once the saved line is at the top")
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.currentOffset, 100, "the saved line, not the block's top, is the position")
    }

    /// A jump to a block that is laid out already carries the in-block anchor (#125): one scroll, no
    /// second correction that moves the text again a moment later.
    @MainActor
    func testJumpToALaidOutBlockScrollsOnce() throws {
        let defaults = UserDefaults(suiteName: "InBlockReaderTests.\(UUID().uuidString)")!
        let model = ReaderViewModel(book: book(), positions: PositionStore(defaults: defaults),
                                    sync: SyncCoordinator(defaults: defaults, credentials: { nil }), settings: defaults)
        model.viewportHeight = 200
        model.blockFramesChanged([0: f(0, 400), 1: f(410, 810)])
        model.jump(to: 1, characterOffset: 100)
        let anchor = try XCTUnwrap(model.jumpRequest?.anchorY)
        let expected = try XCTUnwrap(InBlockPosition.anchorY(fraction: 0.5, blockHeight: 400, viewportHeight: 200,
                                                             viewportTop: 0))
        XCTAssertEqual(anchor, expected, accuracy: 1e-9)
        // Without an offset (or a block that is not laid out) the jump goes to the block's top.
        model.jump(to: 1)
        XCTAssertNil(model.jumpRequest?.anchorY)
    }

    @MainActor
    func testBlockOnlyPositionReopensAtOffsetZero() throws {
        let defaults = UserDefaults(suiteName: "InBlockReaderTests.\(UUID().uuidString)")!
        defaults.set(Data(#"{"position":{"chapterIndex":0,"blockIndex":1},"percentage":0.5}"#.utf8),
                     forKey: "position.inblock")
        let model = ReaderViewModel(book: book(), positions: PositionStore(defaults: defaults),
                                    sync: SyncCoordinator(defaults: defaults, credentials: { nil }), settings: defaults)
        XCTAssertEqual(model.startIndex, 1)
        XCTAssertEqual(model.startOffset, 0)
        XCTAssertEqual(model.localPosition.xpointer, "/body/DocFragment[1]/body/p[2]")
    }
}
