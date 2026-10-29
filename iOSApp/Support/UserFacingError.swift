import Foundation
import ReaderCore

/// An error as the user sees it: a specific title (what happened) and a message (why, and what to do).
/// Built from the underlying error by pure functions so the wording is unit-tested.
struct UserFacingError: Equatable, Identifiable {
    var id: String { title + "\n" + message }
    let title: String
    let message: String

    // MARK: Library import

    /// The picked/opened file could not be copied into the app (not downloaded, permission revoked...).
    static func fileUnreadable(fileName: String) -> UserFacingError {
        UserFacingError(
            title: String(localized: "Couldn’t Open File", comment: "Alert title: an imported file could not be read"),
            message: String(localized: "Folito couldn’t read “\(fileName)”. If it is stored in iCloud Drive or another cloud service, open it once in the Files app so it is downloaded, then try again.",
                            comment: "Alert message; the placeholder is the file name"))
    }

    /// The document picker itself reported an error.
    static func pickerFailed() -> UserFacingError {
        UserFacingError(
            title: String(localized: "Couldn’t Open File", comment: "Alert title: an imported file could not be read"),
            message: String(localized: "The selected file couldn’t be opened. Try choosing it again.",
                            comment: "Alert message when the system file picker fails"))
    }

    /// Converting the EPUB failed.
    static func importFailed(fileName: String, error: Error) -> UserFacingError {
        let title = String(localized: "Couldn’t Import Book", comment: "Alert title: converting an EPUB failed")
        if let e = error as? EPUBError {
            switch e {
            case .invalidArchive, .missingContainer, .missingPackageDocument, .malformedXML:
                return UserFacingError(title: title, message: String(
                    localized: "“\(fileName)” isn’t a valid EPUB file or is damaged. Try downloading or exporting the book again.",
                    comment: "Import error; the placeholder is the file name"))
            case .emptySpine:
                return UserFacingError(title: title, message: String(
                    localized: "“\(fileName)” doesn’t contain any readable chapters.",
                    comment: "Import error; the placeholder is the file name"))
            case .missingResource:
                return UserFacingError(title: title, message: String(
                    localized: "“\(fileName)” is incomplete: part of the book is missing from the file. Try downloading it again.",
                    comment: "Import error; the placeholder is the file name"))
            case .entryTooLarge, .archiveTooLarge:
                return UserFacingError(title: title, message: String(
                    localized: "“\(fileName)” is too large to convert for Apple Watch. Try a smaller edition of the book, for example one without images.",
                    comment: "Import error; the placeholder is the file name"))
            case .notImplemented:
                break
            }
        }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace {
            return UserFacingError(title: title, message: String(
                localized: "There isn’t enough free storage on this iPhone. Free up some space and try again.",
                comment: "Import error when the disk is full"))
        }
        return UserFacingError(title: title, message: String(
            localized: "Something went wrong while converting “\(fileName)”. Try again; if it keeps failing, the file may use a format Folito doesn’t support.",
            comment: "Generic import error; the placeholder is the file name"))
    }

    // MARK: Sync

    /// Message for a failed KOSync request (shown inline in the Sync screen).
    static func syncMessage(for error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "iOS blocked the unencrypted http:// connection. Use an https:// address, or a local-network address (IP address, .local or a name without dots).",
                              comment: "Sync error")
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "This iPhone is offline. Connect to the internet and try again.", comment: "Sync error")
            case .cannotFindHost, .dnsLookupFailed, .unsupportedURL, .badURL:
                return String(localized: "The server address couldn’t be found. Check the server URL.", comment: "Sync error")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                return String(localized: "A secure connection to the server couldn’t be made. The server’s certificate isn’t trusted by this iPhone.",
                              comment: "Sync error")
            default:
                break
            }
        }
        if let e = error as? ReadestError { return readestMessage(for: e) }
        guard let e = error as? KOSyncError else {
            return String(localized: "The server couldn’t be reached. Check the server URL and your internet connection, then try again.",
                          comment: "Generic sync error")
        }
        switch e {
        case .unauthorized:
            return String(localized: "The server didn’t accept this username and password. Check them, or create an account on the sync server first.",
                          comment: "Sync error: wrong credentials")
        case .userExists:
            return String(localized: "That username is already registered on this server.", comment: "Sync error")
        case .offline:
            return String(localized: "The server couldn’t be reached. Check the server URL and your internet connection, then try again.",
                          comment: "Generic sync error")
        case .notFound:
            return String(localized: "The server didn’t recognise the request. Check that the URL points to a KOReader sync server.",
                          comment: "Sync error")
        case .server(let status):
            return String(localized: "The server reported an error (HTTP \(status)). Try again later.",
                          comment: "Sync error; the placeholder is an HTTP status code")
        case .invalidResponse:
            return String(localized: "The server sent a response Folito couldn’t understand. Check that the URL points to a KOReader sync server.",
                          comment: "Sync error")
        case .notImplemented:
            return String(localized: "This server doesn’t support that request.", comment: "Sync error")
        }
    }

    /// Message for a failed Readest Cloud request.
    static func readestMessage(for error: ReadestError) -> String {
        switch error {
        case .invalidCredentials:
            return String(localized: "Readest didn’t accept this email and password. Check them, or create an account in the Readest app first.",
                          comment: "Readest sync error: wrong email or password")
        case .unauthorized, .notSignedIn:
            return String(localized: "Your Readest session has ended. Sign in again.",
                          comment: "Readest sync error: session expired or revoked")
        case .rateLimited:
            return String(localized: "Too many attempts. Wait a few minutes, then try again.",
                          comment: "Readest sync error: rate limited")
        case .offline:
            return String(localized: "Readest couldn’t be reached. Check your internet connection, then try again.",
                          comment: "Readest sync error: no connection")
        case .server(let status, _):
            return String(localized: "The server reported an error (HTTP \(status)). Try again later.",
                          comment: "Sync error; the placeholder is an HTTP status code")
        case .notFound, .invalidResponse:
            return String(localized: "Readest sent a response Folito couldn’t understand. Try again later.",
                          comment: "Readest sync error: unexpected response")
        }
    }
}
