import Foundation

/// One page of an OPDS 1.2 catalog (an Atom feed). See docs/OPDS.md.
///
/// OPDS 1.2 has two kinds of feeds: *navigation* feeds, whose entries lead to other feeds, and *acquisition*
/// feeds, whose entries are books. Real catalogs mix them (Project Gutenberg's book pages, for example), so the
/// kind is decided per entry (`OPDSEntry.kind`), and `kind` here only summarises it.
public struct OPDSFeed: Sendable, Hashable {
    /// The address this page was read from (after redirects); relative links were resolved against it.
    public var url: URL
    public var id: String?
    public var title: String
    public var subtitle: String?
    public var iconURL: URL?
    public var entries: [OPDSEntry]
    /// The next page (`rel="next"`), when the catalog splits the feed into pages.
    public var nextURL: URL?
    /// The catalog's root (`rel="start"`).
    public var startURL: URL?

    public init(url: URL, id: String? = nil, title: String, subtitle: String? = nil, iconURL: URL? = nil,
                entries: [OPDSEntry] = [], nextURL: URL? = nil, startURL: URL? = nil) {
        self.url = url
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconURL = iconURL
        self.entries = entries
        self.nextURL = nextURL
        self.startURL = startURL
    }

    public enum Kind: String, Sendable { case navigation, acquisition }

    /// Acquisition when at least one entry is a book, navigation otherwise.
    public var kind: Kind { entries.contains { $0.kind == .book } ? .acquisition : .navigation }
}

/// A link of an entry or a feed, already resolved to an absolute `http`/`https` URL.
public struct OPDSLink: Sendable, Hashable, Codable {
    public var url: URL
    public var rel: String?
    /// The full media type as written, e.g. `application/atom+xml;profile=opds-catalog;kind=acquisition`.
    public var type: String?
    public var title: String?
    /// Size in bytes, when the catalog says (`length`).
    public var length: Int64?
    /// Media types of `opds:indirectAcquisition` children: the link does not lead to the file itself (DRM
    /// licences, loans, stores).
    public var indirectTypes: [String]

    public init(url: URL, rel: String? = nil, type: String? = nil, title: String? = nil, length: Int64? = nil,
                indirectTypes: [String] = []) {
        self.url = url
        self.rel = rel
        self.type = type
        self.title = title
        self.length = length
        self.indirectTypes = indirectTypes
    }

    /// The media type without parameters, lowercased (`application/epub+zip`).
    public var mediaType: String? { type.map(OPDSMediaType.base) }
}

/// One entry of a feed: a book, or a link to another feed.
public struct OPDSEntry: Sendable, Hashable, Identifiable, Codable {
    /// The entry's Atom id; when it has none, its first link or its title.
    public var id: String
    public var title: String
    public var authors: [String]
    /// Plain text (HTML and XHTML summaries are converted), from `summary`, else from `content`.
    public var summary: String?
    public var language: String?
    public var publisher: String?
    /// Year of `dcterms:issued`, else of `published`.
    public var year: Int?
    public var categories: [String]
    public var imageURL: URL?
    public var thumbnailURL: URL?
    /// The feed an entry leads to, for navigation entries (and "related" feeds of a book).
    public var navigationURL: URL?
    /// Every acquisition link, in document order, whatever its format (`http://opds-spec.org/acquisition…`, and
    /// `enclosure` in plain Atom feeds such as Standard Ebooks' new releases).
    public var acquisitions: [OPDSLink]

    public init(id: String, title: String, authors: [String] = [], summary: String? = nil, language: String? = nil,
                publisher: String? = nil, year: Int? = nil, categories: [String] = [], imageURL: URL? = nil,
                thumbnailURL: URL? = nil, navigationURL: URL? = nil, acquisitions: [OPDSLink] = []) {
        self.id = id
        self.title = title
        self.authors = authors
        self.summary = summary
        self.language = language
        self.publisher = publisher
        self.year = year
        self.categories = categories
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.navigationURL = navigationURL
        self.acquisitions = acquisitions
    }

    public enum Kind: String, Sendable { case book, navigation }

    /// A book when it has any acquisition link (or nothing to navigate to), navigation otherwise.
    public var kind: Kind { acquisitions.isEmpty && navigationURL != nil ? .navigation : .book }

    /// The download Folito uses: the first DRM-free EPUB that is free to take (see `OPDSAcquisitionPolicy`).
    public var epubLink: OPDSLink? { OPDSAcquisitionPolicy.preferredEPUB(in: acquisitions) }

    /// The cover to show in a list: the thumbnail, else the full image.
    public var listImageURL: URL? { thumbnailURL ?? imageURL }
}

/// Which acquisition links Folito follows.
public enum OPDSAcquisitionPolicy {
    public static let epubType = "application/epub+zip"
    /// Plain downloads. `buy`, `borrow`, `subscribe` and `sample` need a store, an account or give only part of
    /// the book, so they are skipped.
    static let freeRels: Set<String> = [
        "http://opds-spec.org/acquisition",
        "http://opds-spec.org/acquisition/open-access",
        "enclosure",
    ]

    /// The first link that is a direct, DRM-free EPUB download, in the catalog's order (catalogs list their
    /// recommended edition first: Standard Ebooks' "Recommended compatible epub", Project Gutenberg's EPUB3).
    /// Skipped: other formats (Kobo kepub, PDF, Kindle…), DRM licences (Adobe ACSM, Readium LCP), links with an
    /// indirect acquisition (the file is behind a licence or a loan) and paid or partial acquisitions.
    public static func preferredEPUB(in links: [OPDSLink]) -> OPDSLink? {
        links.first(where: isDirectEPUB)
    }

    public static func isDirectEPUB(_ link: OPDSLink) -> Bool {
        guard let rel = link.rel, freeRels.contains(rel), link.mediaType == epubType,
              link.indirectTypes.isEmpty else { return false }
        return true
    }

    static func isAcquisition(rel: String?) -> Bool {
        guard let rel else { return false }
        return rel == "enclosure" || rel.hasPrefix("http://opds-spec.org/acquisition")
    }
}

enum OPDSMediaType {
    /// `Application/EPUB+zip; charset=binary` → `application/epub+zip`.
    static func base(_ type: String) -> String {
        String(type.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The parameters, lowercased keys and values (`profile=opds-catalog;kind=acquisition`).
    static func parameters(_ type: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in type.split(separator: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if pair.count == 2 { out[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return out
    }

    /// An Atom feed (`application/atom+xml`, not `type=entry`): a link to another catalog page.
    static func isFeed(_ type: String?) -> Bool {
        guard let type else { return false }
        return base(type) == "application/atom+xml" && parameters(type)["type"] != "entry"
    }
}

/// Joining the pages of a paginated feed.
public enum OPDSPages {
    /// `page` after `entries`, without entries already shown (pages of a changing catalog can overlap).
    public static func append(_ page: [OPDSEntry], to entries: [OPDSEntry]) -> [OPDSEntry] {
        var seen = Set(entries.map(\.id))
        var out = entries
        for entry in page where seen.insert(entry.id).inserted { out.append(entry) }
        return out
    }
}
