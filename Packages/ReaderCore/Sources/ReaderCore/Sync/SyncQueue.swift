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

/// Latest unsent progress for a document plus its retry bookkeeping.
public struct PendingProgress: Codable, Sendable, Equatable {
    public var progress: KOSyncProgress
    public var attempts: Int
    public var nextAttempt: Date
}

public struct SyncFlushResult: Sendable, Equatable {
    public var sent: [String] = []
    /// Still queued (transient failure, backoff not elapsed, or unauthorized).
    public var retained: [String] = []
    /// Discarded after a permanent rejection or too many attempts.
    public var dropped: [String] = []
    /// Discarded because the server already holds a newer position from another device.
    public var superseded: [String] = []
    public var unauthorized = false
}

/// Offline-tolerant debouncer: keeps only the latest progress per document and
/// pushes it with exponential backoff. State is Codable so the app can persist it.
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

    private let client: KOSyncClientProtocol
    private let clock: SyncClock
    private let config: Config
    private let onChange: (@Sendable (Data) -> Void)?
    private var items: [String: PendingProgress] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    /// At most one flush runs at a time; actor reentrancy would otherwise let an older PUT
    /// finish after a newer one and leave the server on the older position.
    private var inFlight: Task<SyncFlushResult, Never>?
    /// Last position the server is known to hold from us, to avoid re-sending the same place.
    private var lastSent: [String: KOSyncProgress] = [:]

    public init(client: KOSyncClientProtocol, clock: SyncClock = SystemSyncClock(),
                config: Config = Config(), restoring state: Data? = nil,
                onChange: (@Sendable (Data) -> Void)? = nil) {
        self.client = client
        self.clock = clock
        self.config = config
        self.onChange = onChange
        if let state, let list = try? JSONDecoder().decode([PendingProgress].self, from: state) {
            for p in list { items[p.progress.document] = p }
        }
    }

    public var pending: [PendingProgress] { items.values.sorted { $0.progress.document < $1.progress.document } }

    public func snapshot() throws -> Data { try JSONEncoder().encode(pending) }

    /// Records the latest progress (replacing any older one for the document) without sending.
    public func enqueue(_ progress: KOSyncProgress) {
        if items[progress.document] == nil, inFlight == nil, let sent = lastSent[progress.document],
           sent.progress == progress.progress, sent.percentage == progress.percentage {
            return // the server already has exactly this place
        }
        items[progress.document] = PendingProgress(progress: progress, attempts: 0, nextAttempt: clock.now())
        persist()
    }

    /// Enqueues and (re)starts the debounce timer; a newer call supersedes the pending timer.
    public func schedule(_ progress: KOSyncProgress) {
        enqueue(progress)
        startWorker(initialDelay: config.debounce)
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
        for key in items.keys.sorted() {
            guard let entry = items[key] else { continue }
            if !force && entry.nextAttempt > clock.now() { result.retained.append(key); continue }
            do {
                if try await isSuperseded(entry.progress) {
                    if items[key]?.progress == entry.progress { items[key] = nil }
                    lastSent[key] = nil
                    result.superseded.append(key)
                    continue
                }
                try await client.pushProgress(entry.progress)
                lastSent[key] = entry.progress
                if items[key]?.progress == entry.progress { items[key] = nil } // keep a newer one queued meanwhile
                result.sent.append(key)
            } catch KOSyncError.unauthorized {
                result.unauthorized = true
                result.retained.append(key)
            } catch {
                if isTransient(error) {
                    var e = items[key] ?? entry
                    if e.progress == entry.progress {
                        e.attempts += 1
                        if e.attempts >= config.maxAttempts { items[key] = nil; result.dropped.append(key); continue }
                        e.nextAttempt = clock.now().addingTimeInterval(backoff(forAttempt: e.attempts))
                        items[key] = e
                    }
                    result.retained.append(key)
                } else {
                    if items[key]?.progress == entry.progress { items[key] = nil }
                    result.dropped.append(key)
                }
            }
        }
        persist()
        return result
    }

    /// True when `progress` waited long enough to be stale and another device has since saved a
    /// newer position. Fresh entries cost no extra request. If the server cannot tell
    /// (no timestamp, permanent error on GET) the entry is sent as usual; network and auth
    /// failures propagate so the entry is retried.
    private func isSuperseded(_ progress: KOSyncProgress) async throws -> Bool {
        guard let queuedAt = progress.timestamp,
              clock.now().timeIntervalSince1970 - Double(queuedAt) > config.staleCheckAge else { return false }
        let remote: KOSyncProgress?
        do {
            remote = try await client.fetchProgress(document: progress.document)
        } catch KOSyncError.unauthorized {
            throw KOSyncError.unauthorized
        } catch {
            if isTransient(error) { throw error }
            return false
        }
        guard let remote, let remoteAt = remote.timestamp, !remote.device_id.isEmpty,
              remote.device_id != progress.device_id else { return false }
        return remoteAt > queuedAt
    }

    private func isTransient(_ error: Error) -> Bool {
        if let e = error as? KOSyncError {
            switch e {
            case .offline: return true
            case .server(let s): return s >= 500 || s == 429
            default: return false
            }
        }
        return error is URLError
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
