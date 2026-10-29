import Foundation
import ReaderCore

/// User-facing status and error texts of the watch app. Pure and unit-tested: every failure says what
/// happened and what the user can do about it (no bare "Error").
enum WatchMessages {
    // MARK: Opening a book

    static func bookOpenFailure(_ error: Error) -> String {
        if let e = error as? BookStorageError, case .unsupportedFormat = e {
            return String(localized: "This book was prepared by a newer version of Folito. Update the app on your iPhone and Apple Watch, then send the book again.",
                          comment: "Opening a book failed: its file format is newer than this app")
        }
        if let e = error as? CocoaError, e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return String(localized: "This book's file is missing from your watch. Delete it here and send it again from Folito on your iPhone.",
                          comment: "Opening a book failed: its file is gone")
        }
        return String(localized: "This book's file is damaged. Delete it here and send it again from Folito on your iPhone.",
                      comment: "Opening a book failed: the stored file could not be read")
    }

    // MARK: Settings > Check server

    /// Result of the last "Check server" (nil: not checked yet).
    static func connection(_ result: SyncCoordinator.ConnectionResult?) -> String {
        switch result {
        case nil:
            return String(localized: "Not checked yet.", comment: "Sync server status before the user checks it")
        case .ok?:
            return String(localized: "Connected. Progress syncs with your server.", comment: "Sync server status")
        case .unauthorized?:
            return String(localized: "Wrong username or password. Fix them in Folito on your iPhone.",
                          comment: "Sync server status: rejected credentials")
        case .offline?:
            return String(localized: "Can't reach the server. Check that your watch or iPhone is online, then try again.",
                          comment: "Sync server status: no connection")
        case .notConfigured?:
            return String(localized: "Sync isn't set up. Set it up in Folito on your iPhone.",
                          comment: "Sync server status: no credentials")
        case .failed?:
            return String(localized: "The server didn't respond as expected. Check the server address in Folito on your iPhone.",
                          comment: "Sync server status: unexpected server response")
        }
    }

    // MARK: Dictionary

    static func dictionary(_ error: DictionaryError) -> String {
        switch error {
        case .offline:
            return String(localized: "You're offline. Connect to Wi-Fi or your iPhone to look up new words; words you looked up before still work.",
                          comment: "Dictionary lookup failed: no network")
        case .notFound:
            return String(localized: "No definition found for this word. Try another form of it, such as the singular.",
                          comment: "Dictionary lookup: the word is not in the dictionary")
        case .rateLimited:
            return String(localized: "The dictionary is busy. Wait a moment, then try again.",
                          comment: "Dictionary lookup failed: rate limited")
        case .server(let status):
            return String(localized: "The dictionary service isn't working right now (error \(status)). Try again later.",
                          comment: "Dictionary lookup failed with an HTTP status code (the number)")
        case .invalidResponse:
            return String(localized: "The dictionary sent an answer Folito can't read. Try again later.",
                          comment: "Dictionary lookup failed: response could not be parsed")
        }
    }

    // MARK: Sync status glyph

    /// VoiceOver label of the reader's sync glyph (nil while idle: nothing is shown).
    static func syncStatus(_ status: SyncStatus) -> String? {
        switch status {
        case .idle: return nil
        case .syncing: return String(localized: "Syncing reading progress", comment: "Accessibility label of the sync glyph")
        case .offline: return String(localized: "Offline. Progress will sync when you're connected.",
                                     comment: "Accessibility label of the sync glyph")
        case .error: return String(localized: "Sync failed. Check the server in Settings.",
                                   comment: "Accessibility label of the sync glyph")
        }
    }
}
