import Foundation

public enum EPUBError: Error, Equatable {
    case notImplemented
    case invalidArchive
    case missingContainer
    case missingPackageDocument
    case malformedXML(String)
    case emptySpine
    /// A resource referenced by the package is not in the archive.
    case missingResource(String)
    /// A ZIP entry declares (or expands to) more than the allowed size.
    case entryTooLarge(String)
}

/// Turns an EPUB file into a `ProcessedBook` (metadata, hashes, chapters, blocks with XPointers).
public protocol EPUBParsing: Sendable {
    func process(epubAt url: URL) throws -> ProcessedBook
}

/// Parses EPUB 2/3 files.
///
/// Decisions:
/// - `DocFragment[N]` numbering counts every `<itemref>` of the spine that resolves to a manifest item
///   (including `linear="no"` ones and non-XHTML items such as SVG covers), like crengine does.
/// - `linear="no"` items are kept and rendered as ordinary chapters.
/// - Spine items that are not XHTML, are missing from the archive, or contain no text produce no `Chapter`;
///   `Chapter.spineIndex` still carries the original position.
/// - Malformed XHTML is parsed leniently rather than rejected.
public struct EPUBParser: EPUBParsing {
    private let identity: DocumentIdentifying
    private let xpointers: XPointerGenerating

    public init(identity: DocumentIdentifying = DocumentIdentity(),
                xpointers: XPointerGenerating = XPointerGenerator()) {
        self.identity = identity
        self.xpointers = xpointers
    }

    public func process(epubAt url: URL) throws -> ProcessedBook {
        let zip = try ZipReader(url: url)

        // container.xml -> package document
        guard zip.contains("META-INF/container.xml") else { throw EPUBError.missingContainer }
        let container = try XMLTreeBuilder.parse(try zip.data(at: "META-INF/container.xml"), what: "container.xml")
        let rootfiles = container.descendants("rootfile")
        let rootfile = rootfiles.first { ($0.attributes["media-type"] ?? "").contains("opf") } ?? rootfiles.first
        guard let opfRaw = rootfile?.attributes["full-path"], let opfPath = ZipReader.normalize(Self.percentDecode(opfRaw)),
              zip.contains(opfPath) else { throw EPUBError.missingPackageDocument }

        let package = try Self.parsePackage(try XMLTreeBuilder.parse(try zip.data(at: opfPath), what: "package document"),
                                            opfPath: opfPath, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        guard !package.spine.isEmpty else { throw EPUBError.emptySpine }

        let titles = Self.chapterTitles(package: package, zip: zip)

        var chapters: [Chapter] = []
        var offset = 0
        for (i, item) in package.spine.enumerated() {
            let spineIndex = i + 1
            guard Self.isXHTML(item), zip.contains(item.path), let data = try? zip.data(at: item.path) else { continue }
            let raw = BlockExtractor.extract(from: data).blocks
            guard !raw.isEmpty else { continue }
            var blocks: [Block] = []
            blocks.reserveCapacity(raw.count)
            for r in raw {
                blocks.append(Block(text: r.text, style: r.style, spans: r.spans,
                                    xpointer: xpointers.xpointer(spineIndex: spineIndex, path: r.path, textOffset: 0),
                                    globalOffset: offset))
                offset += r.text.count
            }
            let title = titles[item.path] ?? blocks.first(where: { Self.isHeading($0.style) })?.text
            chapters.append(Chapter(spineIndex: spineIndex, title: title, blocks: blocks))
        }

        let documentHash = try identity.partialMD5(fileAt: url)
        return ProcessedBook(metadata: package.metadata, documentHash: documentHash,
                             metaHash: identity.metaHash(for: package.metadata),
                             chapters: chapters, totalCharacters: offset)
    }

    // MARK: - Package document

    struct ManifestItem {
        var id: String
        var path: String
        var mediaType: String
        var properties: [String]
    }

    struct Package {
        var metadata: BookMetadata
        var manifest: [String: ManifestItem]
        var spine: [ManifestItem]
        var tocID: String?
    }

    static func parsePackage(_ root: XMLNode, opfPath: String, fallbackTitle: String) throws -> Package {
        guard root.name == "package" else { throw EPUBError.malformedXML("package document: unexpected root <\(root.name)>") }

        var title: String?
        var authors: [String] = []
        var language: String?
        var identifiers: [BookIdentifier] = []
        for md in root.children where md.name == "metadata" {
            for node in md.children {
                let value = node.trimmedText
                guard !value.isEmpty else { continue }
                switch node.name {
                case "title": if title == nil { title = value }
                case "creator": authors.append(value)
                case "language": if language == nil { language = value }
                case "identifier":
                    let scheme = node.attributes["opf:scheme"] ?? node.attributes["scheme"]
                    identifiers.append(BookIdentifier(scheme: scheme, value: value))
                default: break
                }
            }
        }
        let metadata = BookMetadata(title: title ?? fallbackTitle, authors: authors, language: language,
                                    identifiers: identifiers)

        var manifest: [String: ManifestItem] = [:]
        for item in root.descendants("item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"],
                  let path = resolve(href, relativeTo: opfPath) else { continue }
            manifest[id] = ManifestItem(
                id: id, path: path, mediaType: (item.attributes["media-type"] ?? "").lowercased(),
                properties: (item.attributes["properties"] ?? "").split(separator: " ").map(String.init))
        }

        var spine: [ManifestItem] = []
        var tocID: String?
        if let spineNode = root.child("spine") {
            tocID = spineNode.attributes["toc"]
            for ref in spineNode.children where ref.name == "itemref" {
                if let id = ref.attributes["idref"], let item = manifest[id] { spine.append(item) }
            }
        }
        return Package(metadata: metadata, manifest: manifest, spine: spine, tocID: tocID)
    }

    static func isXHTML(_ item: ManifestItem) -> Bool {
        if item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" || item.mediaType == "application/x-dtbook+xml" {
            return true
        }
        let ext = (item.path as NSString).pathExtension.lowercased()
        return item.mediaType.isEmpty && ["xhtml", "html", "htm", "xml"].contains(ext)
    }

    static func isHeading(_ s: BlockStyle) -> Bool {
        switch s {
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: return true
        default: return false
        }
    }

    // MARK: - Table of contents (best effort)

    /// Maps a spine item's archive path to the first TOC label that points at it.
    static func chapterTitles(package: Package, zip: ZipReader) -> [String: String] {
        var titles: [String: String] = [:]
        func add(_ label: String, _ href: String, base: String) {
            guard !label.isEmpty, let path = resolve(href, relativeTo: base), titles[path] == nil else { return }
            titles[path] = label
        }
        // EPUB 3 navigation document
        if let navItem = package.manifest.values.first(where: { $0.properties.contains("nav") }),
           let data = try? zip.data(at: navItem.path), let root = try? XMLTreeBuilder.parse(data, what: "nav") {
            let navs = root.descendants("nav")
            let toc = navs.first { ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").contains("toc") } ?? navs.first
            for a in toc?.descendants("a") ?? [] {
                if let href = a.attributes["href"] { add(a.trimmedText, href, base: navItem.path) }
            }
        }
        // EPUB 2 NCX
        let ncxItem = package.tocID.flatMap { package.manifest[$0] }
            ?? package.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        if let ncxItem, let data = try? zip.data(at: ncxItem.path),
           let root = try? XMLTreeBuilder.parse(data, what: "ncx") {
            for point in root.descendants("navpoint") {
                let label = point.child("navlabel")?.descendants("text").first?.trimmedText ?? ""
                if let src = point.child("content")?.attributes["src"] { add(label, src, base: ncxItem.path) }
            }
        }
        return titles
    }

    // MARK: - Paths

    static func percentDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }

    /// Resolves `href` against the archive path of the referencing file. Returns nil for external or unsafe references.
    static func resolve(_ href: String, relativeTo basePath: String) -> String? {
        var ref = href
        if let i = ref.firstIndex(where: { $0 == "#" || $0 == "?" }) { ref = String(ref[..<i]) }
        guard !ref.isEmpty, !ref.contains("://"), !ref.lowercased().hasPrefix("data:"), !ref.lowercased().hasPrefix("mailto:")
        else { return nil }
        ref = percentDecode(ref)
        if ref.hasPrefix("/") { return ZipReader.normalize(String(ref.dropFirst())) }
        let dir = basePath.contains("/") ? String(basePath[..<basePath.lastIndex(of: "/")!]) : ""
        return ZipReader.normalize(dir.isEmpty ? ref : dir + "/" + ref)
    }
}
