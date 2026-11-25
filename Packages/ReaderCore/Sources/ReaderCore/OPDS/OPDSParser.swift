import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads OPDS 1.2 catalog pages (Atom feeds, and single Atom entry documents) into `OPDSFeed`.
///
/// Namespace-aware: Atom elements are matched by namespace (or no namespace, for sloppy feeds), Dublin Core
/// (`dcterms:` and `dc:`), OPDS (`opds:indirectAcquisition`) and Media RSS (`media:thumbnail`) likewise. The DOCTYPE is
/// removed before parsing (no external or expanding entities), and only `http`/`https` links are kept.
public enum OPDSParser {
    static let atomNS = "http://www.w3.org/2005/Atom"
    static let opdsNS = "http://opds-spec.org/2010/catalog"
    static let dcNamespaces: Set<String> = ["http://purl.org/dc/terms/", "http://purl.org/dc/elements/1.1/"]
    static let mediaNS = "http://search.yahoo.com/mrss/"
    /// Entries kept per page; a page with more is cut (nobody scrolls through them on a phone anyway).
    public static let maxEntries = 500

    /// Parses `data`, read from `url` (relative links are resolved against it).
    public static func parse(_ data: Data, url: URL) throws -> OPDSFeed {
        guard let root = XMLTree.parse(data) else { throw OPDSError.notAFeed }
        switch (root.isAtom, root.name) {
        case (true, "feed"):
            return feed(root, url: url)
        case (true, "entry"):
            // An entry document (`type=entry`): one book, shown like a feed with one entry.
            let entry = self.entry(root, base: url)
            return OPDSFeed(url: url, id: entry.id, title: entry.title, entries: [entry])
        default:
            throw OPDSError.notAFeed
        }
    }

    // MARK: Feed

    private static func feed(_ node: XMLTree.Node, url: URL) -> OPDSFeed {
        var feed = OPDSFeed(url: url, title: "")
        for child in node.elements where child.isAtom {
            switch child.name {
            case "id": feed.id = child.trimmedText
            case "title": feed.title = collapse(child.text)
            case "subtitle": feed.subtitle = text(of: child)
            case "icon", "logo": if feed.iconURL == nil { feed.iconURL = resolve(child.trimmedText, base: url) }
            case "link":
                if let search = searchLink(child, base: url) {
                    // A direct template saves reading the description document; either is kept if alone.
                    if case .template = search { feed.search = search } else if feed.search == nil { feed.search = search }
                    continue
                }
                guard let link = link(child, base: url) else { continue }
                switch link.rel {
                case "next": if OPDSMediaType.isFeed(link.type) || link.type == nil { feed.nextURL = feed.nextURL ?? link.url }
                case "start": feed.startURL = feed.startURL ?? link.url
                default: break
                }
            case "entry":
                if feed.entries.count < maxEntries { feed.entries.append(entry(child, base: url)) }
            default: break
            }
        }
        if feed.title.isEmpty { feed.title = url.host ?? url.absoluteString }
        return feed
    }

    // MARK: Search

    /// A feed's `rel="search"` link: an OpenSearch description, or an Atom template with `{searchTerms}`. The
    /// template's `href` is kept as written (resolving it now would percent-encode its braces).
    private static func searchLink(_ node: XMLTree.Node, base: URL) -> OPDSSearchLink? {
        guard node.attributes["rel"]?.trimmingCharacters(in: .whitespaces).lowercased() == "search",
              let href = node.attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty
        else { return nil }
        let type = node.attributes["type"].map(OPDSMediaType.base)
        if href.contains("{") {
            guard type == nil || type == "application/atom+xml" else { return nil }
            let template = OPDSSearchTemplate(template: href, base: base)
            return template.url(for: "test") == nil ? nil : .template(template)
        }
        guard type == OPDSOpenSearch.descriptionType, let url = resolve(href, base: base) else { return nil }
        return .description(url)
    }

    // MARK: Entry

    private static let imageRels: Set<String> = ["http://opds-spec.org/image", "http://opds-spec.org/cover",
                                                 "x-stanza-cover-image"]
    private static let thumbnailRels: Set<String> = ["http://opds-spec.org/image/thumbnail",
                                                     "http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail"]
    /// Feed links of an entry that are not where the entry leads.
    private static let nonNavigationRels: Set<String> = ["self", "up", "start", "search", "next", "previous", "prev",
                                                         "first", "last", "edit"]

    private static func entry(_ node: XMLTree.Node, base: URL) -> OPDSEntry {
        var id: String?
        var title = ""
        var authors: [String] = []
        var summary: String?
        var content: String?
        var language: String?
        var publisher: String?
        var issued: Int?
        var published: Int?
        var categories: [String] = []
        var image: URL?
        var thumbnail: URL?
        var feedLinks: [OPDSLink] = []
        var acquisitions: [OPDSLink] = []

        for child in node.elements {
            if child.isAtom {
                switch child.name {
                case "id": id = child.trimmedText
                case "title": title = collapse(child.text)
                case "author":
                    if let name = child.first("name", where: \.isAtom).map({ collapse($0.text) }), !name.isEmpty {
                        authors.append(name)
                    }
                case "summary": summary = summary ?? text(of: child)
                case "content": content = content ?? text(of: child)
                case "published": published = published ?? year(child.trimmedText)
                case "category":
                    let label = (child.attributes["label"] ?? child.attributes["term"] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty, !categories.contains(label) { categories.append(label) }
                case "publisher":
                    // Calibre-Web writes `<publisher><name>…</name></publisher>` in the Atom namespace.
                    let name = collapse(child.first("name")?.text ?? child.text)
                    if !name.isEmpty { publisher = publisher ?? name }
                case "link":
                    guard let link = link(child, base: base) else { continue }
                    if OPDSAcquisitionPolicy.isAcquisition(rel: link.rel) {
                        acquisitions.append(link)
                    } else if let rel = link.rel, thumbnailRels.contains(rel) {
                        thumbnail = thumbnail ?? link.url
                    } else if let rel = link.rel, imageRels.contains(rel) {
                        image = image ?? link.url
                    } else if OPDSMediaType.isFeed(link.type), !nonNavigationRels.contains(link.rel ?? "") {
                        feedLinks.append(link)
                    }
                default: break
                }
            } else if dcNamespaces.contains(child.namespace) {
                switch child.name {
                case "language": language = language ?? child.trimmedText.nonEmpty
                case "publisher": publisher = publisher ?? collapse(child.text).nonEmpty
                case "issued", "date": issued = issued ?? year(child.trimmedText)
                default: break
                }
            } else if child.namespace == mediaNS, child.name == "thumbnail" {
                thumbnail = thumbnail ?? child.attributes["url"].flatMap { resolve($0, base: base) }
            }
        }

        // "related" (more by the author, readers also downloaded) only when nothing better is there.
        let navigation = (feedLinks.first { $0.rel != "related" } ?? feedLinks.first)?.url
        let resolvedID = id?.nonEmpty ?? navigation?.absoluteString ?? acquisitions.first?.url.absoluteString ?? title
        return OPDSEntry(id: resolvedID, title: title.isEmpty ? resolvedID : title, authors: authors,
                         summary: summary ?? content, language: language, publisher: publisher,
                         year: issued ?? published, categories: categories, imageURL: image ?? thumbnail,
                         thumbnailURL: thumbnail ?? image, navigationURL: navigation, acquisitions: acquisitions)
    }

    private static func link(_ node: XMLTree.Node, base: URL) -> OPDSLink? {
        guard let href = node.attributes["href"], let url = resolve(href, base: base) else { return nil }
        let indirect = node.descendants { $0.namespace == opdsNS && $0.name == "indirectAcquisition" }
            .compactMap { $0.attributes["type"] }
        let length = node.attributes["length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        return OPDSLink(url: url, rel: node.attributes["rel"]?.trimmingCharacters(in: .whitespaces).nonEmpty,
                        type: node.attributes["type"]?.trimmingCharacters(in: .whitespaces).nonEmpty,
                        title: node.attributes["title"].map(collapse)?.nonEmpty, length: length,
                        indirectTypes: indirect)
    }

    // MARK: Helpers

    /// An absolute `http`/`https` URL, or nil (other schemes such as `javascript:` or `file:` are dropped).
    static func resolve(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = URL(string: trimmed, relativeTo: base)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0, relativeTo: base) }
        guard let url = raw?.absoluteURL, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Plain text of an Atom text construct (`type` text, html or xhtml).
    private static func text(of node: XMLTree.Node) -> String? {
        let type = node.attributes["type"]?.lowercased() ?? "text"
        let raw: String
        switch type {
        case "xhtml", "application/xhtml+xml":
            raw = EPUBMetadataReader.plainText(fromHTML: node.markup)
        case "html", "text/html":
            raw = EPUBMetadataReader.plainText(fromHTML: node.text)
        default:
            // Some servers (Calibre-Web) put HTML into a text summary.
            let t = node.text
            raw = t.range(of: "<[A-Za-z/][^>]*>", options: .regularExpression) != nil
                ? EPUBMetadataReader.plainText(fromHTML: t) : t
        }
        let lines = raw.components(separatedBy: "\n").map(collapse)
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n").nonEmpty
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func year(_ s: String) -> Int? {
        let digits = s.prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isASCII), let y = Int(digits), y > 0 else { return nil }
        return y
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// A small namespace-aware element tree (OPDS pages are small; a tree keeps the interpretation simple).
enum XMLTree {
    final class Node {
        let namespace: String
        let name: String
        let attributes: [String: String]
        fileprivate(set) var items: [Item] = []

        enum Item {
            case text(String)
            case element(Node)
        }

        init(namespace: String, name: String, attributes: [String: String]) {
            self.namespace = namespace
            self.name = name
            self.attributes = attributes
        }

        var isAtom: Bool { namespace == OPDSParser.atomNS || namespace.isEmpty }

        var elements: [Node] {
            items.compactMap { if case .element(let node) = $0 { return node } else { return nil } }
        }

        /// All text inside, descendants included.
        var text: String {
            items.map { item -> String in
                switch item {
                case .text(let s): return s
                case .element(let node): return node.text
                }
            }.joined()
        }

        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The content re-serialised as rough HTML (for XHTML text constructs); text is escaped again.
        var markup: String {
            items.map { item -> String in
                switch item {
                case .text(let s):
                    return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                case .element(let node): return "<\(node.name)>" + node.markup + "</\(node.name)>"
                }
            }.joined()
        }

        func first(_ name: String, where predicate: (Node) -> Bool = { _ in true }) -> Node? {
            elements.first { $0.name == name && predicate($0) }
        }

        func descendants(_ predicate: (Node) -> Bool) -> [Node] {
            elements.flatMap { (predicate($0) ? [$0] : []) + $0.descendants(predicate) }
        }
    }

    /// Elements nested deeper than this are dropped.
    static let maxDepth = 48

    static func parse(_ data: Data) -> Node? {
        let text = XMLSanitizer.prepare(XMLSanitizer.decode(data))
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []
        private var skipped = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard skipped == 0, stack.count < XMLTree.maxDepth else { skipped += 1; return }
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = Node(namespace: namespaceURI ?? "", name: local, attributes: attributeDict)
            if let parent = stack.last { parent.items.append(.element(node)) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if skipped > 0 { skipped -= 1; return }
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipped == 0 else { return }
            stack.last?.items.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard skipped == 0 else { return }
            stack.last?.items.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
        }
    }
}
