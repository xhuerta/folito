import Foundation

/// The parts of an EPUB CFI that Folito can place in a `ProcessedBook`: the spine item and the element
/// path below `<body>`. Character offsets, text-node steps, id assertions and the range end are dropped.
///
/// Readest stores the CFI foliate-js reports for the visible page, usually a range CFI:
/// `epubcfi(/6/24!/4/2[chap]/14,/1:0,/3:120)` = common parent `/6/24!/4/2/14` + start `/1:0` + end.
/// Steps (EPUB CFI 3.1):
/// - `/6/N` before `!`: `/6` is the package's `<spine>`, `N / 2` the 1-based `<itemref>` (`DocFragment[N/2]`);
/// - after `!`: the first step is `<body>` (`/4`: `<head>` is `/2`), then even steps are element children
///   (`step / 2` = 1-based index among the element children, whatever their names) and odd steps are the
///   text between elements, which ends the element path;
/// - `[...]` are id assertions (`^` escapes), `:n` / `~t` / `@x:y` are offsets.
public struct EPUBCFI: Equatable, Sendable {
    /// 1-based spine item index (crengine `DocFragment[N]`, Folito `Chapter.spineIndex`).
    public var spineIndex: Int
    /// 1-based element-child indices below `<body>`, outermost first.
    public var elementPath: [Int]

    public init(spineIndex: Int, elementPath: [Int]) {
        self.spineIndex = spineIndex
        self.elementPath = elementPath
    }

    /// Parses `epubcfi(...)` or a bare path; nil for anything malformed.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("epubcfi(") {
            guard s.hasSuffix(")") else { return nil }
            s = String(s.dropFirst("epubcfi(".count).dropLast())
        }
        guard let plain = Self.removingAssertions(s) else { return nil }
        // Range CFI: "parent,start,end" -> parent + start.
        let parts = plain.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let path: String
        switch parts.count {
        case 1: path = parts[0]
        case 3: path = parts[0] + parts[1]
        default: return nil
        }
        // Offsets (`:n`, `~t`, `@x:y`) only end the last step.
        let stepsOnly = String(path.prefix { $0 != ":" && $0 != "~" && $0 != "@" })
        let hops = stepsOnly.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
        guard hops.count >= 2,
              let package = Self.steps(hops[0]), package.count == 2,
              let content = Self.steps(hops[1]), !content.isEmpty else { return nil }
        let itemref = package[1]
        guard itemref % 2 == 0 else { return nil }
        var elements: [Int] = []
        for step in content.dropFirst() {   // the first step is <body>
            guard step % 2 == 0 else { break }
            elements.append(step / 2)
        }
        self.init(spineIndex: itemref / 2, elementPath: elements)
    }

    /// "/4/2/10" -> [4, 2, 10]; nil unless every step is a positive integer.
    private static func steps(_ s: String) -> [Int]? {
        guard s.hasPrefix("/") else { return nil }
        let parts = s.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), n > 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// Strips `[...]` assertions (honouring `^` escapes); nil when a bracket is left open.
    private static func removingAssertions(_ s: String) -> String? {
        var out = ""
        var inside = false
        var escaped = false
        for ch in s {
            if escaped { escaped = false; if !inside { out.append(ch) }; continue }
            if ch == "^" { escaped = true; continue }
            if inside {
                if ch == "]" { inside = false }
                continue
            }
            if ch == "[" { inside = true; continue }
            if ch == "]" { return nil }
            out.append(ch)
        }
        return inside ? nil : out
    }
}

public enum CFIResolver {
    /// The block `cfi` points into, at the block's start.
    ///
    /// Folito keeps only text blocks, with XPointer paths of tag names and same-name indices, so the CFI's
    /// element indices (counted over *all* element children) are matched level by level against the
    /// distinct child elements the chapter's blocks go through, in document order. Exact when every sibling
    /// element holds text (the usual run of `<p>`s); siblings without text (images, empty anchors, `<hr>`)
    /// are not counted, which can move the result a few blocks later in the same chapter. An index past the
    /// last known child clamps to it; a path that ends inside a block (inline markup) gives that block.
    /// A spine item without text gives the next chapter's start; nil when no chapter follows.
    public static func position(for cfi: EPUBCFI, in book: ProcessedBook) -> BookPosition? {
        guard let ci = book.chapters.firstIndex(where: { $0.spineIndex >= cfi.spineIndex }) else { return nil }
        let chapter = book.chapters[ci]
        guard !chapter.blocks.isEmpty else { return BookPosition(chapterIndex: ci, blockIndex: 0) }
        guard chapter.spineIndex == cfi.spineIndex else { return BookPosition(chapterIndex: ci, blockIndex: 0) }
        let paths: [[PathStep]] = chapter.blocks.map { ParsedXPointer.parse($0.xpointer)?.steps ?? [] }
        var candidates = Array(paths.indices)
        for (depth, k) in cfi.elementPath.enumerated() {
            let deeper = candidates.filter { paths[$0].count > depth }
            var children: [PathStep] = []
            for i in deeper where !children.contains(paths[i][depth]) { children.append(paths[i][depth]) }
            guard !children.isEmpty else { break }
            let chosen = children[min(k, children.count) - 1]
            candidates = deeper.filter { paths[$0][depth] == chosen }
            if k > children.count { break }
        }
        return BookPosition(chapterIndex: ci, blockIndex: candidates.first ?? 0)
    }
}

public extension ReadingPosition {
    /// The remote position to use for `book` once its `cfi` (Readest's `location`) is taken into account.
    ///
    /// The watch pushes only `xpointer` and `progress`, so a Readest row can be mixed: its CFI is where the
    /// Readest apps are, its XPointer where the watch was. When the CFI resolves to a spot further than
    /// the XPointer (or, if that does not resolve, than the row's fraction) by more than `tolerance`, the
    /// CFI spot is returned, with this book's XPointer and character percentage and no page fields;
    /// otherwise (they agree, or the CFI is behind) `self`. Without an XPointer the CFI spot is used;
    /// without a usable CFI, `self`.
    func resolvingCFI(in book: ProcessedBook, tolerance: Double = 0.005) -> ReadingPosition {
        guard let raw = cfi, let parsed = EPUBCFI(raw),
              let pos = CFIResolver.position(for: parsed, in: book),
              let located = XPointerResolver().locate(pos, in: book) else { return self }
        let fromCFI = ReadingPosition(xpointer: located.xpointer, percentage: located.percentage,
                                      chapter: chapter, timestamp: timestamp,
                                      deviceID: deviceID, deviceName: deviceName)
        // CFI only (the Readest app could not convert it): its `progress` is a page fraction, the CFI is exact.
        if xpointer.isEmpty { return fromCFI }
        var rowPercentage = percentage
        if !xpointer.isEmpty,
           case .position(let p, _)? = XPointerResolver().resolve(xpointer, percentage: nil, in: book),
           let l = XPointerResolver().locate(p, in: book) {
            rowPercentage = l.percentage
        }
        return fromCFI.percentage > rowPercentage + tolerance ? fromCFI : self
    }
}
