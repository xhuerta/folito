import XCTest
@testable import ReaderCore

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Client with a scriptable remote and an optional gate that holds back one push.
private final class ScriptedClient: KOSyncClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var remote: KOSyncProgress?
    var fetchError: Error?
    var gatedProgress: String?
    let gate = Gate()
    private(set) var fetches = 0
    private(set) var gatedStarted = false
    private(set) var completed: [KOSyncProgress] = []

    func authorize() async throws {}
    func createUser() async throws {}

    func fetchProgress(document: String) async throws -> KOSyncProgress? {
        lock.lock(); defer { lock.unlock() }
        fetches += 1
        if let fetchError { throw fetchError }
        return remote
    }

    func pushProgress(_ progress: KOSyncProgress) async throws {
        if progress.progress == gatedProgress {
            lock.lock(); gatedStarted = true; lock.unlock()
            await gate.wait()
        }
        lock.lock(); completed.append(progress); lock.unlock()
    }
}

final class StaleProgressTests: XCTestCase {
    private let now = 1_000_000 // FakeClock epoch

    private func prog(xp: String, _ pct: Double, age: Int = 0, device: String = "watch") -> KOSyncProgress {
        KOSyncProgress(document: "doc", progress: xp, percentage: pct, device_id: device, timestamp: now - age)
    }

    private func remote(_ pct: Double, device: String, at ts: Int) -> KOSyncProgress {
        KOSyncProgress(document: "doc", progress: "remote", percentage: pct, device: "Readest",
                       device_id: device, timestamp: ts)
    }

    // MARK: Ordering

    func testConcurrentFlushesNeverLetAnOlderPushLandAfterANewerOne() async {
        let client = ScriptedClient()
        client.gatedProgress = "old"
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "old", 0.10))
        let a = Task { await q.flush() }
        var spins = 0
        while !client.gatedStarted && spins < 10_000 { await Task.yield(); spins += 1 }
        XCTAssertTrue(client.gatedStarted, "the old push must be in flight before the newer one is queued")
        await q.enqueue(prog(xp: "new", 0.20))
        let b = Task { await q.flush() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(client.completed.isEmpty, "the newer push must wait for the one in flight")
        await client.gate.open()
        _ = await a.value
        _ = await b.value
        XCTAssertEqual(client.completed.map(\.progress), ["old", "new"], "the server must end on the newest position")
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Staleness against the server

    func testDelayedEntryIsDroppedWhenAnotherDeviceReadFurtherSinceThen() async {
        let client = ScriptedClient()
        client.remote = remote(0.60, device: "kobo", at: now - 600)   // newer than our entry (1 h old)
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 3600))
        let r = await q.flush()
        XCTAssertEqual(r.superseded, ["doc"])
        XCTAssertTrue(r.sent.isEmpty)
        XCTAssertTrue(client.completed.isEmpty, "must not overwrite newer remote progress")
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testDelayedEntryIsSentWhenRemoteIsOlder() async {
        let client = ScriptedClient()
        client.remote = remote(0.10, device: "kobo", at: now - 7200)
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 3600))
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["doc"])
        XCTAssertEqual(client.completed.map(\.progress), ["mine"])
    }

    func testDelayedEntryIsSentWhenRemoteIsOurOwnDevice() async {
        let client = ScriptedClient()
        client.remote = remote(0.25, device: "watch", at: now - 100)
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 3600))
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["doc"])
    }

    func testDelayedEntryIsSentWhenServerHasNothing() async {
        let client = ScriptedClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 3600))
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["doc"])
    }

    func testFreshEntryIsPushedWithoutExtraRoundTrip() async {
        let client = ScriptedClient()
        client.remote = remote(0.90, device: "kobo", at: now + 10)
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 5))
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["doc"])
        XCTAssertEqual(client.fetches, 0)
    }

    func testStalenessCheckFailingOfflineKeepsTheEntryForRetry() async {
        let client = ScriptedClient()
        client.fetchError = KOSyncError.offline
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "mine", 0.30, age: 3600))
        let r = await q.flush()
        XCTAssertEqual(r.retained, ["doc"])
        XCTAssertTrue(client.completed.isEmpty)
        let pending = await q.pending
        XCTAssertEqual(pending.first?.attempts, 1)
    }

    func testEntryWithoutTimestampIsNotChecked() async {
        let client = ScriptedClient()
        client.remote = remote(0.90, device: "kobo", at: now + 10)
        let q = SyncQueue(client: client, clock: FakeClock())
        var p = prog(xp: "mine", 0.30)
        p.timestamp = nil
        await q.enqueue(p)
        let r = await q.flush()
        XCTAssertEqual(r.sent, ["doc"])
        XCTAssertEqual(client.fetches, 0)
    }

    // MARK: Identical updates

    func testIdenticalPositionIsNotResentAfterASuccessfulPush() async {
        let client = ScriptedClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "same", 0.30))
        _ = await q.flush()
        await q.enqueue(prog(xp: "same", 0.30, age: -5)) // same place, later timestamp
        let pending = await q.pending
        XCTAssertTrue(pending.isEmpty)
        let r = await q.flush()
        XCTAssertTrue(r.sent.isEmpty)
        XCTAssertEqual(client.completed.count, 1)
    }

    func testMovedPositionIsStillSent() async {
        let client = ScriptedClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "a", 0.30))
        _ = await q.flush()
        await q.enqueue(prog(xp: "b", 0.31))
        _ = await q.flush()
        XCTAssertEqual(client.completed.map(\.progress), ["a", "b"])
    }

    func testReturningToAnEarlierPositionIsSent() async {
        let client = ScriptedClient()
        let q = SyncQueue(client: client, clock: FakeClock())
        await q.enqueue(prog(xp: "a", 0.30)); _ = await q.flush()
        await q.enqueue(prog(xp: "b", 0.40)); _ = await q.flush()
        await q.enqueue(prog(xp: "a", 0.30)); _ = await q.flush()
        XCTAssertEqual(client.completed.map(\.progress), ["a", "b", "a"])
    }
}
