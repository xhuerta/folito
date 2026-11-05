import Foundation

/// A book's place in a series ("Book 2 of Dune").
public struct BookSeries: Codable, Sendable, Equatable {
    public var name: String
    /// Position in the series (`calibre:series_index` or `group-position`); may be fractional (2.5).
    public var index: Double?

    public init(name: String, index: Double? = nil) {
        self.name = name
        self.index = index
    }
}

/// One `dc:creator`.
public struct BookCreator: Codable, Sendable, Equatable {
    public var name: String
    /// Sort form ("Herbert, Frank") from `opf:file-as` or an EPUB 3 `file-as` refinement.
    public var fileAs: String?
    /// MARC relator code (`aut`, `edt`, `trl`, …), lower-cased; nil when the book gives none.
    public var role: String?

    public init(name: String, fileAs: String? = nil, role: String? = nil) {
        self.name = name
        self.fileAs = fileAs
        self.role = role
    }
}

/// Descriptive metadata of an EPUB, read from its package document only (no network lookups).
public struct EPUBDetails: Codable, Sendable, Equatable {
    public var title: String
    public var creators: [BookCreator]
    /// `dc:description` as plain text: HTML removed, paragraphs separated by a blank line.
    public var description: String?
    public var publisher: String?
    /// Year of `dc:date` (the publication date when the book marks one).
    public var year: Int?
    public var language: String?
    public var subjects: [String]
    /// ISBN-10 or ISBN-13 from `dc:identifier`, digits only (and a final X for ISBN-10).
    public var isbn: String?
    public var series: BookSeries?

    public init(title: String, creators: [BookCreator] = [], description: String? = nil, publisher: String? = nil,
                year: Int? = nil, language: String? = nil, subjects: [String] = [], isbn: String? = nil,
                series: BookSeries? = nil) {
        self.title = title
        self.creators = creators
        self.description = description
        self.publisher = publisher
        self.year = year
        self.language = language
        self.subjects = subjects
        self.isbn = isbn
        self.series = series
    }

    /// The authors to show: creators with the role `aut`; when no creator has a role, all of them.
    public var authors: [String] {
        let marked = creators.filter { $0.role == "aut" }
        if !marked.isEmpty { return marked.map(\.name) }
        let unmarked = creators.filter { $0.role == nil }
        return (unmarked.isEmpty ? creators : unmarked).map(\.name)
    }
}

/// The cover image found in an EPUB.
public struct EPUBCover: Sendable, Equatable {
    /// Where the cover was found, in the order the reader looks.
    public enum Source: String, Sendable, Equatable {
        /// EPUB 3: the manifest item with `properties="cover-image"`.
        case coverImageProperty
        /// EPUB 2: `<meta name="cover" content="<manifest id>">`.
        case metaCover
        /// `<guide><reference type="cover">`: an image, or the first image of that page.
        case guide
        /// The first image referenced by the first spine item.
        case firstSpineItem
    }

    public var data: Data
    /// Manifest media type, or one guessed from the file extension (`image/jpeg`, `image/svg+xml`, …).
    public var mediaType: String
    /// Archive path of the image.
    public var path: String
    public var source: Source

    public init(data: Data, mediaType: String, path: String, source: Source) {
        self.data = data
        self.mediaType = mediaType
        self.path = path
        self.source = source
    }

    /// True for raster formats an image decoder can open (JPEG, PNG, GIF, WebP, HEIC); false for SVG.
    public var isRaster: Bool { mediaType != "image/svg+xml" }
}

/// Reads `EPUBDetails` and the cover from an EPUB file. Everything is local; nothing is fetched.
public enum EPUBMetadataReader {
    public static func details(epubAt url: URL) throws -> EPUBDetails {
        try read(epubAt: url).details
    }

    public static func cover(epubAt url: URL) throws -> EPUBCover? {
        try read(epubAt: url).cover
    }

    /// Both at once (one archive open).
    public static func read(epubAt url: URL) throws -> (details: EPUBDetails, cover: EPUBCover?) {
        let zip = try ZipReader(url: url)
        let (opfPath, root) = try EPUBParser.packageDocument(in: zip)
        let package = try EPUBParser.parsePackage(root, opfPath: opfPath,
                                                  fallbackTitle: url.deletingPathExtension().lastPathComponent)
        let details = parseDetails(root, fallbackTitle: package.metadata.title)
        return (details, findCover(root: root, package: package, opfPath: opfPath, zip: zip))
    }

    // MARK: - Metadata

    static func parseDetails(_ root: XMLNode, fallbackTitle: String) -> EPUBDetails {
        let nodes = root.children.filter { $0.name == "metadata" }.flatMap(\.children)
        // EPUB 3 refinements: <meta refines="#id" property="…">value</meta>
        var refinements: [String: [String: String]] = [:]
        var calibre: [String: String] = [:]
        for node in nodes where node.name == "meta" {
            if let refines = node.attributes["refines"], let property = node.attributes["property"] {
                let id = refines.hasPrefix("#") ? String(refines.dropFirst()) : refines
                let value = node.trimmedText
                if !value.isEmpty, refinements[id, default: [:]][property] == nil {
                    refinements[id, default: [:]][property] = value
                }
            } else if let name = node.attributes["name"], let content = node.attributes["content"] {
                calibre[name.lowercased()] = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var details = EPUBDetails(title: fallbackTitle)
        var titleSet = false
        var dates: [(event: String?, value: String)] = []
        var identifiers: [(scheme: String?, value: String)] = []
        var epub3Series: BookSeries?
        for node in nodes {
            switch node.name {
            case "title":
                let value = node.trimmedText
                if !titleSet, !value.isEmpty { details.title = value; titleSet = true }
            case "creator":
                let name = node.trimmedText
                guard !name.isEmpty else { continue }
                let refined = node.attributes["id"].flatMap { refinements[$0] } ?? [:]
                let role = (node.attributes["opf:role"] ?? node.attributes["role"] ?? refined["role"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let fileAs = node.attributes["opf:file-as"] ?? node.attributes["file-as"] ?? refined["file-as"]
                details.creators.append(BookCreator(name: name, fileAs: nonEmpty(fileAs),
                                                    role: nonEmpty(role)))
            case "description":
                if details.description == nil { details.description = nonEmpty(plainDescription(node)) }
            case "publisher":
                if details.publisher == nil { details.publisher = nonEmpty(node.trimmedText) }
            case "date":
                let value = node.trimmedText
                if !value.isEmpty { dates.append((node.attributes["opf:event"] ?? node.attributes["event"], value)) }
            case "language":
                if details.language == nil { details.language = nonEmpty(node.trimmedText) }
            case "subject":
                let value = node.trimmedText
                if !value.isEmpty, !details.subjects.contains(value) { details.subjects.append(value) }
            case "identifier":
                let value = node.trimmedText
                if !value.isEmpty { identifiers.append((node.attributes["opf:scheme"] ?? node.attributes["scheme"], value)) }
            case "meta":
                guard epub3Series == nil, node.attributes["property"] == "belongs-to-collection",
                      node.attributes["refines"] == nil else { continue }
                let name = node.trimmedText
                let refined = node.attributes["id"].flatMap { refinements[$0] } ?? [:]
                guard !name.isEmpty, refined["collection-type"]?.lowercased() == "series" else { continue }
                epub3Series = BookSeries(name: name, index: refined["group-position"].flatMap(seriesIndex))
            default:
                break
            }
        }

        let publication = dates.first { $0.event?.lowercased() == "publication" } ?? dates.first { $0.event == nil } ?? dates.first
        details.year = publication.flatMap { year(from: $0.value) }
        details.isbn = isbn(from: identifiers)
        if let epub3Series {
            details.series = epub3Series
        } else if let name = nonEmpty(calibre["calibre:series"]) {
            details.series = BookSeries(name: name, index: calibre["calibre:series_index"].flatMap(seriesIndex))
        }
        return details
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func seriesIndex(_ raw: String) -> Double? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    /// The first four-digit year in a W3CDTF date ("2019-05-01", "1813", "2001-01-01T00:00:00+00:00").
    static func year(from value: String) -> Int? {
        let digits = Array(value.unicodeScalars)
        var i = 0
        while i + 4 <= digits.count {
            let run = digits[i..<i + 4]
            if run.allSatisfy({ CharacterSet.decimalDigits.contains($0) && $0.isASCII }),
               i + 4 == digits.count || !CharacterSet.decimalDigits.contains(digits[i + 4]),
               i == 0 || !CharacterSet.decimalDigits.contains(digits[i - 1]) {
                let year = Int(String(String.UnicodeScalarView(run))) ?? 0
                if year >= 1 && year <= 9999 && year != 101 { return year }  // 0101 is a common "unknown" filler
            }
            i += 1
        }
        return nil
    }

    /// An ISBN from the identifiers: one marked `opf:scheme="ISBN"`, then a `urn:isbn:` value, then any value
    /// that is a valid ISBN-13 (978/979) or ISBN-10 on its own.
    static func isbn(from identifiers: [(scheme: String?, value: String)]) -> String? {
        func clean(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.lowercased().hasPrefix("urn:isbn:") { v = String(v.dropFirst(9)) }
            if v.lowercased().hasPrefix("isbn:") { v = String(v.dropFirst(5)) }
            return v.uppercased().filter { $0.isASCII && ($0.isNumber || $0 == "X") }
        }
        let marked = identifiers.filter { $0.scheme?.lowercased() == "isbn" || $0.value.lowercased().hasPrefix("urn:isbn:") }
        for id in marked {
            let v = clean(id.value)
            if v.count == 13 || v.count == 10 { return v }
        }
        for id in identifiers where isValidISBN(clean(id.value)) && !id.value.lowercased().contains("uuid") {
            return clean(id.value)
        }
        return nil
    }

    static func isValidISBN(_ v: String) -> Bool {
        let chars = Array(v)
        if chars.count == 13, v.hasPrefix("978") || v.hasPrefix("979"), chars.allSatisfy(\.isNumber) {
            let sum = chars.enumerated().reduce(0) { $0 + ($1.element.wholeNumberValue ?? 0) * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0
        }
        if chars.count == 10, chars.dropLast().allSatisfy(\.isNumber), chars[9].isNumber || chars[9] == "X" {
            var sum = 0
            for (i, c) in chars.enumerated() { sum += (10 - i) * (c == "X" ? 10 : (c.wholeNumberValue ?? 0)) }
            return sum % 11 == 0
        }
        return false
    }

    /// Plain text of a description, whether it holds escaped HTML (`&lt;p&gt;…`, the common case), real child
    /// elements, or plain text. Paragraphs become blank-line separated; everything else is collapsed.
    static func plainDescription(_ node: XMLNode) -> String {
        plainText(fromHTML: markup(of: node))
    }

    /// Re-serialises a node's content as rough HTML so element children and escaped HTML go through one path.
    private static func markup(of node: XMLNode) -> String {
        var out = node.text
        for child in node.children { out += "<\(child.name)>" + markup(of: child) + "</\(child.name)>" }
        return out
    }

    private static let blockTags: Set<String> = ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                                                 "blockquote", "ul", "ol", "tr", "section"]

    /// HTML (or plain text) to plain text with paragraph breaks kept as "\n\n".
    public static func plainText(fromHTML html: String) -> String {
        // Split at block-level tags, then let HTMLText strip inline tags and decode entities in each piece.
        var pieces: [String] = []
        var current = ""
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                let inner = html[html.index(after: i)..<close]
                let name = inner.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
                if blockTags.contains(name) {
                    pieces.append(current)
                    current = ""
                    i = html.index(after: close)
                    continue
                }
            }
            if html[i] == "\n" || html[i] == "\r" {
                // A blank line in plain text separates paragraphs.
                let rest = html[html.index(after: i)...].prefix { $0 == " " || $0 == "\t" || $0 == "\r" }
                let afterRest = html.index(i, offsetBy: rest.count + 1, limitedBy: html.endIndex) ?? html.endIndex
                if afterRest < html.endIndex, html[afterRest] == "\n" {
                    pieces.append(current)
                    current = ""
                    i = html.index(after: afterRest)
                    continue
                }
            }
            current.append(html[i])
            i = html.index(after: i)
        }
        pieces.append(current)
        return pieces.map { HTMLText.plain($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Cover

    static func findCover(root: XMLNode, package: EPUBParser.Package, opfPath: String, zip: ZipReader) -> EPUBCover? {
        let manifest = package.manifest
        func image(_ item: EPUBParser.ManifestItem?, _ source: EPUBCover.Source) -> EPUBCover? {
            guard let item else { return nil }
            if isImage(mediaType: item.mediaType, path: item.path) { return load(item.path, item.mediaType, source, zip) }
            if EPUBParser.isXHTML(item) { return firstImage(inPage: item.path, manifest: manifest, source: source, zip: zip) }
            return nil
        }

        // 1. EPUB 3 cover-image property.
        if let item = manifest.values.sorted(by: { $0.id < $1.id }).first(where: { $0.properties.contains("cover-image") }),
           let cover = image(item, .coverImageProperty) {
            return cover
        }
        // 2. EPUB 2 <meta name="cover" content="id"> (some books put a path there instead of an id).
        let metas = root.children.filter { $0.name == "metadata" }.flatMap(\.children).filter { $0.name == "meta" }
        if let content = metas.first(where: { $0.attributes["name"]?.lowercased() == "cover" })?.attributes["content"] {
            let byPath = EPUBParser.resolve(content, relativeTo: opfPath).flatMap { path in
                manifest.values.first { $0.path == path }
            }
            if let cover = image(manifest[content] ?? byPath, .metaCover) { return cover }
        }
        // 3. <guide><reference type="cover" href="…">
        if let guide = root.child("guide") {
            for ref in guide.children where ref.name == "reference" && ref.attributes["type"]?.lowercased() == "cover" {
                guard let href = ref.attributes["href"], let path = EPUBParser.resolve(href, relativeTo: opfPath) else { continue }
                let item = manifest.values.first { $0.path == path }
                    ?? EPUBParser.ManifestItem(id: path, path: path, mediaType: "", properties: [])
                if let cover = image(item, .guide) { return cover }
            }
        }
        // 4. The first image of the first spine item.
        if let first = package.spine.first, let cover = image(first, .firstSpineItem) {
            return cover
        }
        return nil
    }

    static let imageExtensions: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "svg": "image/svg+xml",
    ]

    static func isImage(mediaType: String, path: String) -> Bool {
        if mediaType.hasPrefix("image/") { return true }
        return mediaType.isEmpty && imageExtensions[(path as NSString).pathExtension.lowercased()] != nil
    }

    private static func load(_ path: String, _ mediaType: String, _ source: EPUBCover.Source, _ zip: ZipReader) -> EPUBCover? {
        guard zip.contains(path), let data = try? zip.data(at: path), !data.isEmpty else { return nil }
        let type = mediaType.hasPrefix("image/") ? mediaType
            : imageExtensions[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
        return EPUBCover(data: data, mediaType: type == "image/jpg" ? "image/jpeg" : type, path: path, source: source)
    }

    /// The first `<img src>` or SVG `<image href>` of an XHTML page.
    private static func firstImage(inPage path: String, manifest: [String: EPUBParser.ManifestItem],
                                   source: EPUBCover.Source, zip: ZipReader) -> EPUBCover? {
        guard zip.contains(path), let data = try? zip.data(at: path),
              let page = try? XMLTreeBuilder.parse(data, what: "cover page") else { return nil }
        for node in imageNodes(page) {
            let href = node.name == "img" ? node.attributes["src"]
                : node.attributes["xlink:href"] ?? node.attributes["href"]
            guard let href, let target = EPUBParser.resolve(href, relativeTo: path) else { continue }
            let mediaType = manifest.values.first { $0.path == target }?.mediaType ?? ""
            guard isImage(mediaType: mediaType, path: target) else { continue }
            if let cover = load(target, mediaType, source, zip) { return cover }
        }
        return nil
    }

    private static func imageNodes(_ node: XMLNode) -> [XMLNode] {
        var out: [XMLNode] = []
        for child in node.children {
            if child.name == "img" || child.name == "image" { out.append(child) }
            out.append(contentsOf: imageNodes(child))
        }
        return out
    }
}

/// Colours of the generated cover placeholders (title and author on a colour picked from the title, like
/// Apple Books). Shared so the iPhone and the watch pick the same colour for a book.
public enum CoverPalette {
    /// Deep, muted tones; white text on each has a contrast ratio of at least 6:1.
    public static let colors: [UInt32] = [0x8E3B46, 0x2F5D62, 0x3D5A80, 0x6B4E9B, 0x7A5200, 0x2E6B3F, 0x7A4419, 0x4A4E69]

    /// Stable index into `colors` (FNV-1a of the lower-cased, trimmed title; the same on every device and run).
    public static func index(for title: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(colors.count))
    }

    /// RGB components (0...1) of the colour for `title`.
    public static func rgb(for title: String) -> (red: Double, green: Double, blue: Double) {
        let c = colors[index(for: title)]
        return (Double((c >> 16) & 0xFF) / 255, Double((c >> 8) & 0xFF) / 255, Double(c & 0xFF) / 255)
    }
}

/// Shortening long descriptions for a "More" expander without truncating text on screen.
public enum DescriptionExcerpt {
    /// The text cut at a word boundary to at most `maxCharacters`, with "…" appended; `truncated` is false
    /// (and the text unchanged) when it already fits.
    public static func excerpt(_ text: String, maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxCharacters, maxCharacters > 0 else { return (text, false) }
        let head = text.prefix(maxCharacters)
        let endsAtWord = text[head.endIndex].isWhitespace
        let cut = endsAtWord ? head.endIndex : (head.lastIndex { $0.isWhitespace } ?? head.endIndex)
        var short = String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = short.last, ",;:.-–—".contains(last) { short.removeLast() }
        if short.isEmpty { short = String(head) }
        return (short + "\u{2026}", true)
    }
}
