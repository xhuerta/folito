import Foundation
import ReaderCore

/// Builds `KOSyncCredentials` from the raw strings received from the phone.
enum ServerURL {
    /// Accepts "host", "host:port", or a full URL; defaults to https. Returns nil for empty/invalid input.
    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func credentials(server: String?, user: String?, password: String?) -> KOSyncCredentials? {
        guard let user, !user.isEmpty, let password, !password.isEmpty else { return nil }
        if let server, !server.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = parse(server) else { return nil }
            return KOSyncCredentials(serverURL: url, username: user, password: password)
        }
        return KOSyncCredentials(username: user, password: password)
    }
}
