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
        case .noDictionary:
            return String(localized: "No dictionary on this watch yet. Download one in Folito on your iPhone: Settings, Dictionaries.",
                          comment: "Dictionary lookup failed: no offline dictionary is installed")
        case .notFound:
            return String(localized: "No definition found for this word. Try another form of it, such as the singular.",
                          comment: "Dictionary lookup: the word is not in the dictionary")
        case .unreadable:
            return String(localized: "A dictionary on this watch is damaged. Delete it in Folito on your iPhone and download it again.",
                          comment: "Dictionary lookup failed: an installed dictionary file could not be read")
        }
    }

    /// CC BY-SA credit of an installed dictionary: authors, licence, compiler, and that it was changed.
    static func dictionaryCredit(_ info: CompactDictionaryInfo) -> String {
        String(localized: "Definitions from \(info.dataSource) by its contributors, under the \(info.license) licence. Compiled by \(info.publisher). Shortened and reformatted by Folito.",
               comment: "Dictionary credit. 1: data source (Wiktionary), 2: licence (CC BY-SA 4.0), 3: who compiled the file (reader.dict)")
    }

    /// "English · 41 MB" for a dictionary installed on the watch.
    static func dictionaryLabel(_ info: CompactDictionaryInfo, size: Int64?, locale: Locale = .current) -> String {
        let language = locale.localizedString(forLanguageCode: info.language) ?? info.language
        guard let size else { return language }
        return language + " \u{00B7} " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
