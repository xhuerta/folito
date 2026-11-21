import Foundation

/// A catalog in the iPhone's Catalogs list: a preset or one the user added by address.
public struct OPDSCatalog: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The catalog's root feed.
    public var url: URL
    public var isPreset: Bool

    public init(id: String = UUID().uuidString, title: String, url: URL, isPreset: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.isPreset = isPreset
    }

    /// Standard Ebooks' new releases. Their full OPDS catalog is a benefit of their Patrons Circle (it answers
    /// 401 without a membership login); the new releases feed is open to everyone and lists EPUB downloads.
    public static let standardEbooks = OPDSCatalog(
        id: "preset.standardebooks", title: "Standard Ebooks",
        url: URL(string: "https://standardebooks.org/feeds/atom/new-releases")!, isPreset: true)

    public static let projectGutenberg = OPDSCatalog(
        id: "preset.gutenberg", title: "Project Gutenberg",
        url: URL(string: "https://www.gutenberg.org/ebooks.opds/")!, isPreset: true)

    /// Listed in the app, contacted only when the user opens one.
    public static let presets: [OPDSCatalog] = [standardEbooks, projectGutenberg]
}

/// Turns what the user typed into a catalog address.
public enum OPDSCatalogAddress {
    /// `https://…` and `http://…` addresses as typed; a bare host or path gets `https://`; `opds://` (used by some
    /// sites for "open in your reader" links) becomes `https://`. Nil for anything else (other schemes, no host,
    /// spaces in the host).
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("opds://") {
            text = "https://" + text.dropFirst("opds://".count)
        } else if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            // "example.com:8083/opds" would otherwise parse with "example.com" as its scheme.
            if text.contains("://") { return nil }
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
