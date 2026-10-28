import Foundation

/// One step of an element path: tag name plus 1-based index among same-named siblings.
public struct PathStep: Codable, Sendable, Equatable {
    public var name: String
    public var index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }
}

/// Builds KOReader/crengine-style XPointers:
/// `/body/DocFragment[N]/body/<path>/text().OFFSET`
public protocol XPointerGenerating: Sendable {
    /// - Parameters:
    ///   - spineIndex: 1-based spine item index (`DocFragment[N]`).
    ///   - path: element steps below the XHTML `<body>`.
    ///   - textOffset: character offset into the element's text node; nil omits `text()`.
    func xpointer(spineIndex: Int, path: [PathStep], textOffset: Int?) -> String
}

public enum XPointerResolution: Equatable, Sendable {
    /// Resolved exactly (possibly after trimming the path backwards).
    case position(BookPosition, trimmedSteps: Int)
    /// XPointer unusable; fall back to a 0…1 book percentage.
    case percentage(Double)
}

public protocol XPointerResolving: Sendable {
    /// Resolve `xpointer` in `book`. Trim the path backwards on failure (as the Readest plugin does),
    /// then fall back to `percentage` (0…1).
    func resolve(_ xpointer: String, percentage: Double?, in book: ProcessedBook) -> XPointerResolution?
}

public struct XPointerGenerator: XPointerGenerating {
    public init() {}

    /// Like crengine, `[1]` is omitted (the first/only sibling); `[k]` is emitted for k > 1.
    /// `textOffset == nil` omits the whole `/text().N` tail.
    public func xpointer(spineIndex: Int, path: [PathStep], textOffset: Int?) -> String {
        var out = "/body/DocFragment[\(max(1, spineIndex))]/body"
        for step in path {
            out += "/" + step.name
            if step.index > 1 { out += "[\(step.index)]" }
        }
        if let off = textOffset { out += "/text().\(max(0, off))" }
        return out
    }
}

public struct XPointerResolver: XPointerResolving {
    public init() {}

    public func resolve(_ xpointer: String, percentage: Double?, in book: ProcessedBook) -> XPointerResolution? {
        let fallback = Self.usable(percentage).map { XPointerResolution.percentage($0) }
        guard let target = ParsedXPointer.parse(xpointer),
              let ci = book.chapters.firstIndex(where: { $0.spineIndex == target.spineIndex }),
              !book.chapters[ci].blocks.isEmpty else { return fallback }
        let chapter = book.chapters[ci]
        let blocks: [[PathStep]?] = chapter.blocks.map { ParsedXPointer.parse($0.xpointer)?.steps }

        // Try the full path, then trim element steps backwards (never down to zero steps).
        var trimmed = 0
        while target.steps.count - trimmed >= 1 {
            let steps = Array(target.steps.dropLast(trimmed))
            if let (bi, exact) = Self.match(steps, in: blocks) {
                var offset = 0
                if trimmed == 0, exact, target.hasTextStep, (target.textIndex ?? 1) == 1, let o = target.offset {
                    let text = chapter.blocks[bi].text
                    offset = min(OffsetConversion.characterOffset(forScalarOffset: o, in: text), text.count)
                }
                return .position(BookPosition(chapterIndex: ci, blockIndex: bi, characterOffset: offset),
                                 trimmedSteps: trimmed)
            }
            trimmed += 1
        }
        // Only the chapter is known (or nothing matched): prefer the percentage, else chapter start.
        if let fb = fallback, !target.steps.isEmpty { return fb }
        return .position(BookPosition(chapterIndex: ci, blockIndex: 0, characterOffset: 0),
                         trimmedSteps: target.steps.count)
    }

    /// Returns (block index, whether the block path equals the target path exactly).
    private static func match(_ steps: [PathStep], in blocks: [[PathStep]?]) -> (Int, Bool)? {
        if let i = blocks.firstIndex(where: { $0 == steps }) { return (i, true) }
        // Block is an ancestor of the target (target points into inline markup): longest wins.
        var best: (Int, Int)?
        for (i, b) in blocks.enumerated() {
            guard let b, b.count < steps.count, Array(steps.prefix(b.count)) == b else { continue }
            if best == nil || b.count > best!.1 { best = (i, b.count) }
        }
        if let best { return (best.0, false) }
        // Target is a container of blocks: first block inside it.
        if let i = blocks.firstIndex(where: { b in
            guard let b, b.count > steps.count else { return false }
            return Array(b.prefix(steps.count)) == steps
        }) { return (i, false) }
        return nil
    }

    private static func usable(_ p: Double?) -> Double? {
        guard let p, p.isFinite else { return nil }
        return min(1, max(0, p))
    }

    /// Reverse helper: reading position -> (XPointer, 0…1 percentage).
    public func locate(_ position: BookPosition, in book: ProcessedBook)
        -> (xpointer: String, percentage: Double)? {
        guard book.chapters.indices.contains(position.chapterIndex) else { return nil }
        let chapter = book.chapters[position.chapterIndex]
        guard chapter.blocks.indices.contains(position.blockIndex) else { return nil }
        let block = chapter.blocks[position.blockIndex]
        let offset = min(max(0, position.characterOffset), block.text.count)

        var xp = block.xpointer
        if offset > 0, let parsed = ParsedXPointer.parse(block.xpointer) {
            xp = XPointerGenerator().xpointer(
                spineIndex: parsed.spineIndex, path: parsed.steps,
                textOffset: OffsetConversion.scalarOffset(forCharacterOffset: offset, in: block.text))
        }
        let pct = book.totalCharacters > 0
            ? min(1, max(0, Double(block.globalOffset + offset) / Double(book.totalCharacters))) : 0
        return (xp, pct)
    }
}
