import Foundation
import ReaderCore

/// Sendable wrapper to move a decoded book across concurrency domains.
struct ProcessedBookBox: @unchecked Sendable {
    let book: ProcessedBook
}
