import Foundation

/// A parsed KOReader/crengine XPointer of the DocFragment form.
///
/// Grammar accepted (tolerant superset of what crengine `toStringV2()` emits and of what
/// Readest pushes):
///
///     /body/DocFragment[N]/body[/name[k]]*[/text()[k]][.OFFSET]
///
/// `[N]`/`[k]` are optional (default 1). `.OFFSET` may follow a `text()` step (crengine text
/// point) or an element step (crengine element point, e.g. `div[1].0`).
public struct ParsedXPointer: Equatable, Sendable {
    /// 1-based spine index (`DocFragment[N]`; 1 when the index is omitted).
    public var spineIndex: Int
    /// Element steps below `<body>`, names lowercased, indices 1-based.
    public var steps: [PathStep]
    /// Whether the path ended in a `text()` step.
    public var hasTextStep: Bool
    /// The `k` of `text()[k]` (1 when omitted); nil if there is no `text()` step.
    public var textIndex: Int?
    /// The trailing `.OFFSET`, if any (UTF-32 code points for text points, child index for
    /// element points).
    public var offset: Int?

    public init(spineIndex: Int, steps: [PathStep], hasTextStep: Bool = false,
                textIndex: Int? = nil, offset: Int? = nil) {
        self.spineIndex = spineIndex
        self.steps = steps
        self.hasTextStep = hasTextStep
        self.textIndex = textIndex
        self.offset = offset
    }

    /// Parse; returns nil for anything that is not a well-formed DocFragment XPointer.
    public static func parse(_ raw: String) -> ParsedXPointer? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/body/DocFragment"
        guard s.hasPrefix(prefix) else { return nil }
        var rest = Substring(s.dropFirst(prefix.count))

        // Optional [N].
        var spine = 1
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            guard let n = positiveInt(rest[rest.index(after: rest.startIndex)..<close]) else { return nil }
            spine = n
            rest = rest[rest.index(after: close)...]
        }
        if rest.isEmpty { return ParsedXPointer(spineIndex: spine, steps: []) }
        guard rest.hasPrefix("/") else { return nil }
        rest = rest.dropFirst()

        var comps = rest.split(separator: "/", omittingEmptySubsequences: false).map(Substring.init)
        if comps.last?.isEmpty == true { comps.removeLast() }   // tolerate one trailing slash
        guard !comps.isEmpty, !comps.contains(where: { $0.isEmpty }) else { return nil }

        // `body` (optionally `body[1]`).
        guard let bodyStep = parseElementComponent(comps[0], allowOffset: false),
              bodyStep.step.name == "body", bodyStep.step.index == 1 else {
            // `/body/DocFragment[N].0`-style (offset directly after the fragment) is not supported.
            return nil
        }
        comps.removeFirst()

        var result = ParsedXPointer(spineIndex: spine, steps: [])
        for (i, comp) in comps.enumerated() {
            let isLast = i == comps.count - 1
            if comp.hasPrefix("text()") {
                guard isLast else { return nil }
                var tail = comp.dropFirst("text()".count)
                var off: Int?
                if let dot = tail.lastIndex(of: ".") {
                    guard let o = nonNegativeInt(tail[tail.index(after: dot)...]) else { return nil }
                    off = o
                    tail = tail[..<dot]
                }
                var k = 1
                if !tail.isEmpty {
                    guard tail.hasPrefix("["), tail.hasSuffix("]"),
                          let n = positiveInt(tail.dropFirst().dropLast()) else { return nil }
                    k = n
                }
                result.hasTextStep = true
                result.textIndex = k
                result.offset = off
            } else {
                guard let parsed = parseElementComponent(comp, allowOffset: isLast) else { return nil }
                result.steps.append(parsed.step)
                result.offset = parsed.offset
            }
        }
        return result
    }

    private static func parseElementComponent(_ comp: Substring, allowOffset: Bool)
        -> (step: PathStep, offset: Int?)? {
        var body = comp
        var off: Int?
        if let dot = body.lastIndex(of: ".") {
            guard allowOffset, let o = nonNegativeInt(body[body.index(after: dot)...]) else { return nil }
            off = o
            body = body[..<dot]
        }
        var name = body
        var index = 1
        if let open = body.firstIndex(of: "[") {
            guard body.hasSuffix("]"),
                  let n = positiveInt(body[body.index(after: open)..<body.index(before: body.endIndex)])
            else { return nil }
            index = n
            name = body[..<open]
        }
        guard isValidName(name) else { return nil }
        return (PathStep(name: name.lowercased(), index: index), off)
    }

    private static func isValidName(_ s: Substring) -> Bool {
        guard let first = s.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ":"
        }
    }

    private static func positiveInt(_ s: Substring) -> Int? {
        guard let n = nonNegativeInt(s), n >= 1 else { return nil }
        return n
    }

    private static func nonNegativeInt(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(s)   // nil on overflow
    }
}

enum OffsetConversion {
    /// crengine offsets count UTF-32 code points; `BookPosition.characterOffset` counts `Character`s.
    static func characterOffset(forScalarOffset scalars: Int, in text: String) -> Int {
        guard scalars > 0 else { return 0 }
        var seen = 0
        var chars = 0
        for ch in text {
            if seen >= scalars { break }
            seen += ch.unicodeScalars.count
            chars += 1
        }
        return chars
    }

    static func scalarOffset(forCharacterOffset offset: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        var scalars = 0
        for (i, ch) in text.enumerated() {
            if i >= offset { break }
            scalars += ch.unicodeScalars.count
        }
        return scalars
    }
}
