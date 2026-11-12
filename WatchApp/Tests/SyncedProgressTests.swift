import XCTest
import ReaderCore
@testable import FolitoWatch

/// A newer synced position in the complications and the Library, and declined offers (#132).
final class SyncedProgressTests: XCTestCase {
    /// Readest-like: returns `stored` without a device id, counts requests, can fail.
    private final class MockService: SyncConnector, @unchecked Sendable {
        let lock = NSLock()
        var stored: ReadingPosition?
        var fails = false
        var fetches = 0
        var descriptor: SyncConnectorDescriptor { ReadestConnectorFactory().descriptor }
        func authorize() async throws {}
        func fetchProgress(for book: BookIdentity) async throws -> ReadingPosition? {
            try lock.withLock {
                fetches += 1
                if fails { throw URLError(.notConnectedToInternet) }
                return stored
            }
        }
        func pushProgress(_ position: ReadingPosition, for book: BookIdentity) async throws {}
    }

    private final class Box: @unchecked Sendable { var service: MockService? }

    private struct Rig {
        let defaults: UserDefaults
        let name: String
        let service: MockService
        let box: Box
        let sync: SyncCoordinator
        let store: ReadingSnapshotStore
        let publisher: ComplicationPublisher
        let refresher: SyncedProgressRefresher
        let reloads: () -> Int
        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }

    /// The complications show book "h" at 40 %.
    @MainActor
    private func rig(now: @escaping () -> Date = { Date() }) -> Rig {
        let name = "SyncedProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let service = MockService()
        let box = Box()
        box.service = service
        let sync = SyncCoordinator(defaults: defaults, connector: { box.service })
        let store = ReadingSnapshotStore(defaults: defaults)
        var count = 0
        let publisher = ComplicationPublisher(store: store,
                                              localStore: ReadingSnapshotStore(defaults: defaults, key: "local"),
                                              reload: { count += 1 })
        publisher.publish(ReadingSnapshot(bookID: "h", title: "T", chapterTitle: "Ch 4", fraction: 0.4,
                                          minutesLeft: 7))
        let refresher = SyncedProgressRefresher(sync: sync, complications: publisher,
                                                positions: PositionStore(defaults: defaults), now: now)
        return Rig(defaults: defaults, name: name, service: service, box: box, sync: sync, store: store,
                   publisher: publisher, refresher: refresher, reloads: { count })
    }

    private func remote(_ fraction: Double, xp: String = "/body/p[80]", at seconds: TimeInterval = 100) -> ReadingPosition {
        ReadingPosition(xpointer: xp, percentage: fraction, chapter: "Ch 8", timestamp: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Snapshot merge

    func testMergeShowsOnlyAPositionAhead() {
        let local = ReadingSnapshot(bookID: "h", title: "T", chapterTitle: "Ch 4", fraction: 0.4, minutesLeft: 7)
        let ahead = ComplicationPublisher.merged(local, synced: remote(0.8))
        XCTAssertEqual(ahead.fraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(ahead.chapterTitle, "Ch 8")
        XCTAssertNil(ahead.minutesLeft, "minutes left belong to the local position")
        XCTAssertEqual(ComplicationPublisher.merged(local, synced: remote(0.2)), local)
        XCTAssertEqual(ComplicationPublisher.merged(local, synced: remote(0.403)), local, "within the tolerance")
        XCTAssertEqual(ComplicationPublisher.merged(local, synced: nil), local)
    }

    // MARK: Refresh

    @MainActor
    func testRefreshShowsARemotePositionAhead() async {
        let r = rig()
        defer { r.cleanup() }
        r.service.stored = remote(0.8)
        let before = r.reloads()
        let result = await r.refresher.refresh()
        XCTAssertEqual(result, .ahead(remote(0.8)))
        XCTAssertEqual(r.service.fetches, 1, "one request per refresh")
        XCTAssertEqual(r.store.load()?.fraction ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(r.reloads(), before + 1)
        XCTAssertEqual(r.sync.remoteMemory.synced(for: "h")?.percentage ?? 0, 0.8, accuracy: 1e-9,
                       "the Library row reads it")
        // Launch and foreground together: the second refresh asks nothing.
        let again = await r.refresher.refresh()
        XCTAssertNil(again)
        XCTAssertEqual(r.service.fetches, 1)
    }

    @MainActor
    func testBehindOwnOrDeclinedLeavesTheLocalPosition() async {
        var clock = Date(timeIntervalSince1970: 0)
        let r = rig(now: { clock })
        defer { r.cleanup() }
        let local = r.store.load()
        // Behind.
        r.service.stored = remote(0.2)
        let behind = await r.refresher.refresh()
        XCTAssertEqual(behind, .nothing)
        XCTAssertEqual(r.store.load(), local)
        // This watch's own push coming back.
        let own = remote(0.8, xp: "/body/p[81]")
        r.sync.ownProgress.record(own, connectorID: "readest", bookKey: "h")
        r.service.stored = own
        clock += 120
        let mine = await r.refresher.refresh()
        XCTAssertEqual(mine, .nothing)
        XCTAssertEqual(r.store.load(), local)
        // A declined row.
        let declined = remote(0.9, xp: "/body/p[90]")
        r.sync.remoteMemory.setDeclined(RemoteFingerprint(declined), for: "h")
        r.service.stored = declined
        clock += 120
        let answered = await r.refresher.refresh()
        XCTAssertEqual(answered, .nothing)
        XCTAssertEqual(r.store.load(), local)
        XCTAssertNil(r.sync.remoteMemory.synced(for: "h"))
    }

    @MainActor
    func testErrorOrSyncOffChangesNothing() async {
        var clock = Date(timeIntervalSince1970: 0)
        let r = rig(now: { clock })
        defer { r.cleanup() }
        let local = r.store.load()
        r.service.stored = remote(0.8)
        r.service.fails = true
        let failed = await r.refresher.refresh()
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(r.store.load(), local)
        XCTAssertEqual(r.sync.status, .idle, "the background refresh does not change the reader's sync status")
        // Sync off: no request at all.
        r.box.service = nil
        clock += 120
        let off = await r.refresher.refresh()
        XCTAssertEqual(off, .off)
        XCTAssertEqual(r.service.fetches, 1)
        XCTAssertEqual(r.store.load(), local)
    }

    @MainActor
    func testRemoteFallingBehindAgainRestoresTheLocalSnapshot() async {
        var clock = Date(timeIntervalSince1970: 0)
        let r = rig(now: { clock })
        defer { r.cleanup() }
        r.service.stored = remote(0.8)
        await r.refresher.refresh()
        XCTAssertEqual(r.store.load()?.fraction ?? 0, 0.8, accuracy: 1e-9)
        r.service.stored = remote(0.3, at: 200)
        clock += 120
        await r.refresher.refresh()
        XCTAssertEqual(r.store.load()?.fraction ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.store.load()?.minutesLeft, 7)
        XCTAssertNil(r.sync.remoteMemory.synced(for: "h"))
    }

    // MARK: Reader

    @MainActor
    private func model(_ r: Rig) -> ReaderViewModel {
        let blocks = (0..<100).map { Block(text: String(repeating: "x", count: 10), xpointer: "/body/p[\($0 + 1)]",
                                           globalOffset: $0 * 10) }
        let book = ProcessedBook(metadata: BookMetadata(title: "T", authors: []), documentHash: "h", metaHash: "",
                                 chapters: [Chapter(spineIndex: 1, title: nil, blocks: blocks)], totalCharacters: 1_000)
        let m = ReaderViewModel(book: book, positions: PositionStore(defaults: r.defaults), sync: r.sync,
                                complications: r.publisher, settings: r.defaults)
        m.jump(to: 40)
        return m
    }

    @MainActor
    func testAcceptingTheOfferReloadsTheComplicationsAtOnce() async {
        let r = rig()
        defer { r.cleanup() }
        r.service.stored = remote(0.8)
        await r.refresher.refresh()
        let m = model(r)
        await m.syncOnOpen()
        XCTAssertTrue(m.showRemoteOffer)
        XCTAssertNil(r.sync.remoteMemory.synced(for: "h"), "the open book answers it through the offer")
        let before = r.reloads()
        m.acceptRemote()
        // The jump's publish reloads (40 % -> 80 %); the forced one reloads again although nothing visible changed.
        XCTAssertEqual(r.reloads(), before + 2)
        XCTAssertEqual(r.store.load()?.fraction ?? 0, 0.8, accuracy: 0.02)
    }

    @MainActor
    func testGoToSyncedPositionReloadsTheComplications() async {
        let r = rig()
        defer { r.cleanup() }
        let m = model(r)
        r.service.stored = remote(0.2, xp: "")
        let before = r.reloads()
        let result = await m.goToSyncedPosition()
        XCTAssertEqual(result, .jumped)
        XCTAssertGreaterThanOrEqual(r.reloads(), before + 2, "the jump's publish plus the forced one")
    }

    @MainActor
    func testDeclinedOfferIsNotRepeatedUntilTheRemoteChanges() async {
        let r = rig()
        defer { r.cleanup() }
        r.service.stored = remote(0.8)
        let first = model(r)
        await first.syncOnOpen()
        XCTAssertTrue(first.showRemoteOffer)
        first.declineRemote()
        XCTAssertNotNil(r.sync.remoteMemory.declined(for: "h"))
        // Reopened: the same row is not offered again, nor shown by the complications.
        let second = model(r)
        await second.syncOnOpen()
        XCTAssertFalse(second.showRemoteOffer)
        XCTAssertNil(second.remoteOffer)
        await r.refresher.refresh(force: true)
        XCTAssertNil(r.sync.remoteMemory.synced(for: "h"))
        XCTAssertLessThan(r.store.load()?.fraction ?? 1, 0.5)
        // Another device saved a new position: offered again.
        r.service.stored = remote(0.85, xp: "/body/p[86]", at: 300)
        let third = model(r)
        await third.syncOnOpen()
        XCTAssertTrue(third.showRemoteOffer)
        XCTAssertEqual(third.remoteOffer?.xpointer, "/body/p[86]")
        // Accepting forgets the declined row.
        third.acceptRemote()
        XCTAssertNil(r.sync.remoteMemory.declined(for: "h"))
    }

    func testFingerprintMatchesTheSameRowOnly() {
        let row = ReadingPosition(xpointer: "/a", percentage: 0.5, timestamp: Date(timeIntervalSince1970: 1),
                                  cfi: "epubcfi(/6/2!/4)")
        let f = RemoteFingerprint(row)
        XCTAssertTrue(f.matches(row))
        var later = row; later.timestamp = Date(timeIntervalSince1970: 2)
        XCTAssertFalse(f.matches(later))
        var moved = row; moved.cfi = "epubcfi(/6/4!/4)"
        XCTAssertFalse(f.matches(moved))
    }
}
