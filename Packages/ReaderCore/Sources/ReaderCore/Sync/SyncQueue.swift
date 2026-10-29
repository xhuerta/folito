import Foundation

/// Time source for `SyncQueue`; injectable so tests do not wait.
public protocol SyncClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A position waiting to be sent to one connector.
public struct SyncEntry: Codable, Sendable, Equatable {
    /// `SyncConnectorDescriptor.id` of the service the position was recorded for. An entry is only ever
    /// sent to that service; switching connectors drops it.
    public var connectorID: String
    public var book: BookIdentity
    public var position: ReadingPosition

    public init(connectorID: String, book: BookIdentity, position: ReadingPosition) {
        self.connectorID = connectorID
        self.book = book
        self.position = position
    }
}

/// Latest unsent progress for a document plus its retry bookkeeping.
public struct PendingProgress: Codable, Sendable, Equatable {
    public var entry: SyncEntry
    public var attempts: Int
    public var nextAttempt: Date

    public init(entry: SyncEntry, attempts: Int, nextAttempt: Date) {
        self.entry = entry
        self.attempts = attempts
        self.nextAttempt = nextAttempt
    }

    /// KOSync view of the entry (compatibility with code written before connectors).
    public var progress: KOSyncProgress { KOSyncProgress(book: entry.book, position: entry.position) }

    enum CodingKeys: String, CodingKey { case entry, progress, attempts, nextAttempt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempts = try c.decode(Int.self, forKey: .attempts)
        nextAttempt = try c.decode(Date.self, forKey: .nextAttempt)
        if let e = try c.decodeIfPresent(SyncEntry.self, forKey: .entry) {
            entry = e
        } else {
            // Queues persisted before connectors (`sync.queue.v1`) hold bare KOSync records.
            let p = try c.decode(KOSyncProgress.self, forKey: .progress)
            entry = SyncEntry(connectorID: KOSyncConnectorFactory.id, book: p.bookIdentity, position: p.readingPosition)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry, forKey: .entry)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(nextAttempt, forKey: .nextAttempt)
    }
}

public struct SyncFlushResult: Sendable, Equatable {
    public var sent: [String] = []
    /// Still queued (transient failure, backoff not elapsed, or unauthorized).
    public var retained: [String] = []
    /// Discarded after a permanent rejection, too many attempts, or because it belongs to another connector.
    public var dropped: [String] = []
    /// Discarded because the server already holds a newer position from another device.
    public var superseded: [String] = []
    public var unauthorized = false
}

/// Offline-tolerant debouncer: keeps only the latest progress per document and pushes it with
/// exponential backoff through a `SyncConnector`. Connector-agnostic; state is Codable so the app can
/// persist it.
public actor SyncQueue {
    public struct Config: Sendable {
        public var debounce: TimeInterval = 5
        public var baseBackoff: TimeInterval = 2
        public var maxBackoff: TimeInterval = 300
        public var maxAttempts: Int = 10
        /// Entries older than this (they sat in the queue, e.g. while offline) are checked against
        /// the server before being sent, so they never overwrite a newer position from another device.
        public var staleCheckAge: TimeInterval = 60
        public init() {}
    }

    private let connector: SyncConnector
    private let clock: SyncClock
    private let config: Config
    private let onChange: (@Sendable (Data) -> Void)?
    private var items: [String: PendingProgress] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    /// At most one flush runs at a time; actor reentrancy would otherwise let an older push
    /// finish after a newer one and leave the server on the older position.
    private var inFlight: Task<SyncFlushResult, Never>?
    /// Last position the server is known to hold from us, to avoid re-sending the same place.
    private var lastSent: [String: SyncEntry] = [:]

    /// `connector` may resolve the active service on every call (the watch's `ActiveSyncConnector`); its
    /// `descriptor.id` at flush time decides which entries may be sent.
    public init(connector: SyncConnector, clock: SyncClock = SystemSyncClock(),
                config: Config = Config(), restoring state: Data? = nil,
                onChange: (@Sendable (Data) -> Void)? = nil) {
        self.connector = connector
        self.clock = clock
        self.config = config
        self.onChange = onChange
        if let state, let list = try? JSONDecoder().decode([PendingProgress].self, from: state) {
            for p in list { items[p.entry.book.key] = p }
        }
    }

    /// KOSync convenience (pre-connector API).
    public init(client: KOSyncClientProtocol, clock: SyncClock = SystemSyncClock(),
                config: Config = Config(), restoring state: Data? = nil,
                onChange: (@Sendable (Data) -> Void)? = nil) {
        self.init(connector: KOSyncConnector(client: client), clock: clock, config: config,
                  restoring: state, onChange: onChange)
    }

    public var pending: [PendingProgress] { items.values.sorted { $0.entry.book.key < $1.entry.book.key } }

    public func snapshot() throws -> Data { try JSONEncoder().encode(pending) }

    /// Records the latest position (replacing any older one for the book) without sending.
    public func enqueue(_ entry: SyncEntry) {
        let key = entry.book.key
        if items[key] == nil, inFlight == nil, let sent = lastSent[key], sent.connectorID == entry.connectorID,
           sent.position.isSamePlace(as: entry.position) {
            return // the server already has exactly this place
        }
        items[key] = PendingProgress(entry: entry, attempts: 0, nextAttempt: clock.now())
        persist()
    }

    /// Records `position` for the queue's current connector.
    public func enqueue(_ position: ReadingPosition, for book: BookIdentity) {
        enqueue(SyncEntry(connectorID: connector.descriptor.id, book: book, position: position))
    }

    public func enqueue(_ progress: KOSyncProgress) {
        enqueue(progress.readingPosition, for: progress.bookIdentity)
    }

    /// Enqueues and (re)starts the debounce timer; a newer call supersedes the pending timer.
    public func schedule(_ entry: SyncEntry) {
        enqueue(entry)
        startWorker(initialDelay: config.debounce)
    }

    public func schedule(_ position: ReadingPosition, for book: BookIdentity) {
        schedule(SyncEntry(connectorID: connector.descriptor.id, book: book, position: position))
    }

    public func schedule(_ progress: KOSyncProgress) {
        schedule(progress.readingPosition, for: progress.bookIdentity)
    }

    /// Forgets the pending entry of one document (e.g. the book was deleted).
    public func remove(document: String) {
        lastSent[document] = nil
        guard items.removeValue(forKey: document) != nil else { return }
        persist()
    }

    /// Forgets every pending entry and stops the worker.
    public func removeAll() {
        cancel()
        items.removeAll()
        lastSent.removeAll()
        persist()
    }

    /// Drops entries recorded for any other connector than `connectorID` (called after a switch).
    public func retainOnly(connectorID: String) {
        let before = items.count
        items = items.filter { $0.value.entry.connectorID == connectorID }
        lastSent = lastSent.filter { $0.value.connectorID == connectorID }
        if items.count != before { persist() }
    }

    /// Starts delivery of anything restored from disk.
    public func resume() { if !items.isEmpty { startWorker(initialDelay: 0) } }

    public func cancel() { generation += 1; worker?.cancel(); worker = nil }

    public func backoff(forAttempt attempts: Int) -> TimeInterval {
        min(config.maxBackoff, config.baseBackoff * pow(2, Double(max(0, attempts - 1))))
    }

    /// Sends every entry that is due (all of them when `force`). Never throws.
    /// Calls are serialized: a flush that starts while another is running waits for it.
    @discardableResult
    public func flush(force: Bool = false) async -> SyncFlushResult {
        while let running = inFlight { _ = await running.value }
        let task = Task { await self.performFlush(force: force) }
        inFlight = task
        return await task.value
    }

    private func performFlush(force: Bool) async -> SyncFlushResult {
        defer { inFlight = nil }
        var result = SyncFlushResult()
        let descriptor = connector.descriptor
        for key in items.keys.sorted() {
            guard let entry = items[key]?.entry else { continue }
            if !descriptor.id.isEmpty && entry.connectorID != descriptor.id {
                // Recorded for another service: never send it to this one.
                items[key] = nil
                lastSent[key] = nil
                result.dropped.append(key)
                continue
            }
            if !force, let next = items[key]?.nextAttempt, next > clock.now() { result.retained.append(key); continue }
            do {
                if try await isSuperseded(entry, descriptor: descriptor) {
                    if items[key]?.entry == entry { items[key] = nil }
                    lastSent[key] = nil
                    result.superseded.append(key)
                    continue
                }
                try await connector.pushProgress(entry.position, for: entry.book)
                lastSent[key] = entry
                if items[key]?.entry == entry { items[key] = nil } // keep a newer one queued meanwhile
                result.sent.append(key)
            } catch {
                switch SyncErrors.disposition(of: error) {
                case .unauthorized:
                    result.unauthorized = true
                    result.retained.append(key)
                case .transient:
                    if var e = items[key], e.entry == entry {
                        e.attempts += 1
                        if e.attempts >= config.maxAttempts { items[key] = nil; result.dropped.append(key); continue }
                        e.nextAttempt = clock.now().addingTimeInterval(backoff(forAttempt: e.attempts))
                        items[key] = e
                    }
                    result.retained.append(key)
                case .permanent:
                    if items[key]?.entry == entry { items[key] = nil }
                    result.dropped.append(key)
                }
            }
        }
        persist()
        return result
    }

    /// True when the entry waited long enough to be stale and another device has since saved a newer
    /// position. Fresh entries cost no extra request. If the server cannot tell (no timestamp, permanent
    /// error on GET) the entry is sent as usual; network and auth failures propagate so it is retried.
    private func isSuperseded(_ entry: SyncEntry, descriptor: SyncConnectorDescriptor) async throws -> Bool {
        guard let queuedAt = entry.position.timestamp,
              clock.now().timeIntervalSince(queuedAt) > config.staleCheckAge else { return false }
        let remote: ReadingPosition?
        do {
            remote = try await connector.fetchProgress(for: entry.book)
        } catch {
            if SyncErrors.disposition(of: error) != .permanent { throw error }
            return false
        }
        guard let remote, let remoteAt = remote.timestamp, remote.deviceID != entry.position.deviceID
                || remote.deviceID.isEmpty else { return false }
        if descriptor.staleCheckRequiresDeviceID && remote.deviceID.isEmpty { return false }
        return remoteAt > queuedAt
    }

    private func startWorker(initialDelay: TimeInterval) {
        worker?.cancel()
        generation += 1
        let gen = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: gen, initialDelay: initialDelay)
        }
    }

    private func run(generation gen: Int, initialDelay: TimeInterval) async {
        do { try await clock.sleep(seconds: initialDelay) } catch { return }
        while gen == generation, !Task.isCancelled, !items.isEmpty {
            let result = await flush()
            if result.unauthorized || gen != generation { return }
            guard let next = items.values.map(\.nextAttempt).min() else { return }
            let wait = next.timeIntervalSince(clock.now())
            if wait > 0 { do { try await clock.sleep(seconds: wait) } catch { return } }
        }
    }

    private func persist() {
        guard let onChange, let data = try? snapshot() else { return }
        onChange(data)
    }
}
