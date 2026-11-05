import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OnlineMetadataError: Error, Equatable, Sendable {
    /// No connection (or the request timed out).
    case offline
    /// Still 429/503 after backing off.
    case rateLimited
    case server(status: Int)
    case invalidResponse
}

/// One HTTP GET. The app uses `URLSessionMetadataTransport`; tests use a mock, so unit tests never touch the network.
public protocol MetadataTransport: Sendable {
    /// Returns the body, the status code and the `Retry-After` header (seconds) when present.
    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, retryAfter: Double?)
}

/// An ephemeral `URLSession`: no cookies, no cache on disk, no credentials.
public struct URLSessionMetadataTransport: MetadataTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int, retryAfter: Double?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OnlineMetadataError.invalidResponse }
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            return (data, http.statusCode, retryAfter)
        } catch let error as OnlineMetadataError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OnlineMetadataError.offline
        }
    }
}

/// Looks books up on Open Library, following their API etiquette (docs/ONLINE_METADATA.md): a descriptive
/// User-Agent, one request at a time with at least `minimumInterval` between them, and exponential backoff on
/// 429/503 (honouring `Retry-After`).
public actor OpenLibraryClient {
    private let transport: MetadataTransport
    private let userAgent: String
    private let minimumInterval: Double
    private let maxRetries: Int
    private let sleep: @Sendable (Double) async throws -> Void
    private let now: @Sendable () -> Date
    private var lastRequest: Date?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Requests sent so far (tests check the count and order).
    public private(set) var requestLog: [URL] = []

    public init(transport: MetadataTransport = URLSessionMetadataTransport(),
                userAgent: String = OpenLibraryAPI.userAgent, minimumInterval: Double = 1, maxRetries: Int = 2,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.userAgent = userAgent
        self.minimumInterval = minimumInterval
        self.maxRetries = maxRetries
        self.sleep = sleep
        self.now = now
    }

    // MARK: Lookups

    /// The ISBN first (Books API); without an ISBN, or when Open Library does not know it, a title and author
    /// search. Returns at most `OpenLibraryAPI.maxMatches`, best first; empty when nothing fits.
    public func lookup(_ query: OnlineLookupQuery) async throws -> [OnlineBookMatch] {
        if let isbn = query.isbn, let url = OpenLibraryAPI.booksURL(isbn: isbn),
           let data = try await fetch(url), let match = try OpenLibraryAPI.parseBooks(data) {
            return [match]
        }
        guard let url = OpenLibraryAPI.searchURL(title: query.title, author: query.authors.first) else { return [] }
        guard let data = try await fetch(url) else { return [] }
        return MatchScoring.rank(try OpenLibraryAPI.parseSearch(data), for: query)
    }

    /// The match's description: the edition's own, else its work's (one or two requests). Nil when it has none.
    public func description(for match: OnlineBookMatch) async throws -> String? {
        if let text = match.description { return text }
        guard let url = OpenLibraryAPI.recordURL(key: match.key), let data = try await fetch(url) else { return nil }
        let record = try OpenLibraryAPI.parseRecord(data)
        if let text = record.description { return text }
        guard let work = record.workKey, let workURL = OpenLibraryAPI.recordURL(key: work),
              let workData = try await fetch(workURL) else { return nil }
        return try OpenLibraryAPI.parseRecord(workData).description
    }

    /// The large cover image, or nil when Open Library has none (404, thanks to `default=false`).
    public func cover(for match: OnlineBookMatch) async throws -> Data? {
        guard let url = match.coverURL, let data = try await fetch(url), !data.isEmpty else { return nil }
        return data
    }

    // MARK: Requests

    /// GET with etiquette. Nil for 404; throws for other failures.
    func fetch(_ url: URL) async throws -> Data? {
        await acquire()
        defer { release() }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            if let last = lastRequest {
                let wait = minimumInterval - now().timeIntervalSince(last)
                if wait > 0 { try await sleep(wait) }
            }
            lastRequest = now()
            requestLog.append(url)
            let response = try await transport.get(url, headers: ["User-Agent": userAgent, "Accept": "application/json, image/*"])
            switch response.status {
            case 200..<300: return response.data
            case 404: return nil
            case 429, 503:
                guard attempt < maxRetries else { throw OnlineMetadataError.rateLimited }
                let backoff = min(60, max(response.retryAfter ?? 0, 2 * pow(2, Double(attempt))))
                attempt += 1
                try await sleep(backoff)
            default:
                throw OnlineMetadataError.server(status: response.status)
            }
        }
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
