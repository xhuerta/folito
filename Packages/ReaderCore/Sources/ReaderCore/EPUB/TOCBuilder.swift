import Foundation

/// Builds `ProcessedBook.toc`: the EPUB 3 nav first, the NCX when the nav is missing or resolves to nothing,
/// then h1–h3 headings. Mirrors what crengine, foliate-js and Readium do (see `TOCEntry`).
enum TOCBuilder {
    /// A TOC node before resolution, flattened in pre-order.
    struct RawEntry: Equatable {
        var title: String
        var depth: Int
        /// Archive path of the target document; nil for a group heading (nav `<span>`) or an external link.
        var path: String?
        /// Percent-decoded `#fragment`, if any.
        var fragment: String?
        /// The label was a nav `<span>` (or had no usable link) and the node only groups its children.
        var isGroupHeading: Bool
    }

    /// Nav `epub:type`s that are never the table of contents.
    static let nonTOCNavTypes: Set<String> = ["landmarks", "page-list", "lot", "loi", "loa", "lov"]

    // MARK: - Sources

    /// Entries of `<nav epub:type="toc">` in the package's nav document. `hidden` is ignored on purpose: it only
    /// affects rendering the nav document as content, reading systems still use those entries.
    static func navEntries(package: EPUBParser.Package, zip: ZipReader) -> [RawEntry] {
        guard let navItem = package.manifest.values.first(where: { $0.properties.contains("nav") }),
              let data = try? zip.data(at: navItem.path), let root = try? XMLTreeBuilder.parse(data, what: "nav")
        else { return [] }
        func types(_ n: XMLNode) -> [String] {
            (n.attributes["epub:type"] ?? n.attributes["type"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        let navs = root.descendants("nav")
        guard let toc = navs.first(where: { types($0).contains("toc") })
                ?? navs.first(where: { types($0).allSatisfy { !nonTOCNavTypes.contains($0) } }),
              let ol = toc.descendants("ol").first else { return [] }
        var out: [RawEntry] = []
        func walk(_ ol: XMLNode, depth: Int) {
            for li in ol.children where li.name == "li" {
                let label = li.children.first { $0.name == "a" || $0.name == "span" }
                let sub = li.child("ol")
                var title = label?.trimmedText ?? li.trimmedTextExcludingLists
                if title.isEmpty { title = label?.attributes["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                let href = label?.name == "a" ? label?.attributes["href"] : nil
                let target = href.flatMap { split($0, base: navItem.path) }
                guard target != nil || sub != nil else { continue }  // nothing to show or open
                out.append(RawEntry(title: title, depth: depth, path: target?.path, fragment: target?.fragment,
                                    isGroupHeading: target == nil))
                if let sub { walk(sub, depth: depth + 1) }
            }
        }
        walk(ol, depth: 0)
        return out
    }

    /// Entries of the NCX `navMap` (nested `navPoint`s, in tree order; `playOrder` is ignored as it is often wrong).
    static func ncxEntries(package: EPUBParser.Package, zip: ZipReader) -> [RawEntry] {
        let ncxItem = package.tocID.flatMap { package.manifest[$0] }
            ?? package.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
        guard let ncxItem, let data = try? zip.data(at: ncxItem.path),
              let root = try? XMLTreeBuilder.parse(data, what: "ncx"),
              let navMap = root.descendants("navmap").first else { return [] }
        var out: [RawEntry] = []
        func walk(_ parent: XMLNode, depth: Int) {
            for point in parent.children where point.name == "navpoint" {
                let title = point.child("navlabel")?.descendants("text").first?.trimmedText ?? ""
                let target = point.child("content")?.attributes["src"].flatMap { split($0, base: ncxItem.path) }
                let hasChildren = point.children.contains { $0.name == "navpoint" }
                guard target != nil || hasChildren else { continue }
                out.append(RawEntry(title: title, depth: depth, path: target?.path, fragment: target?.fragment,
                                    isGroupHeading: target == nil))
                walk(point, depth: depth + 1)
            }
        }
        walk(navMap, depth: 0)
        return out
    }

    /// Splits an href into the resolved archive path and the percent-decoded fragment.
    static func split(_ href: String, base: String) -> (path: String, fragment: String?)? {
        guard let path = EPUBParser.resolve(href, relativeTo: base) else { return nil }
        guard let hash = href.firstIndex(of: "#") else { return (path, nil) }
        let fragment = EPUBParser.percentDecode(String(href[href.index(after: hash)...]))
        return (path, fragment.isEmpty ? nil : fragment)
    }

    /// Fragment ids each document must locate while its blocks are extracted.
    static func wantedIDs(_ entries: [RawEntry]...) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for list in entries {
            for e in list { if let p = e.path, let f = e.fragment { out[p, default: []].insert(f) } }
        }
        return out
    }

    // MARK: - Resolution

    /// What the resolver needs to know about the extracted chapters.
    struct Context {
        var chapters: [Chapter]
        /// Archive path -> 1-based spine index (first occurrence).
        var spineIndexByPath: [String: Int]
        /// Per chapter (index into `chapters`): fragment id -> location.
        var anchors: [[String: AnchorTarget]]

        func chapterIndex(forSpineIndex s: Int) -> Int? { chapters.firstIndex { $0.spineIndex == s } }

        /// Rules: no fragment or unknown id -> the document's first block; an id past the document's last block ->
        /// the next chapter's start; a spine item without text -> the next chapter's start; a file outside the
        /// spine (or a missing one) -> nil.
        func position(path: String?, fragment: String?) -> BookPosition? {
            guard let path, let spine = spineIndexByPath[path] else { return nil }
            guard let ci = chapterIndex(forSpineIndex: spine) else {
                return chapters.firstIndex { $0.spineIndex > spine }.map { BookPosition(chapterIndex: $0, blockIndex: 0) }
            }
            guard let fragment, let a = anchors[ci][fragment] else { return BookPosition(chapterIndex: ci, blockIndex: 0) }
            if a.blockIndex < chapters[ci].blocks.count {
                return BookPosition(chapterIndex: ci, blockIndex: a.blockIndex, characterOffset: a.characterOffset)
            }
            if ci + 1 < chapters.count { return BookPosition(chapterIndex: ci + 1, blockIndex: 0) }
            return BookPosition(chapterIndex: ci, blockIndex: max(0, chapters[ci].blocks.count - 1))
        }
    }

    /// Resolves raw entries. Group headings take their first descendant's position; empty labels fall back to
    /// the target block's text. Returns nil when no entry resolves (the source is unusable).
    static func resolve(_ raw: [RawEntry], in context: Context) -> [TOCEntry]? {
        var out = raw.map { r in
            TOCEntry(title: r.title, depth: r.depth, position: context.position(path: r.path, fragment: r.fragment),
                     isGroupHeading: r.isGroupHeading)
        }
        guard out.contains(where: { $0.position != nil }) else { return nil }
        for i in out.indices where out[i].position == nil && out[i].isGroupHeading {
            var j = i + 1
            while j < out.count, out[j].depth > out[i].depth {
                if let p = out[j].position { out[i].position = p; break }
                j += 1
            }
        }
        for i in out.indices where out[i].title.isEmpty {
            if let p = out[i].position { out[i].title = label(context.chapters[p.chapterIndex].blocks[p.blockIndex].text) }
        }
        // Drop leaves that have neither a label nor a target; parents stay so that depths remain contiguous.
        return out.indices.filter { i in
            let isParent = i + 1 < out.count && out[i + 1].depth > out[i].depth
            return isParent || !out[i].title.isEmpty || out[i].position != nil
        }.map { out[$0] }
    }

    /// Fallback TOC from h1–h3 blocks; depth follows the heading level relative to the shallowest one used.
    static func headingEntries(_ chapters: [Chapter]) -> [TOCEntry]? {
        func level(_ s: BlockStyle) -> Int? {
            switch s {
            case .heading1: return 1
            case .heading2: return 2
            case .heading3: return 3
            default: return nil
            }
        }
        var found: [(level: Int, title: String, position: BookPosition)] = []
        for (ci, ch) in chapters.enumerated() {
            for (bi, b) in ch.blocks.enumerated() {
                if let l = level(b.style) { found.append((l, label(b.text), BookPosition(chapterIndex: ci, blockIndex: bi))) }
            }
        }
        guard let top = found.map(\.level).min() else { return nil }
        var out: [TOCEntry] = []
        var previousDepth = -1
        for f in found {
            let depth = min(f.level - top, previousDepth + 1)  // keep child depth == parent depth + 1
            out.append(TOCEntry(title: f.title, depth: depth, position: f.position))
            previousDepth = depth
        }
        return out
    }

    /// A one-line label from block text.
    static func label(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// The book's TOC and its source: nav, else NCX, else headings, else nil (the spine list stays the fallback).
    static func build(nav: [RawEntry], ncx: [RawEntry], context: Context) -> (toc: [TOCEntry], source: TOCSource)? {
        if let toc = resolve(nav, in: context) { return (toc, .nav) }
        if let toc = resolve(ncx, in: context) { return (toc, .ncx) }
        if let toc = headingEntries(context.chapters) { return (toc, .headings) }
        return nil
    }
}

extension XMLNode {
    /// Own text of an element, without nested lists (a nav `<li>` that has no `<a>`/`<span>` label).
    var trimmedTextExcludingLists: String {
        let parts = [text] + children.filter { $0.name != "ol" && $0.name != "ul" }.map(\.textContent)
        return parts.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
