import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Endpoints and the public Supabase key of Readest Cloud, as shipped in the open-source
/// `apps/readest.koplugin` (main.lua `default_settings`, `readest-sync-api.json`,
/// `supabase-auth-api.json`). See docs/READEST_SYNC.md.
public struct ReadestConfiguration: Sendable, Equatable {
    public var supabaseURL: URL
    /// Public Supabase "anon" key (a JWT with `role: anon`), the same one every Readest client ships;
    /// it is not a secret. Sent as `apikey` to the auth endpoints only.
    public var anonKey: String
    public var apiBase: URL

    public init(supabaseURL: URL, anonKey: String, apiBase: URL) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.apiBase = apiBase
    }

    // main.lua keeps the key base64-encoded (`SUPABAE_ANON_KEY_BASE64`); decoded at runtime the same way.
    private static let anonKeyBase64 = "ZXlKaGJHY2lPaUpJVXpJMU5pSXNJblI1Y0NJNklrcFhWQ0o5LmV5SnBjM01pT2lKemRYQmhZbUZ6WlNJc0luSmxaaUk2SW5aaWMzbDRablZ6YW1weFpIaHJhbkZzZVhOaklpd2ljbTlzWlNJNkltRnViMjRpTENKcFlYUWlPakUzTXpReE1qTTJOekVzSW1WNGNDSTZNakEwT1RZNU9UWTNNWDAuM1U1VXFhb3VfMVNnclZlMWVvOXJBcGMwdUtqcWhwUWRVWGh2d1VIbVVmZw=="

    public static let readestCloud = ReadestConfiguration(
        supabaseURL: URL(string: "https://vbsyxfusjjqdxkjqlysc.supabase.co")!,
        anonKey: String(data: Data(base64Encoded: anonKeyBase64) ?? Data(), encoding: .utf8) ?? "",
        apiBase: URL(string: "https://web.readest.com/api")!)
}

public enum ReadestError: Error, Equatable {
    case offline
    /// Wrong email/password (the password grant answered 400/401).
    case invalidCredentials
    /// Session expired or revoked; sign in again on the iPhone.
    case unauthorized
    case notSignedIn
    case rateLimited
    case notFound
    case server(status: Int, message: String?)
    case invalidResponse
}

extension ReadestError: SyncErrorClassifying {
    public var syncDisposition: SyncErrorDisposition {
        switch self {
        case .offline, .rateLimited: return .transient
        case .server(let s, _): return s >= 500 ? .transient : .permanent
        case .unauthorized, .notSignedIn, .invalidCredentials: return .unauthorized
        case .notFound, .invalidResponse: return .permanent
        }
    }
}

enum ReadestHTTP {
    // Same list as `KOSyncClient`: these mean "try again later", everything else is reported.
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Int, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadestError.invalidResponse }
            return (http.statusCode, data)
        } catch let error as URLError {
            if offlineCodes.contains(error.code) { throw ReadestError.offline }
            throw error
        }
    }

    /// Best-effort human message from Supabase (`msg`, `error_description`, `message`) or Readest (`error`) bodies.
    static func message(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["msg", "error_description", "message", "error"] {
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// Lenient timestamp: ISO-8601 string (with or without fractions / Postgres " " separator) or epoch ms number.
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, !(value is Bool) { return Date(timeIntervalSince1970: n.doubleValue / 1000) }
        guard var s = value as? String, !s.isEmpty else { return nil }
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        // Postgres emits microseconds; ISO8601DateFormatter accepts at most milliseconds.
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<tz]
            s = String(s[..<dot]) + "." + String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(s[tz...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
