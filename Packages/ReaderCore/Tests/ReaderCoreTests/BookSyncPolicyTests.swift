import XCTest
@testable import ReaderCore

/// Issue #167: which books sync (connector kind x Readest link x per-book switch), the switch's merge and wire
/// form, pruning the queue, and the delayed syncing glyph.
final class BookSyncPolicyTests: XCTestCase {
    // MARK: Decision

    func testKOSyncSyncsEveryBookUnlessSwitchedOff() {
        for linked in [Bool?.none, true, false] {
            XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: false, linked: linked, switchedOn: true), .sync)
            XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: false, linked: linked, switchedOn: false), .switchedOff)
        }
    }

    func testReadestSyncsOnlyLinkedBooks() {
        XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: true, linked: true, switchedOn: true), .sync)
        XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: true, linked: false, switchedOn: true), .notInLibrary)
        // Unknown (older iPhone app, library not loaded): as before, the book syncs.
        XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: true, linked: nil, switchedOn: true), .sync)
    }

    func testSwitchWinsOverLink() {
        XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: true, linked: false, switchedOn: false), .switchedOff)
        XCTAssertEqual(BookSyncPolicy.decide(requiresLibraryLink: true, linked: true, switchedOn: false), .switchedOff)
        XCTAssertFalse(BookSyncDecision.switchedOff.syncs)
        XCTAssertFalse(BookSyncDecision.notInLibrary.syncs)
        XCTAssertTrue(BookSyncDecision.sync.syncs)
    }

    func testDescriptorsSayWhichConnectorNeedsALink() {
        XCTAssertTrue(ReadestConnectorFactory.descriptorValue.requiresLibraryLink)
        XCTAssertFalse(KOSyncConnectorFactory.descriptorValue.requiresLibraryLink)
    }

    func testSettingsDecisionPerBook() {
        let settings = BookSyncSettings(readestLinked: ["a"],
                                        switches: ["b": BookSyncSwitch(isOn: false, stamp: 5)])
        let readest = ReadestConnectorFactory.descriptorValue
        let kosync = KOSyncConnectorFactory.descriptorValue
        XCTAssertEqual(settings.decision(for: "a", connector: readest), .sync)
        XCTAssertEqual(settings.decision(for: "c", connector: readest), .notInLibrary)
        XCTAssertEqual(settings.decision(for: "c", connector: kosync), .sync)
        XCTAssertEqual(settings.decision(for: "b", connector: kosync), .switchedOff)
        XCTAssertNil(settings.decision(for: "a", connector: nil))
        // No report from the iPhone: every book syncs, as in earlier versions.
        XCTAssertEqual(BookSyncSettings().decision(for: "c", connector: readest), .sync)
    }

    func testOutsideLibraryOnlyWhenKnownAndLinkRequired() {
        let settings = BookSyncSettings(readestLinked: ["a"],
                                        switches: ["c": BookSyncSwitch(isOn: false, stamp: 5)])
        XCTAssertFalse(settings.isOutsideLibrary("a", requiresLibraryLink: true))
        XCTAssertTrue(settings.isOutsideLibrary("b", requiresLibraryLink: true))
        // The switch plays no part: a book switched off and not in the library is still outside it.
        XCTAssertTrue(settings.isOutsideLibrary("c", requiresLibraryLink: true))
        // KOReader Sync keeps no library.
        XCTAssertFalse(settings.isOutsideLibrary("b", requiresLibraryLink: false))
        // Unknown links: not outside (the book syncs, as before).
        XCTAssertFalse(BookSyncSettings().isOutsideLibrary("b", requiresLibraryLink: true))
    }

    func testSettingsPersistRoundTripAndTolerateOldData() throws {
        let settings = BookSyncSettings(readestLinked: ["a", "b"], switches: ["c": BookSyncSwitch(isOn: false, stamp: 9)])
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(BookSyncSettings.self, from: data), settings)
        let empty = try JSONDecoder().decode(BookSyncSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, BookSyncSettings())
        XCTAssertNil(empty.readestLinked)
    }

    // MARK: Switch

    func testSwitchStampsStrictlyNewer() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = BookSyncSwitch.set(false, now: now, replacing: nil)
        XCTAssertEqual(first, BookSyncSwitch(isOn: false, stamp: 1_000_000))
        let second = BookSyncSwitch.set(true, now: now, replacing: first)
        XCTAssertEqual(second.stamp, 1_000_001)
        XCTAssertTrue(second.isOn)
    }

    func testSwitchMergeLastWriterWins() {
        let local = ["a": BookSyncSwitch(isOn: false, stamp: 10), "b": BookSyncSwitch(isOn: true, stamp: 10)]
        let incoming = ["a": BookSyncSwitch(isOn: true, stamp: 20),   // newer: taken
                        "b": BookSyncSwitch(isOn: false, stamp: 10),  // tie: local kept
                        "c": BookSyncSwitch(isOn: false, stamp: 1),   // new book
                        "": BookSyncSwitch(isOn: false, stamp: 99)]   // invalid key
        let result = BookSyncSwitchMerge.merge(local: local, incoming: incoming)
        XCTAssertEqual(result.changed, ["a", "c"])
        XCTAssertEqual(result.switches["a"], BookSyncSwitch(isOn: true, stamp: 20))
        XCTAssertEqual(result.switches["b"], BookSyncSwitch(isOn: true, stamp: 10))
        XCTAssertEqual(result.switches["c"]?.isOn, false)
        XCTAssertNil(result.switches[""])
        // Resending the same copy changes nothing.
        XCTAssertTrue(BookSyncSwitchMerge.merge(local: result.switches, incoming: result.switches).changed.isEmpty)
    }

    func testSwitchDecodesTolerantly() throws {
        let json = #"{"a": {"t": 5}, "b": {"on": "x", "t": -3}, "c": {"on": false}}"#
        let decoded = try JSONDecoder().decode([String: BookSyncSwitch].self, from: Data(json.utf8))
        XCTAssertEqual(decoded["a"], BookSyncSwitch(isOn: true, stamp: 5))
        XCTAssertEqual(decoded["b"], BookSyncSwitch(isOn: true, stamp: 0))
        XCTAssertEqual(decoded["c"], BookSyncSwitch(isOn: false, stamp: 0))
    }

    // MARK: Wire (backward compatibility)

    func testWireRoundTrip() {
        let switches = ["a": BookSyncSwitch(isOn: false, stamp: 7)]
        var context = BookSyncWire.context(switches: switches)
        context.merge(BookSyncWire.context(readestLinked: ["x", "y", ""])) { _, new in new }
        XCTAssertEqual(BookSyncWire.switches(from: context), switches)
        XCTAssertEqual(BookSyncWire.readestLinked(from: context), ["x", "y"])
        XCTAssertEqual(context[BookSyncWire.readestLinkedKey] as? [String], ["x", "y"])
    }

    func testMissingKeysMeanCurrentBehaviour() {
        // An older iPhone (or one without the Readest library) sends neither key.
        let old: [String: Any] = ["type": "settings", "settingsVersion": 1]
        XCTAssertNil(BookSyncWire.switches(from: old))
        XCTAssertNil(BookSyncWire.readestLinked(from: old))
        XCTAssertTrue(BookSyncWire.context(switches: [:]).isEmpty)
        XCTAssertTrue(BookSyncWire.context(readestLinked: nil).isEmpty)
        // Known but empty is not unknown: no book is in the Readest library.
        XCTAssertEqual(BookSyncWire.readestLinked(from: BookSyncWire.context(readestLinked: [])), [])
        // Garbage is ignored, not fatal.
        XCTAssertNil(BookSyncWire.switches(from: [BookSyncWire.switchesKey: "not json"]))
        XCTAssertNil(BookSyncWire.readestLinked(from: [BookSyncWire.readestLinkedKey: 42]))
    }

    // MARK: Queue pruning

    func testPruneDropsUnsyncableBooksAndPersists() async {
        let client = FakeClient()
        let saved = PruneBox()
        let queue = SyncQueue(connector: KOSyncConnector(client: client), clock: FakeClock(),
                              onChange: { saved.data = $0 })
        for doc in ["a", "b", "c"] {
            await queue.enqueue(KOSyncProgress(document: doc, progress: "p", percentage: 0.5, device_id: "me"))
        }
        let settings = BookSyncSettings(switches: ["b": BookSyncSwitch(isOn: false, stamp: 1)])
        let dropped = await queue.prune { settings.decision(for: $0.book.key, requiresLibraryLink: false).syncs }
        XCTAssertEqual(dropped, ["b"])
        let pending = await queue.pending
        XCTAssertEqual(pending.map(\.progress.document), ["a", "c"])
        let restored = try? JSONDecoder().decode([PendingProgress].self, from: saved.data ?? Data())
        XCTAssertEqual(restored?.map(\.progress.document), ["a", "c"])
        let result = await queue.flush()
        XCTAssertEqual(result.sent, ["a", "c"])
        XCTAssertEqual(client.pushed.map(\.document), ["a", "c"])
        // Nothing to drop: nothing persisted again, nothing returned.
        saved.data = nil
        let none = await queue.prune { _ in true }
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(saved.data)
    }

    func testPruneForReadestLinks() async {
        let queue = SyncQueue(connector: KOSyncConnector(client: FakeClient()), clock: FakeClock())
        for doc in ["linked", "unlinked"] {
            await queue.enqueue(KOSyncProgress(document: doc, progress: "p", percentage: 0.5, device_id: "me"))
        }
        let settings = BookSyncSettings(readestLinked: ["linked"])
        await queue.prune { settings.decision(for: $0.book.key, requiresLibraryLink: true).syncs }
        let pending = await queue.pending
        XCTAssertEqual(pending.map(\.progress.document), ["linked"])
    }

    // MARK: Glyph delay

    @MainActor
    func testQuickRequestNeverShowsTheGlyph() async {
        let clock = GateClock()
        let indicator = SlowRequestIndicator(delay: 1, clock: clock)
        var changes: [Bool] = []
        indicator.onChange = { changes.append($0) }
        let token = indicator.begin()
        await clock.waitForSleeper()
        indicator.end(token)
        clock.release()
        await indicator.settle()
        XCTAssertFalse(indicator.isShowing)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(clock.requested, [1])
    }

    @MainActor
    func testSlowRequestShowsTheGlyphUntilItEnds() async {
        let clock = GateClock()
        let indicator = SlowRequestIndicator(delay: 1, clock: clock)
        var changes: [Bool] = []
        indicator.onChange = { changes.append($0) }
        let token = indicator.begin()
        await clock.waitForSleeper()
        clock.release() // one second passed, the request is still running
        await indicator.settle()
        XCTAssertTrue(indicator.isShowing)
        indicator.end(token)
        XCTAssertFalse(indicator.isShowing)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor
    func testSupersededRequestDoesNotShowTheGlyph() async {
        let clock = GateClock()
        let indicator = SlowRequestIndicator(delay: 1, clock: clock)
        let first = indicator.begin()
        await clock.waitForSleeper()
        let second = indicator.begin()
        indicator.end(second)
        clock.release()
        await indicator.settle()
        XCTAssertFalse(indicator.isShowing)
        // Ending the older request later changes nothing either.
        indicator.end(first)
        XCTAssertFalse(indicator.isShowing)
    }
}

private final class PruneBox: @unchecked Sendable { var data: Data? }

/// A clock whose `sleep` waits until the test releases it (the "one second" passes only when the test says so).
private final class GateClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var sleepers = 0
    private(set) var requested: [TimeInterval] = []

    func now() -> Date { Date(timeIntervalSince1970: 0) }

    func sleep(seconds: TimeInterval) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            requested.append(seconds)
            sleepers += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiting
        waiting = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    /// Waits until a timer is sleeping on this clock.
    func waitForSleeper() async {
        for _ in 0..<1_000 {
            lock.lock(); let count = sleepers; lock.unlock()
            if count > 0 { return }
            await Task.yield()
        }
    }
}
