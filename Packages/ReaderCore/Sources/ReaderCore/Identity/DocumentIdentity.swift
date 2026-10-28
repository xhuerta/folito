import Foundation

public enum IdentityError: Error, Equatable {
    case notImplemented
    case unreadableFile
}

/// Document identifiers used by KOReader and Readest.
public protocol DocumentIdentifying: Sendable {
    /// KOReader `util.partialMD5` of the file contents, lowercase hex.
    func partialMD5(fileAt url: URL) throws -> String
    /// Same algorithm over in-memory data.
    func partialMD5(of data: Data) -> String
    /// Readest `generateMetadataHash`: md5("title|authors|identifier"), lowercase hex.
    func metaHash(for metadata: BookMetadata) -> String
}

public struct DocumentIdentity: DocumentIdentifying {
    public init() {}
    public func partialMD5(fileAt url: URL) throws -> String { throw IdentityError.notImplemented }
    public func partialMD5(of data: Data) -> String { "" }
    public func metaHash(for metadata: BookMetadata) -> String { "" }
}
