import Foundation
import UIKit
import Security
import ReaderCore

/// The Catalogs list (presets and the catalogs the user added), their sign-ins, and downloads from catalogs
/// (docs/OPDS.md).
///
/// Nothing here contacts a server on its own: a catalog is read only when the user opens it (or adds or edits it,
/// to check the address and sign-in), and a book is downloaded only when the user taps Download.
///
/// Sign-ins (user name and password, HTTP Basic) are kept per server (scheme, host and port: `OPDSOrigin`) in the
/// iPhone Keychain only, under `keychainService`, never in UserDefaults or a file; in memory they live in the
/// client's `OPDSCredentialVault`, which sends them only to that server over https. Plain-http catalogs cannot
/// have a sign-in (`OPDSSignInPolicy`).
@MainActor
final class CatalogStore: ObservableObject {
    /// Catalogs the user added, in the order they were added.
    @Published private(set) var custom: [OPDSCatalog] = []
    /// The user name of each server with a saved sign-in (never the password).
    @Published private(set) var signIns: [OPDSOrigin: String] = [:]
    /// Entry ids being downloaded right now.
    @Published private(set) var downloading: Set<String> = []
    /// Entry ids downloaded into the library during this session (the detail screen shows "In Your Library").
    @Published private(set) var downloaded: Set<String> = []
    /// A failed download, shown by the screen that started it.
    @Published var alert: UserFacingError?

    let client: OPDSClient
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    static let customKey = "catalogs.custom"
    static let keychainService = "com.xlahuerta.folito.opds"

    /// The app's Keychain for sign-ins: this device only (not in iCloud Keychain, not restored onto another
    /// device), readable after the first unlock.
    nonisolated static func makeKeychain() -> KeychainStore {
        KeychainStore(service: keychainService, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    init(client: OPDSClient = OPDSClient(), defaults: UserDefaults = .standard,
         keychain: KeychainStore = CatalogStore.makeKeychain()) {
        self.client = client
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode([OPDSCatalog].self, from: data) {
            custom = saved
        }
        for origin in Set(custom.compactMap { OPDSOrigin($0.url) }) where origin.isSecure {
            if let credentials = Self.read(keychain, origin) {
                client.vault.set(credentials, for: origin)
                signIns[origin] = credentials.username
            }
        }
    }

    var all: [OPDSCatalog] { OPDSCatalog.presets + custom }

    // MARK: Custom catalogs

    /// Checks the address (and the sign-in, if one was entered) by reading the catalog once, then adds it, named
    /// after the feed when `name` is empty, and saves the sign-in in the Keychain. Returns the problem to show in
    /// the form, or nil when the catalog was added.
    ///
    /// With no sign-in entered, a server that already has one (another catalog on it) uses that one.
    func add(address: String, name: String, username: String = "", password: String = "") async -> String? {
        guard let url = OPDSCatalogAddress.normalize(address) else {
            return String(localized: "Enter a web address that starts with https://, for example https://example.com/opds.",
                          comment: "Add Catalog: the address field does not contain a usable web address")
        }
        if let existing = all.first(where: { $0.url == url }) {
            return String(localized: "“\(existing.title)” already has this address.",
                          comment: "Add Catalog: the address is already in the list; the placeholder is the catalog's name")
        }
        let entered: OPDSCredentials?
        switch Self.credentials(username: username, password: password) {
        case .failure(let problem): return problem.message
        case .success(let credentials): entered = credentials
        }
        if entered != nil, !OPDSSignInPolicy.canSignIn(to: url) {
            return UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS)
        }
        let origin = OPDSOrigin(url)
        let credentials = entered ?? origin.flatMap { client.vault.credentials(for: $0) }
        do {
            let feed = try await client.checkFeed(at: url, credentials: credentials)
            if let entered, let origin, let problem = storeSignIn(entered, for: origin) { return problem }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            custom.append(OPDSCatalog(title: trimmed.isEmpty ? feed.title : trimmed, url: url))
            save()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return Self.message(for: error, at: url)
        }
    }

    /// What the edit screen does with the sign-in.
    enum SignInChange: Equatable {
        case keep
        case remove
        case set(OPDSCredentials)
    }

    /// The sign-in change the edit screen's fields ask for: both empty removes it; a user name with an empty
    /// password keeps the saved password if the user name is unchanged.
    func signInChange(for catalog: OPDSCatalog, username: String, password: String) -> Result<SignInChange, SignInProblem> {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty && password.isEmpty { return .success(signIn(for: catalog) == nil ? .keep : .remove) }
        if password.isEmpty, let saved = signIn(for: catalog), saved == user { return .success(.keep) }
        return Self.credentials(username: username, password: password).map { $0.map(SignInChange.set) ?? .keep }
    }

    /// Renames a catalog and changes its sign-in. A new sign-in is checked by reading the catalog with it first,
    /// and saved only if the catalog accepts it. Returns the problem to show, or nil when saved.
    func update(_ catalog: OPDSCatalog, name: String, username: String, password: String) async -> String? {
        guard let index = custom.firstIndex(where: { $0.id == catalog.id }) else { return nil }
        let change: SignInChange
        switch signInChange(for: catalog, username: username, password: password) {
        case .failure(let problem): return problem.message
        case .success(let c): change = c
        }
        let origin = OPDSOrigin(catalog.url)
        switch change {
        case .keep:
            break
        case .remove:
            if let origin { forgetSignIn(for: origin) }
        case .set(let credentials):
            guard let origin, OPDSSignInPolicy.canSignIn(to: catalog.url) else {
                return UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS)
            }
            do {
                _ = try await client.checkFeed(at: catalog.url, credentials: credentials)
            } catch is CancellationError {
                return nil
            } catch {
                return Self.message(for: error, at: catalog.url)
            }
            if let problem = storeSignIn(credentials, for: origin) { return problem }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { custom[index].title = trimmed }
        save()
        return nil
    }

    /// Removes the catalog; its server's sign-in is deleted from the Keychain unless another catalog uses it.
    func remove(_ catalog: OPDSCatalog) {
        custom.removeAll { $0.id == catalog.id }
        save()
        if let origin = OPDSOrigin(catalog.url), !custom.contains(where: { OPDSOrigin($0.url) == origin }) {
            forgetSignIn(for: origin)
        }
    }

    /// Deletes the sign-in of the catalog's server (Keychain and memory).
    func removeSignIn(for catalog: OPDSCatalog) {
        if let origin = OPDSOrigin(catalog.url) { forgetSignIn(for: origin) }
    }

    /// The saved user name for the catalog's server, if it has a sign-in.
    func signIn(for catalog: OPDSCatalog) -> String? {
        OPDSOrigin(catalog.url).flatMap { signIns[$0] }
    }

    /// The added catalog a sign-in for `url` would belong to: the first one on the same `https` server. Nil for
    /// the presets, other servers and plain http (no sign-in is offered there).
    func signInCatalog(for url: URL) -> OPDSCatalog? {
        guard let origin = OPDSOrigin(url), origin.isSecure else { return nil }
        return custom.first { OPDSOrigin($0.url) == origin }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.customKey) }
    }

    // MARK: Sign-in storage

    /// Saves the sign-in in the Keychain, then in memory. Returns a problem if the Keychain refused it.
    private func storeSignIn(_ credentials: OPDSCredentials, for origin: OPDSOrigin) -> String? {
        guard origin.isSecure, let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            return UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS)
        }
        do {
            try keychain.set(json, account: origin.description)
        } catch {
            return String(localized: "The sign-in couldn’t be saved to this iPhone’s Keychain. Restart your iPhone and try again.",
                          comment: "Catalogs: saving a catalog's user name and password in the Keychain failed")
        }
        client.vault.set(credentials, for: origin)
        signIns[origin] = credentials.username
        return nil
    }

    private func forgetSignIn(for origin: OPDSOrigin) {
        keychain.remove(account: origin.description)
        client.vault.set(nil, for: origin)
        signIns[origin] = nil
    }

    private nonisolated static func read(_ keychain: KeychainStore, _ origin: OPDSOrigin) -> OPDSCredentials? {
        guard let json = keychain.get(account: origin.description) else { return nil }
        return try? JSONDecoder().decode(OPDSCredentials.self, from: Data(json.utf8))
    }

    /// Why the sign-in fields cannot be used.
    struct SignInProblem: Error, Equatable {
        let message: String
    }

    /// Credentials from the form's fields: nil when both are empty. The user name is trimmed; the password is used
    /// exactly as typed.
    nonisolated static func credentials(username: String, password: String) -> Result<OPDSCredentials?, SignInProblem> {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty && password.isEmpty { return .success(nil) }
        let credentials = OPDSCredentials(username: user, password: password)
        guard let problem = credentials.problem else { return .success(credentials) }
        switch problem {
        case .missingUsername:
            return .failure(SignInProblem(message: String(localized: "Enter the user name, or leave both sign-in fields empty.",
                                                          comment: "Catalog sign-in: a password was typed without a user name")))
        case .missingPassword:
            return .failure(SignInProblem(message: String(localized: "Enter the password, or leave both sign-in fields empty.",
                                                          comment: "Catalog sign-in: a user name was typed without a password")))
        case .colonInUsername:
            return .failure(SignInProblem(message: String(localized: "A user name can’t contain a colon (:).",
                                                          comment: "Catalog sign-in: HTTP Basic user names cannot contain a colon")))
        case .controlCharacters:
            return .failure(SignInProblem(message: String(localized: "The user name or password contains a line break or another invisible character. Type it again.",
                                                          comment: "Catalog sign-in: control characters in the user name or password")))
        }
    }

    /// The message for a failed check: a sign-in asked by a plain-http catalog is explained as such.
    nonisolated static func message(for error: Error, at url: URL) -> String {
        if (error as? OPDSError)?.isAuthentication == true, !OPDSSignInPolicy.canSignIn(to: url) {
            return UserFacingError.catalogMessage(for: OPDSError.signInRequiresHTTPS)
        }
        return UserFacingError.catalogMessage(for: error)
    }

    // MARK: Downloads

    /// Downloads the entry's EPUB and imports it through the normal pipeline; the library then sends it to the
    /// watch as usual.
    func download(_ entry: OPDSEntry, into library: LibraryStore) async {
        guard let link = entry.epubLink, !downloading.contains(entry.id) else { return }
        downloading.insert(entry.id)
        defer { downloading.remove(entry.id) }
        let fileName = Self.fileName(for: entry)
        do {
            let data = try await client.download(link)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
            try data.write(to: temp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temp) }
            if await library.importDownloaded(from: temp, fileName: fileName) != nil {
                downloaded.insert(entry.id)
                Announcer.announce(String(localized: "Downloaded “\(entry.title)”.",
                                          comment: "VoiceOver announcement after a book was downloaded (from Readest or a catalog); the placeholder is the title"))
            } else if let error = library.importError {
                // The Library's own alert is behind the Catalogs sheet: show the import error here instead.
                library.importError = nil
                alert = error
            }
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingError.catalogDownloadFailed(title: entry.title, error: error)
        }
    }

    // MARK: Covers

    private let images = NSCache<NSURL, UIImage>()

    /// A cover or thumbnail from the catalog, loaded through the catalog client (ephemeral session) and kept in
    /// memory while the app runs. Nil when the catalog has none or it is not an image.
    func image(at url: URL) async -> UIImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let data = try? await client.image(at: url), let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    /// "Pride and Prejudice.epub": the title without characters a file name cannot hold.
    nonisolated static func fileName(for entry: OPDSEntry) -> String {
        let cleaned = entry.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Book" : String(cleaned.prefix(120))) + ".epub"
    }
}

/// One catalog page being browsed, with its following pages appended as the user asks for them.
@MainActor
final class CatalogFeedModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(UserFacingError)
    }

    let url: URL
    private let client: OPDSClient
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var title: String?
    @Published private(set) var entries: [OPDSEntry] = []
    @Published private(set) var nextURL: URL?
    @Published private(set) var isLoadingMore = false
    /// A failed "Load More"; the entries already shown stay.
    @Published var moreError: UserFacingError?
    /// The last failure was a missing or refused sign-in (401, or 403 without one).
    @Published private(set) var failedForSignIn = false
    private var hasLoaded = false

    init(url: URL, client: OPDSClient) {
        self.url = url
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        if entries.isEmpty { phase = .loading }
        do {
            let feed = try await client.feed(at: url)
            hasLoaded = true
            title = feed.title
            entries = OPDSPages.append(feed.entries, to: [])
            nextURL = feed.nextURL
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            let failure = userFacing(error)
            if entries.isEmpty { phase = .failed(failure) } else { moreError = failure }
        }
    }

    func loadMore() async {
        guard let next = nextURL, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.feed(at: next)
            entries = OPDSPages.append(page.entries, to: entries)
            // A page pointing to itself (or back) would loop.
            nextURL = page.nextURL == next || page.nextURL == url ? nil : page.nextURL
        } catch is CancellationError {
            return
        } catch {
            moreError = userFacing(error)
        }
    }

    /// The error to show; a sign-in asked by a plain-http page is explained as such. Also remembers whether a
    /// sign-in could fix the failure (the screen then offers Sign In for an https catalog the user added).
    private func userFacing(_ error: Error) -> UserFacingError {
        failedForSignIn = (error as? OPDSError)?.isAuthentication == true
        return UserFacingError(title: UserFacingError.catalogFailed(error).title,
                               message: CatalogStore.message(for: error, at: url))
    }
}
