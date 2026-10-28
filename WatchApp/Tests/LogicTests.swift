import XCTest
import ReaderCore
@testable import WristReaderWatch

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
        XCTAssertTrue(CredentialsStore.isClearRequest(["type": "settings", "kosync_cleared": true, "settingsStamp": 9]))
        XCTAssertFalse(CredentialsStore.isClearRequest(["type": "settings", "kosync_cleared": false]))
        XCTAssertFalse(CredentialsStore.isClearRequest(["type": "settings", "kosync_user": "u"]))
        XCTAssertTrue(ConnectivityReceiver.shouldApplySettings(incomingStamp: 9, lastApplied: 8))
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: 8, lastApplied: 8))
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

    @MainActor
    func testLegacyPendingStoreIsMigrated() async throws {
        let d = defaults()
        let legacy = ["a": KOSyncProgress(document: "a", progress: "/p", percentage: 0.4, device_id: "d", timestamp: 1)]
        d.set(try JSONEncoder().encode(legacy), forKey: SyncCoordinator.legacyKey)
        let creds = KOSyncCredentials(username: "u", password: "p")
        let rec = Recorder()
        var config = SyncQueue.Config(); config.debounce = 3600
        // With credentials the coordinator moves the legacy entries into the queue and resumes it at once,
        // so the migrated position is delivered (debounce only applies to new reports).
        let sync = SyncCoordinator(defaults: d, config: config, credentials: { creds }, makeClient: { _ in rec })
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(d.data(forKey: SyncCoordinator.legacyKey))
        XCTAssertEqual(rec.lock.withLock { rec.pushed.map(\.document) }, ["a"])
        XCTAssertEqual(sync.pendingCount, 0)
    }

    @MainActor
    func testLegacyPendingStoreIsDroppedWhenUnconfigured() async throws {
        let d = defaults()
        let legacy = ["a": KOSyncProgress(document: "a", progress: "/p", percentage: 0.4, device_id: "d", timestamp: 1)]
        d.set(try JSONEncoder().encode(legacy), forKey: SyncCoordinator.legacyKey)
        let rec = Recorder()
        let sync = SyncCoordinator(defaults: d, credentials: { nil }, makeClient: { _ in rec })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(d.data(forKey: SyncCoordinator.legacyKey))
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertTrue(rec.lock.withLock { rec.pushed.isEmpty })
    }
}

final class MiscLogicTests: XCTestCase {
    func testFontSizeClamp() {
        XCTAssertEqual(ReaderSettings.clampFontSize(2), ReaderSettings.minFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(99), ReaderSettings.maxFontSize)
        XCTAssertEqual(ReaderSettings.clampFontSize(.nan), ReaderSettings.defaultFontSize)
    }

    func testServerURLParsing() {
        XCTAssertEqual(ServerURL.parse("sync.example.org")?.absoluteString, "https://sync.example.org")
        XCTAssertEqual(ServerURL.parse("http://10.0.0.2:8080")?.port, 8080)
        XCTAssertNil(ServerURL.parse("   "))
        XCTAssertNil(ServerURL.credentials(server: "x.org", user: "u", password: nil))
        XCTAssertEqual(ServerURL.credentials(server: "", user: "u", password: "p")?.username, "u")
    }

    func testErrorClassification() {
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.offline), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: KOSyncError.unauthorized), .error)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(SyncErrorClassifier.status(for: URLError(.badServerResponse)), .error)
    }

    func testDeleteMessageSchema() {
        // Shape sent by the iPhone (WatchSchema.deleteBook) and the legacy shape.
        XCTAssertEqual(ConnectivityReceiver.deleteHash(from: ["type": "delete_book", "documentHash": "abc"]), "abc")
        XCTAssertEqual(ConnectivityReceiver.deleteHash(from: ["delete_book": "abc"]), "abc")
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "settings", "documentHash": "abc"]))
        XCTAssertNil(ConnectivityReceiver.deleteHash(from: ["type": "delete_book"]))
    }

    func testSettingsStampPolicy() {
        XCTAssertTrue(ConnectivityReceiver.shouldApplySettings(incomingStamp: nil, lastApplied: 50))
        XCTAssertTrue(ConnectivityReceiver.shouldApplySettings(incomingStamp: 51, lastApplied: 50))
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: 50, lastApplied: 50))
        XCTAssertFalse(ConnectivityReceiver.shouldApplySettings(incomingStamp: 10, lastApplied: 50))
    }

    func testLibraryContext() {
        let c = ConnectivityReceiver.libraryContext(hashes: ["b", "a"])
        XCTAssertEqual(c["type"] as? String, "library")
        XCTAssertEqual(c["hashes"] as? [String], ["a", "b"])
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
