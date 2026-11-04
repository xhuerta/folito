import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Readest Cloud library: the `books` rows of `/api/sync` and the book files in `/api/storage/*`.
// Every shape below was read from readest/readest (see docs/READEST_SYNC.md, "Library and files").

/// One `books` row as `GET /api/sync?type=books` returns it (raw DB row, snake_case, ISO timestamps).
/// `rawRow` keeps the whole row so a later push can send every field back: when the client's
/// `updatedAt` is newer the server replaces the row with what was sent (`transformBookToDB` turns a
/// missing field into null), so a partial push would erase the Readest app's tags, groups or progress.
public struct ReadestCloudBook: Sendable, Equatable, Codable, Identifiable {
    public var id: String { hash }
    /// `book_hash`: the partial MD5 of the file, the same value as Folito's `documentHash`.
    public var hash: String
    public var metaHash: String?
    /// "EPUB", "PDF", "MOBI", ... (`BookFormat` in Readest).
    public var format: String
    public var title: String
    public var author: String
    public var updatedAt: Date?
    public var deletedAt: Date?
    /// Set once the book file is in Readest's storage ("uploaded"); null for rows that only sync progress.
    public var uploadedAt: Date?
    public var coverUpdatedAt: Date?
    /// The row exactly as received (JSON object).
    public var rawRow: Data

    public init(hash: String, metaHash: String? = nil, format: String = "EPUB", title: String, author: String = "",
                updatedAt: Date? = nil, deletedAt: Date? = nil, uploadedAt: Date? = nil,
                coverUpdatedAt: Date? = nil, rawRow: Data? = nil) {
        self.hash = hash
        self.metaHash = metaHash
        self.format = format
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.uploadedAt = uploadedAt
        self.coverUpdatedAt = coverUpdatedAt
        self.rawRow = rawRow ?? Data("{}".utf8)
    }

    /// The hash of the placeholder row `sync.ts` returns to a first pull of an empty library.
    public static let placeholderHash = "00000000000000000000000000000000"

    /// Shown in a library: the file is in Readest (`uploaded_at`), the row is not a tombstone, and the
    /// format is one Folito reads. Same rule as the koplugin's `VISIBLE_BOOK_SQL` plus the EPUB filter.
    public var isAvailable: Bool {
        uploadedAt != nil && deletedAt == nil && hash != Self.placeholderHash && isEPUB
    }

    public var isEPUB: Bool { format.uppercased() == "EPUB" }

    public static func parse(_ row: [String: Any]) -> ReadestCloudBook? {
        guard let hash = (row["book_hash"] as? String) ?? (row["hash"] as? String), !hash.isEmpty else { return nil }
        let raw = (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ReadestCloudBook(
            hash: hash, metaHash: (row["meta_hash"] as? String) ?? (row["metaHash"] as? String),
            format: (row["format"] as? String) ?? "EPUB",
            title: (row["title"] as? String) ?? "", author: (row["author"] as? String) ?? "",
            updatedAt: ReadestHTTP.date(row["updated_at"] ?? row["updatedAt"]),
            deletedAt: ReadestHTTP.date(row["deleted_at"] ?? row["deletedAt"]),
            uploadedAt: ReadestHTTP.date(row["uploaded_at"] ?? row["uploadedAt"]),
            coverUpdatedAt: ReadestHTTP.date(row["cover_updated_at"] ?? row["coverUpdatedAt"]),
            rawRow: raw)
    }

    /// DB column -> `Book` field read by `transformBookToDB` (apps/readest-app/src/utils/transform.ts).
    static let wireFields: [(db: String, wire: String, isDate: Bool)] = [
        ("meta_hash", "metaHash", false), ("format", "format", false), ("title", "title", false),
        ("author", "author", false), ("source_title", "sourceTitle", false),
        ("original_filename", "originalFilename", false), ("group_id", "groupId", false),
        ("group_name", "groupName", false), ("group_updated_at", "groupUpdatedAt", true), ("tags", "tags", false),
        ("progress", "progress", false), ("reading_status", "readingStatus", false),
        ("reading_status_updated_at", "readingStatusUpdatedAt", true), ("cover_hash", "coverHash", false),
        ("cover_updated_at", "coverUpdatedAt", true), ("page_count", "pageCount", false),
        ("metadata", "metadata", false), ("metadata_updated_at", "metadataUpdatedAt", true),
        ("created_at", "createdAt", true), ("updated_at", "updatedAt", true), ("deleted_at", "deletedAt", true),
        ("uploaded_at", "uploadedAt", true),
    ]

    /// The row in the camelCase `Book` shape `POST /api/sync` expects, with every field received.
    public func wireRow() -> [String: Any] {
        let row = ((try? JSONSerialization.jsonObject(with: rawRow)) as? [String: Any]) ?? [:]
        var out: [String: Any] = ["hash": hash, "bookHash": hash]
        for f in Self.wireFields {
            guard let v = row[f.db] ?? row[f.wire], !(v is NSNull) else { continue }
            if f.isDate {
                if let d = ReadestHTTP.date(v) { out[f.wire] = ReadestLibraryClient.millis(d) }
            } else if f.db == "metadata", let s = v as? String, let d = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) {
                // Stored as a JSON string; the server stringifies what it gets, so send the object.
                out[f.wire] = obj
            } else {
                out[f.wire] = v
            }
        }
        if out["format"] == nil { out["format"] = format }
        if out["title"] == nil { out["title"] = title }
        if out["author"] == nil { out["author"] = author }
        return out
    }
}

/// `GET /api/storage/stats` (`usage`, `quota` in bytes).
public struct ReadestStorageUsage: Sendable, Equatable, Codable {
    public var usage: Int64
    public var quota: Int64
    public init(usage: Int64, quota: Int64) { self.usage = usage; self.quota = quota }
    public var fraction: Double { quota > 0 ? min(1, Double(usage) / Double(quota)) : 0 }
}

/// `POST /api/storage/upload` answer for a book file.
public struct ReadestUploadTicket: Sendable, Equatable {
    public var uploadURL: URL
    public var fileKey: String?
    public var usage: Int64?
    public var quota: Int64?
}

/// What Folito knows about a local book when it uploads it.
public struct ReadestUploadBook: Sendable, Equatable {
    public var hash: String
    public var metaHash: String?
    public var title: String
    public var author: String
    public var sourceTitle: String?
    public init(hash: String, metaHash: String?, title: String, author: String, sourceTitle: String? = nil) {
        self.hash = hash
        self.metaHash = metaHash
        self.title = title
        self.author = author
        self.sourceTitle = sourceTitle
    }
}

/// Object keys of book files (`{user_id}/Readest/Books/{hash}/...`, `CLOUD_BOOKS_SUBDIR` in
/// apps/readest-app/src/services/constants.ts; `getRemoteBookFilename` / `getCoverFilename` in utils/book.ts).
public enum ReadestFileKey {
    public static let booksSubdir = "Readest/Books"

    /// The `fileName` Folito uploads a book under: the S3-style `{hash}/{hash}.epub`, as the koplugin and the
    /// Calibre plugin do. The server prefixes it with the user id.
    public static func uploadName(hash: String, ext: String = "epub") -> String { "\(booksSubdir)/\(hash)/\(hash).\(ext)" }

    /// Download key of a book. On R2 the Readest app stores `{title}.epub` instead; `/storage/download`
    /// resolves any `{user}/Readest/Books/{hash}/{name}.{ext}` key by hash and extension (bookFileKey.ts).
    public static func book(userID: String, hash: String, ext: String = "epub") -> String {
        "\(userID)/\(uploadName(hash: hash, ext: ext))"
    }

    /// The cover, always `cover.png` (utils/book.ts `getCoverFilename`).
    public static func cover(userID: String, hash: String) -> String { "\(userID)/\(booksSubdir)/\(hash)/cover.png" }
}

/// Client for the library side of Readest Cloud: book rows (`/api/sync?type=books`) and files
/// (`/api/storage/upload`, `download`, `list`, `delete`, `stats`). Same auth rules as `ReadestSyncClient`:
/// a 401, or a 403 `{"error":"Not authenticated"}`, refreshes the token once and retries.
public struct ReadestLibraryClient: Sendable {
    private let config: ReadestConfiguration
    private let http: URLSession
    private let auth: ReadestAuth
    private let now: @Sendable () -> Date

    public init(config: ReadestConfiguration = .readestCloud, session: URLSession = .shared, auth: ReadestAuth,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.http = session
        self.auth = auth
        self.now = now
    }

    static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    // MARK: Rows

    /// Every `books` row of the account (tombstones included; see `ReadestCloudBook.isAvailable`).
    /// Without `limit` the server pages internally and returns all rows (sync.ts `queryTables`).
    public func fetchBooks() async throws -> [ReadestCloudBook] {
        let data = try await send("GET", "sync", query: ["since": "0", "type": "books"])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadestError.invalidResponse
        }
        return ((obj["books"] as? [[String: Any]]) ?? []).compactMap(ReadestCloudBook.parse)
    }

    /// `POST /api/sync` with book rows only; returns the authoritative rows the server answers with.
    @discardableResult
    public func pushBooks(_ rows: [[String: Any]]) async throws -> [ReadestCloudBook] {
        let body = try JSONSerialization.data(withJSONObject: ["books": rows, "notes": [Any](), "configs": [Any]()],
                                              options: [.sortedKeys])
        let data = try await send("POST", "sync", body: body)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["books"] as? [[String: Any]]) ?? []).compactMap(ReadestCloudBook.parse)
    }

    // MARK: Files

    /// `GET /api/storage/download?fileKey=` -> a presigned URL (30 min); nil when the file does not exist.
    public func downloadURL(fileKey: String) async throws -> URL? {
        do {
            let data = try await send("GET", "storage/download", query: ["fileKey": fileKey])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let s = obj?["downloadUrl"] as? String, let url = URL(string: s) else { throw ReadestError.invalidResponse }
            return url
        } catch ReadestError.notFound {
            return nil
        }
    }

    /// `POST /api/storage/upload {fileName, fileSize, bookHash}` -> presigned PUT URL. The server reserves the
    /// size against the quota first and answers 403 "Insufficient storage quota" when it does not fit.
    public func requestUpload(fileName: String, fileSize: Int, bookHash: String) async throws -> ReadestUploadTicket {
        let body = try JSONSerialization.data(withJSONObject: ["fileName": fileName, "fileSize": fileSize,
                                                               "bookHash": bookHash], options: [.sortedKeys])
        let data = try await send("POST", "storage/upload", body: body)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = obj["uploadUrl"] as? String, let url = URL(string: s) else { throw ReadestError.invalidResponse }
        return ReadestUploadTicket(uploadURL: url, fileKey: obj["fileKey"] as? String,
                                   usage: (obj["usage"] as? NSNumber)?.int64Value,
                                   quota: (obj["quota"] as? NSNumber)?.int64Value)
    }

    /// PUT of the bytes to a presigned URL (no auth header: the signature is in the URL).
    public func put(_ data: Data, to url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = data
        let (status, body) = try await ReadestHTTP.perform(req, session: http)
        switch status {
        case 200, 201, 204: return
        case 413: throw ReadestError.fileTooLarge
        default: throw ReadestError.server(status: status, message: Self.s3Code(body))
        }
    }

    /// GET of a presigned download URL.
    public func get(_ url: URL) async throws -> Data {
        let (status, data) = try await ReadestHTTP.perform(URLRequest(url: url), session: http)
        switch status {
        case 200: return data
        case 404: throw ReadestError.notFound
        default: throw ReadestError.server(status: status, message: Self.s3Code(data))
        }
    }

    /// `GET /api/storage/list?bookHash=` -> the keys of every file stored for the book.
    public func listFiles(bookHash: String) async throws -> [String] {
        let data = try await send("GET", "storage/list", query: ["bookHash": bookHash])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReadestError.invalidResponse
        }
        return ((obj["files"] as? [[String: Any]]) ?? []).compactMap { $0["file_key"] as? String }
    }

    /// `DELETE /api/storage/delete?fileKey=`; a missing file counts as deleted.
    public func deleteFile(fileKey: String) async throws {
        do { _ = try await send("DELETE", "storage/delete", query: ["fileKey": fileKey]) } catch ReadestError.notFound {}
    }

    /// `GET /api/storage/stats`.
    public func storageUsage() async throws -> ReadestStorageUsage {
        let data = try await send("GET", "storage/stats")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = (obj["usage"] as? NSNumber)?.int64Value,
              let quota = (obj["quota"] as? NSNumber)?.int64Value else { throw ReadestError.invalidResponse }
        return ReadestStorageUsage(usage: usage, quota: quota)
    }

    // MARK: Library operations

    /// The account's user id (from the session), the first segment of every file key.
    public func userID() async throws -> String { try await auth.userID() }

    /// Presigned URL of the book's EPUB, or nil when Readest has no file for it.
    public func bookDownloadURL(hash: String) async throws -> URL? {
        try await downloadURL(fileKey: ReadestFileKey.book(userID: try await userID(), hash: hash))
    }

    /// Presigned URL of the book's `cover.png`, or nil when it has none.
    public func coverDownloadURL(hash: String) async throws -> URL? {
        try await downloadURL(fileKey: ReadestFileKey.cover(userID: try await userID(), hash: hash))
    }

    /// Uploads an EPUB the way the koplugin does (`uploadAndRecord`): presigned upload of
    /// `Readest/Books/{hash}/{hash}.epub`, PUT, then a `books` row with `uploadedAt` so every Readest client
    /// lists it. `existing` (the account's row for this hash, tombstone or not) is pushed back whole.
    @discardableResult
    public func uploadBook(_ epub: Data, book: ReadestUploadBook, existing: ReadestCloudBook?) async throws -> ReadestCloudBook {
        let ticket = try await requestUpload(fileName: ReadestFileKey.uploadName(hash: book.hash),
                                             fileSize: epub.count, bookHash: book.hash)
        try await put(epub, to: ticket.uploadURL)
        let at = Self.millis(now())
        var row = existing?.wireRow() ?? Self.newRow(for: book, createdAt: at)
        row["uploadedAt"] = at
        row["updatedAt"] = at
        row["deletedAt"] = NSNull()
        let answer = try await pushBooks([row])
        return answer.first { $0.hash == book.hash } ?? ReadestCloudBook.parse(Self.dbShape(row)) ??
            ReadestCloudBook(hash: book.hash, title: book.title, uploadedAt: now())
    }

    /// Removes the book from Readest: deletes every stored file of the hash (book, cover; like the koplugin's
    /// `deleteCloudFiles`) and pushes a tombstone (`deletedAt`, `uploadedAt` null) so every client drops it.
    public func deleteBook(_ book: ReadestCloudBook) async throws {
        for key in try await listFiles(bookHash: book.hash) { try await deleteFile(fileKey: key) }
        let at = Self.millis(now())
        var row = book.wireRow()
        row["deletedAt"] = at
        row["updatedAt"] = at
        row["uploadedAt"] = NSNull()
        try await pushBooks([row])
    }

    /// A row for a book Readest has never seen (same fields the koplugin's `row_to_wire` sends).
    static func newRow(for book: ReadestUploadBook, createdAt: Int64) -> [String: Any] {
        var row: [String: Any] = ["hash": book.hash, "bookHash": book.hash, "format": "EPUB", "title": book.title,
                                  "author": book.author, "createdAt": createdAt, "updatedAt": createdAt]
        if let m = book.metaHash, !m.isEmpty { row["metaHash"] = m }
        if let s = book.sourceTitle, !s.isEmpty { row["sourceTitle"] = s }
        return row
    }

    /// camelCase wire row -> the snake_case shape `ReadestCloudBook.parse` reads (fallback only).
    static func dbShape(_ row: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["book_hash": row["hash"] ?? ""]
        for f in ReadestCloudBook.wireFields {
            guard let v = row[f.wire], !(v is NSNull) else { continue }
            if f.isDate, let n = v as? NSNumber {
                out[f.db] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: n.doubleValue / 1000))
            } else {
                out[f.db] = v
            }
        }
        return out
    }

    // MARK: Transport

    static func s3Code(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        guard let a = s.range(of: "<Code>"), let b = s.range(of: "</Code>", range: a.upperBound..<s.endIndex) else {
            return nil
        }
        return String(s[a.upperBound..<b.lowerBound])
    }

    /// Maps a non-2xx answer of `/api/*` to an error (`.unauthorized` = refresh once and retry). Other 403s
    /// (quota, permission) are reported as they are.
    static func error(status: Int, data: Data) -> ReadestError {
        let msg = ReadestHTTP.message(from: data)
        switch status {
        case 403 where msg == "Insufficient storage quota":
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return .quotaExceeded(usage: (obj?["usage"] as? NSNumber)?.int64Value)
        case 401: return .unauthorized
        case 403 where msg == "Not authenticated": return .unauthorized
        case 404: return .notFound
        case 413: return .fileTooLarge
        case 429: return .rateLimited
        default: return .server(status: status, message: msg)
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var refreshed = false
        while true {
            let token = try await auth.validAccessToken(forceRefresh: refreshed)
            var comps = URLComponents(url: config.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty {
                comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                // A file key may contain "&", "+" or "=": encode them so the server's parser keeps the key whole.
                comps.percentEncodedQuery = comps.percentEncodedQuery?
                    .replacingOccurrences(of: "+", with: "%2B")
            }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = body }
            let (status, data) = try await ReadestHTTP.perform(req, session: http)
            if (200..<300).contains(status) { return data }
            let error = Self.error(status: status, data: data)
            if error == .unauthorized, !refreshed { refreshed = true; continue }
            throw error
        }
    }
}

// MARK: - Merge of the local library and the Readest library

/// Where a book of the unified library lives.
public enum LibraryAvailability: Sendable, Equatable {
    /// Only on this device (never uploaded, or Readest is not connected).
    case localOnly
    /// On this device and in Readest.
    case localAndReadest
    /// Only in Readest: shown with a download button, never sent to the watch.
    case readestOnly
}

/// One row of the unified library.
public struct MergedLibraryItem<Local: Sendable>: Sendable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var local: Local?
    public var cloud: ReadestCloudBook?

    public var availability: LibraryAvailability {
        if local == nil { return .readestOnly }
        return cloud == nil ? .localOnly : .localAndReadest
    }
}

/// The Library's filter menu.
public enum LibraryFilter: String, CaseIterable, Sendable {
    case all
    case onThisDevice
    case inReadest

    public func includes(_ availability: LibraryAvailability) -> Bool {
        switch self {
        case .all: return true
        case .onThisDevice: return availability != .readestOnly
        case .inReadest: return availability != .localOnly
        }
    }
}

public enum LibraryMerge {
    /// Local books first, in their own order, each paired with its Readest row (same hash); then the books
    /// available only in Readest, newest first. Rows that are not `isAvailable` (tombstones, progress-only rows,
    /// other formats, the placeholder) never appear and never mark a local book as "in Readest".
    public static func merge<Local>(local: [Local], hash: (Local) -> String,
                                    cloud: [ReadestCloudBook]) -> [MergedLibraryItem<Local>] {
        var byHash: [String: ReadestCloudBook] = [:]
        for b in cloud where b.isAvailable {
            if let old = byHash[b.hash], (old.updatedAt ?? .distantPast) >= (b.updatedAt ?? .distantPast) { continue }
            byHash[b.hash] = b
        }
        var seen = Set<String>()
        var items: [MergedLibraryItem<Local>] = []
        for l in local {
            let h = hash(l)
            guard seen.insert(h).inserted else { continue }
            items.append(MergedLibraryItem(hash: h, local: l, cloud: byHash[h]))
        }
        let cloudOnly = byHash.values.filter { !seen.contains($0.hash) }.sorted {
            let a = $0.updatedAt ?? .distantPast, b = $1.updatedAt ?? .distantPast
            return a != b ? a > b : $0.hash < $1.hash
        }
        items += cloudOnly.map { MergedLibraryItem(hash: $0.hash, local: nil, cloud: $0) }
        return items
    }
}
