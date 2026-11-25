import Foundation

/// How a catalog page offers search (`<link rel="search">`). See docs/OPDS.md.
public enum OPDSSearchLink: Sendable, Hashable {
    /// An OpenSearch description document (`application/opensearchdescription+xml`) that holds the template; it is
    /// read when the user searches for the first time.
    case description(URL)
    /// A template for Atom results given directly in the link (`type="application/atom+xml"` and an `href` with
    /// `{searchTerms}`), as Calibre's content server and Calibre-Web write it.
    case template(OPDSSearchTemplate)
}

/// An OpenSearch URL template for Atom/OPDS results, e.g. `/opds/search?query={searchTerms}`.
public struct OPDSSearchTemplate: Sendable, Hashable {
    /// The template as written (it may be relative).
    public var template: String
    /// The address the template is relative to: the description document, or the feed that linked it.
    public var base: URL
    /// The `Url` element's `indexOffset` and `pageOffset` (OpenSearch 1.1; both default to 1).
    public var indexOffset: Int
    public var pageOffset: Int

    public init(template: String, base: URL, indexOffset: Int = 1, pageOffset: Int = 1) {
        self.template = template
        self.base = base
        self.indexOffset = indexOffset
        self.pageOffset = pageOffset
    }

    /// The results address for `terms`: `{searchTerms}` gets the trimmed terms, percent-encoded; required
    /// `{startIndex}` / `{startPage}` the first page, `{language}` `*`, `{inputEncoding}` / `{outputEncoding}`
    /// `UTF-8`; optional parameters (`{name?}`) are left empty. Nil for empty terms, a template without
    /// `{searchTerms}` or with another required parameter, and results that are not `http`/`https`.
    public func url(for terms: String) -> URL? {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let filled = OPDSOpenSearch.fill(template, terms: trimmed, indexOffset: indexOffset,
                                                                  pageOffset: pageOffset) else { return nil }
        return OPDSParser.resolve(filled, base: base)
    }
}

/// OpenSearch 1.1 description documents and templates, as OPDS 1.2 catalogs use them.
public enum OPDSOpenSearch {
    static let namespace = "http://a9.com/-/spec/opensearch/1.1/"
    static let descriptionType = "application/opensearchdescription+xml"

    /// Reads an OpenSearch description, served from `url`, and picks its template for Atom results: a `Url` with
    /// `type` `application/atom+xml` (any parameters; one with `profile=opds-catalog` first) and `{searchTerms}`.
    /// `Url`s for other result types (HTML, RSS, suggestions) are ignored. Throws `.notAFeed` for anything that is
    /// not a description, and `.searchNotSupported` when it has no usable Atom template.
    public static func parseDescription(_ data: Data, url: URL) throws -> OPDSSearchTemplate {
        guard let root = XMLTree.parse(data), root.name == "OpenSearchDescription",
              root.namespace == namespace || root.namespace.isEmpty else { throw OPDSError.notAFeed }
        var candidates: [(template: OPDSSearchTemplate, opds: Bool)] = []
        for node in root.elements where node.name == "Url" && (node.namespace == namespace || node.namespace.isEmpty) {
            guard let type = node.attributes["type"], OPDSMediaType.base(type) == "application/atom+xml",
                  let raw = node.attributes["template"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            // `rel` defaults to "results"; "suggestions", "self" and "collection" are not result pages.
            let rel = node.attributes["rel"]?.lowercased().split(separator: " ").map(String.init) ?? ["results"]
            guard rel.contains("results") else { continue }
            let template = OPDSSearchTemplate(
                template: raw, base: url,
                indexOffset: node.attributes["indexOffset"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1,
                pageOffset: node.attributes["pageOffset"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1)
            // Usable only if it can be filled with a test term.
            guard template.url(for: "test") != nil else { continue }
            candidates.append((template, OPDSMediaType.parameters(type)["profile"] == "opds-catalog"))
        }
        guard let best = candidates.first(where: \.opds) ?? candidates.first else { throw OPDSError.searchNotSupported }
        return best.template
    }

    /// Percent-encodes search terms for any part of a URL: everything but the unreserved characters of RFC 3986
    /// (letters, digits, `-._~`) is encoded, so a term can be put into a path segment (`/opds/search/{searchTerms}`)
    /// or a query value alike. A space becomes `%20`.
    public static func encode(_ terms: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return terms.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The template with every `{parameter}` replaced (see `OPDSSearchTemplate.url(for:)`), or nil.
    static func fill(_ template: String, terms: String, indexOffset: Int = 1, pageOffset: Int = 1) -> String? {
        var out = ""
        var hasTerms = false
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            var name = String(rest[rest.index(after: open)..<close])
            rest = rest[rest.index(after: close)...]
            let optional = name.hasSuffix("?")
            if optional { name.removeLast() }
            // A namespace prefix (`{opensearch:searchTerms}`) names the same parameter.
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "searchTerms":
                out += encode(terms)
                hasTerms = true
            case _ where optional:
                break
            case "startIndex": out += String(indexOffset)
            case "startPage": out += String(pageOffset)
            case "language": out += "*"
            case "inputEncoding", "outputEncoding": out += "UTF-8"
            default:
                // A required parameter Folito has no value for (`count`, or a server's own extension).
                return nil
            }
        }
        out += rest
        return hasTerms ? out : nil
    }
}
