import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One `book_configs` row as `GET /api/sync?type=configs` returns it (raw DB row, snake_case;
/// `progress` is a JSON string such as "[12,300]"). Only the reading-position fields are kept.
public struct ReadestBookConfig: Sendable, Equatable {
    public var bookHash: String
    public var metaHash: String?
    /// KOReader XPointer (written by the koplugin, and by the Readest apps converted from their CFI).
    public var xpointer: String?
    /// `[current page, total pages]` in the writer's own pagination.
    public var progress: [Int]?
    public var updatedAt: Date?
    public var deletedAt: Date?

    public init(bookHash: String, metaHash: String? = nil, xpointer: String? = nil, progress: [Int]? = nil,
                updatedAt: Date? = nil, deletedAt: Date? = nil) {
        self.bookHash = bookHash
        self.metaHash = metaHash
        self.xpointer = xpointer
        self.progress = progress
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// 0...1 from `progress`, like Readest's `getConfigFraction`; nil without a usable page count.
    public var fraction: Double? {
        guard let p = progress, p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        return min(1, Double(p[0]) / Double(p[1]))
    }

    static func parse(_ row: [String: Any]) -> ReadestBookConfig? {
        guard let hash = row["book_hash"] as? String, !hash.isEmpty else { return nil }
        let xp = row["xpointer"] as? String
        return ReadestBookConfig(bookHash: hash, metaHash: row["meta_hash"] as? String,
                                 xpointer: (xp?.isEmpty ?? true) ? nil : xp,
                                 progress: parseProgress(row["progress"]),
                                 updatedAt: ReadestHTTP.date(row["updated_at"]),
                                 deletedAt: ReadestHTTP.date(row["deleted_at"]))
    }

    /// `progress` is a JSON string in `book_configs` and an array in `books`; accept both.
    static func parseProgress(_ value: Any?) -> [Int]? {
        if let arr = value as? [Any] {
            let n = arr.compactMap { ($0 as? NSNumber)?.intValue }
            return n.count == arr.count && n.count == 2 ? n : nil
        }
        if let s = value as? String, let d = s.data(using: .utf8) {
            return parseProgress(try? JSONSerialization.jsonObject(with: d))
        }
        return nil
    }
}

/// `/api/sync` client for reading positions (`readest-sync-api.json`: `pullChanges` / `pushChanges`).
/// Requests carry `Authorization: Bearer <Supabase access token>`; a 401, or a 403 whose body is
/// `{"error":"Not authenticated"}`, refreshes the token once and retries (koplugin behaviour).
public struct ReadestSyncClient: Sendable {
    private let config: ReadestConfiguration
    private let http: URLSession
    private let auth: ReadestAuth

    public init(config: ReadestConfiguration = .readestCloud, session: URLSession = .shared, auth: ReadestAuth) {
        self.config = config
        self.http = session
        self.auth = auth
    }

    /// Every config row of the book: same `book_hash` OR same `meta_hash` (the server ORs them), so the
    /// result can include sibling copies of the same work. Tombstones are filtered out.
    public func fetchConfigs(bookHash: String, metaHash: String?) async throws -> [ReadestBookConfig] {
        var q = ["since": "0", "type": "configs", "book": bookHash]
        if let metaHash, !metaHash.isEmpty { q["meta_hash"] = metaHash }
        let data = try await send(method: "GET", query: q, body: nil)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadestError.invalidResponse
        }
        let rows = (obj["configs"] as? [[String: Any]]) ?? []
        return rows.compactMap(ReadestBookConfig.parse).filter { $0.deletedAt == nil }
    }

    /// `POST /api/sync` with one config, the way the koplugin pushes (`updatedAt` in epoch ms).
    /// The server keeps the row with the newer `updated_at` (ties keep the server row) and answers with
    /// the authoritative rows, which are returned.
    @discardableResult
    public func pushConfig(_ c: ReadestBookConfig) async throws -> [ReadestBookConfig] {
        let body = try JSONSerialization.data(withJSONObject: Self.pushBody(c), options: [.sortedKeys])
        let data = try await send(method: "POST", query: [:], body: body)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["configs"] as? [[String: Any]]) ?? []).compactMap(ReadestBookConfig.parse)
    }

    static func pushBody(_ c: ReadestBookConfig) -> [String: Any] {
        var cfg: [String: Any] = ["bookHash": c.bookHash, "xpointer": c.xpointer ?? ""]
        if let u = c.updatedAt { cfg["updatedAt"] = Int64((u.timeIntervalSince1970 * 1000).rounded()) }
        if let m = c.metaHash { cfg["metaHash"] = m }
        if let p = c.progress { cfg["progress"] = p }
        return ["books": [Any](), "notes": [Any](), "configs": [cfg]]
    }

    /// Cheap authenticated read used to verify a session (no rows: `since` is now).
    public func ping() async throws {
        let now = String(Int64(Date().timeIntervalSince1970 * 1000))
        _ = try await send(method: "GET", query: ["since": now, "type": "configs",
                                                    "book": "00000000000000000000000000000000"], body: nil)
    }

    private func send(method: String, query: [String: String], body: Data?) async throws -> Data {
        var refreshed = false
        while true {
            let token = try await auth.validAccessToken(forceRefresh: refreshed)
            var comps = URLComponents(url: config.apiBase.appendingPathComponent("sync"), resolvingAgainstBaseURL: false)!
            if !query.isEmpty {
                comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = body }
            let (status, data) = try await ReadestHTTP.perform(req, session: http)
            switch status {
            case 200, 201: return data
            case 401, 403:
                // 403 is also used for quota/permission errors; only "Not authenticated" means a bad token.
                let msg = ReadestHTTP.message(from: data)
                if status == 401 || msg == "Not authenticated" {
                    if refreshed { throw ReadestError.unauthorized }
                    refreshed = true
                    continue
                }
                throw ReadestError.server(status: status, message: msg)
            case 404: throw ReadestError.notFound
            case 429: throw ReadestError.rateLimited
            default: throw ReadestError.server(status: status, message: ReadestHTTP.message(from: data))
            }
        }
    }
}
