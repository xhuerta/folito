import Foundation
import ReaderCore

/// Downloads, converts, updates and deletes the offline dictionaries (docs/DICTIONARIES.md).
///
/// Pipeline for one dictionary: HTTPS download of the StarDict ZIP -> checks (HTTP status, length, the
/// SHA-256 when the catalog has one, ZIP CRC-32s, StarDict and gzip internal checks) -> conversion to the
/// compact format -> SHA-256 of the result -> stored under Application Support -> sent to the watch
/// (WatchConnectivity file transfer; the watch verifies size and SHA-256 before installing it).
/// The phone keeps its copy so the watch can get it again (watch app reinstalled, transfer lost).
@MainActor
final class DictionaryManager: ObservableObject {
    enum Phase: Equatable {
        case downloading(Double)
        case converting(Double)
    }

    /// Work in progress per dictionary id (absent = idle).
    @Published private(set) var phases: [String: Phase] = [:]
    /// Installed dictionaries by id.
    @Published private(set) var installedInfos: [String: CompactDictionaryInfo] = [:]
    /// Installed dictionaries whose source file changed on the server since they were downloaded.
    @Published private(set) var updatesAvailable: Set<String> = []
    /// The last download / conversion problem, shown as an alert.
    @Published var error: UserFacingError?

    let installed: InstalledDictionaries
    private let defaults: UserDefaults
    private var tasks: [String: Task<Void, Never>] = [:]

    /// A dictionary was installed or updated on the phone: send it to the watch.
    var onInstalled: ((String) -> Void)?
    /// A dictionary was deleted on the phone: delete it on the watch.
    var onDeleted: ((String) -> Void)?

    private static let validatorsKey = "dictionaries.validators"
    private static let checksumsKey = "dictionaries.sha256"

    init(rootDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folito", isDirectory: true)
        installed = InstalledDictionaries(directory: root.appendingPathComponent("Dictionaries", isDirectory: true))
        self.defaults = defaults
        refresh()
    }

    private func refresh() {
        installedInfos = Dictionary(uniqueKeysWithValues: installed.infos.map { ($0.id, $0) })
    }

    func isInstalled(_ id: String) -> Bool { installedInfos[id] != nil }

    func installedSize(_ id: String) -> Int64? { FileDigest.size(of: installed.url(for: id)) }

    /// What the watch needs: every installed dictionary with its file, SHA-256 and size.
    func transferList() -> [(id: String, fileURL: URL, sha256: String, size: Int64)] {
        let sums = defaults.dictionary(forKey: Self.checksumsKey) as? [String: String] ?? [:]
        return installedInfos.keys.sorted().compactMap { id in
            let url = installed.url(for: id)
            guard let sha = sums[id], let size = FileDigest.size(of: url) else { return nil }
            return (id, url, sha, size)
        }
    }

    // MARK: Download and convert

    func download(_ descriptor: DictionaryDescriptor) {
        guard tasks[descriptor.id] == nil else { return }
        phases[descriptor.id] = .downloading(0)
        tasks[descriptor.id] = Task { [weak self] in
            await self?.run(descriptor)
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    private func run(_ d: DictionaryDescriptor) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("dict-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: work)
            tasks[d.id] = nil
            phases[d.id] = nil
        }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("download.zip")
            let id = d.id
            let response = try await FileDownload.run(d.downloadURL, to: zip) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading(_)? = self?.phases[id] { self?.phases[id] = .downloading(fraction) }
                }
            }
            try Self.verify(download: zip, response: response, descriptor: d)
            phases[d.id] = .converting(0)
            let output = work.appendingPathComponent(InstalledDictionaries.fileName(for: d.id))
            let template = d.compactInfo(sourceVersion: response.lastModified ?? "")
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    if case .converting(_)? = self?.phases[id] { self?.phases[id] = .converting(fraction) }
                }
            }
            // Off the main actor. A detached task does not inherit cancellation: forward it with a flag.
            let flag = CancelFlag()
            let installed = self.installed
            let sha = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    _ = try StarDictConverter.convert(zip: zip, template: template, to: output,
                                                      workDirectory: work.appendingPathComponent("source"),
                                                      progress: report, isCancelled: { flag.isCancelled })
                    let sha = try FileDigest.sha256(of: output)
                    if flag.isCancelled { throw CancellationError() }
                    try installed.install(fileAt: output)
                    return sha
                }.value
            } onCancel: {
                flag.cancel()
            }
            var sums = defaults.dictionary(forKey: Self.checksumsKey) as? [String: String] ?? [:]
            sums[d.id] = sha
            defaults.set(sums, forKey: Self.checksumsKey)
            var validators = defaults.dictionary(forKey: Self.validatorsKey) as? [String: String] ?? [:]
            validators[d.id] = response.validator
            defaults.set(validators, forKey: Self.validatorsKey)
            updatesAvailable.remove(d.id)
            refresh()
            onInstalled?(d.id)
            Announcer.announce(String(localized: "Dictionary ready: \(Self.languageName(d.language)).",
                                      comment: "VoiceOver announcement when a dictionary finished installing; the placeholder is its language"))
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            self.error = UserFacingError.dictionaryFailed(language: Self.languageName(d.language), error: error)
        }
    }

    /// HTTP 200, the announced length, and the catalog's SHA-256 when there is one.
    nonisolated static func verify(download url: URL, response: FileDownload.Response, descriptor: DictionaryDescriptor) throws {
        guard response.status == 200 else { throw FileDownload.Failure.http(response.status) }
        let expected = response.expectedLength > 0 ? response.expectedLength : nil
        try FileDigest.verify(url, size: expected, sha256: descriptor.sha256)
    }

    func delete(_ id: String) {
        cancel(id)
        installed.remove(id: id)
        var sums = defaults.dictionary(forKey: Self.checksumsKey) as? [String: String] ?? [:]
        sums[id] = nil
        defaults.set(sums, forKey: Self.checksumsKey)
        updatesAvailable.remove(id)
        refresh()
        onDeleted?(id)
    }

    // MARK: Updates

    /// Asks the server (HEAD) whether each installed dictionary's file changed since it was downloaded.
    func checkForUpdates() async {
        let validators = defaults.dictionary(forKey: Self.validatorsKey) as? [String: String] ?? [:]
        for id in installedInfos.keys {
            guard let d = DictionaryCatalog.descriptor(id: id), let known = validators[id], !known.isEmpty,
                  let current = await FileDownload.validator(of: d.downloadURL) else { continue }
            if current != known { updatesAvailable.insert(id) }
        }
    }

    nonisolated static func languageName(_ code: String, locale: Locale = .autoupdatingCurrent) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }
}

/// Cancellation signal shared with a detached conversion task.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// One HTTPS download to a file with progress. A delegate-based task: the async `URLSession.download`
/// reports no progress.
enum FileDownload {
    struct Response: Sendable {
        var status: Int
        var expectedLength: Int64
        var etag: String?
        var lastModified: String?
        /// ETag, else Last-Modified: what `checkForUpdates` compares.
        var validator: String { etag ?? lastModified ?? "" }
    }

    enum Failure: Error, Equatable {
        case http(Int)
    }

    static let userAgent = "Folito/1.0 (https://github.com/xhuerta/folito; dictionary download)"

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Response {
        let delegate = Delegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// ETag / Last-Modified of `url` (HEAD request), nil when unreachable.
    static func validator(of url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Response, Error>?
        private var response: Response?
        private var lastReported = -1.0

        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if fraction - lastReported >= 0.01 || fraction >= 1 {
                lastReported = fraction
                progress(fraction)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The temporary file is deleted when this returns: move it now.
            let http = downloadTask.response as? HTTPURLResponse
            response = Response(status: http?.statusCode ?? 0,
                                expectedLength: http?.expectedContentLength ?? -1,
                                etag: http?.value(forHTTPHeaderField: "ETag"),
                                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.moveItem(at: location, to: destination) } catch {
                continuation?.resume(throwing: error); continuation = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: response)
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
            continuation = nil
        }
    }
}
