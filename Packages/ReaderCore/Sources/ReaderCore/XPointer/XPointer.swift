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
    public func xpointer(spineIndex: Int, path: [PathStep], textOffset: Int?) -> String { "" }
}

public struct XPointerResolver: XPointerResolving {
    public init() {}
    public func resolve(_ xpointer: String, percentage: Double?, in book: ProcessedBook) -> XPointerResolution? { nil }
}
