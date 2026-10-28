import Foundation

public enum EPUBError: Error, Equatable {
    case notImplemented
    case invalidArchive
    case missingContainer
    case missingPackageDocument
    case malformedXML(String)
    case emptySpine
}

/// Turns an EPUB file into a `ProcessedBook` (metadata, hashes, chapters, blocks with XPointers).
public protocol EPUBParsing: Sendable {
    func process(epubAt url: URL) throws -> ProcessedBook
}

public struct EPUBParser: EPUBParsing {
    public init() {}
    public func process(epubAt url: URL) throws -> ProcessedBook { throw EPUBError.notImplemented }
}
