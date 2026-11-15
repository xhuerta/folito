import Foundation

/// What the iPhone app remembers to decide when to ask for an App Store rating (stored only on the device,
/// `ReviewPromptStore`; never sent anywhere).
///
/// The reading signal is the watch's reported progress: the iPhone does not read books itself, but the watch
/// publishes the whole percent read per book in its `library` context. A calendar day on which any book's
/// percentage went up compared with the last report counts as a reading day.
public struct ReviewPromptState: Codable, Sendable, Equatable {
    /// First launch of a version that knows about the rating prompt (not the original install date).
    public var firstLaunchAt: Date?
    /// Local calendar days ("2026-11-15") with reading progress, oldest first, at most `maxReadingDays`.
    public var readingDays: [String]
    /// Last whole percent seen per book hash; nil until the first non-empty progress report.
    public var progressBaseline: [String: Int]?
    /// When the system review prompt was last requested.
    public var lastRequestAt: Date?
    /// `CFBundleShortVersionString` of the app that last requested it.
    public var lastRequestVersion: String?

    /// Only the count matters, so older days are dropped.
    public static let maxReadingDays = 30

    public init(firstLaunchAt: Date? = nil, readingDays: [String] = [], progressBaseline: [String: Int]? = nil,
                lastRequestAt: Date? = nil, lastRequestVersion: String? = nil) {
        self.firstLaunchAt = firstLaunchAt
        self.readingDays = readingDays
        self.progressBaseline = progressBaseline
        self.lastRequestAt = lastRequestAt
        self.lastRequestVersion = lastRequestVersion
    }

    /// Every launch: remembers the first one.
    public mutating func noteLaunch(at now: Date) {
        if firstLaunchAt == nil { firstLaunchAt = now }
    }

    /// The watch reported its progress (fraction read, 0...1, per book hash). Records `now`'s calendar day when a
    /// book advanced by at least one whole percent since the previous report. The first report only sets the
    /// baseline (progress made before this version was installed is not counted); an empty report carries no
    /// information and is ignored. A book reported for the first time counts from 0 %.
    public mutating func noteProgress(_ progress: [String: Double], at now: Date, calendar: Calendar = .current) {
        guard !progress.isEmpty else { return }
        var percents: [String: Int] = [:]
        for (hash, fraction) in progress where fraction.isFinite {
            percents[hash] = Int((min(max(fraction, 0), 1) * 100).rounded())
        }
        guard let baseline = progressBaseline else {
            progressBaseline = percents
            return
        }
        let advanced = percents.contains { hash, percent in percent > (baseline[hash] ?? 0) }
        progressBaseline = baseline.merging(percents) { _, new in new }
        if advanced { noteReadingDay(now, calendar: calendar) }
    }

    /// Records the calendar day of `date` as a reading day (once per day).
    public mutating func noteReadingDay(_ date: Date, calendar: Calendar = .current) {
        let day = Self.dayKey(date, calendar: calendar)
        guard !readingDays.contains(day) else { return }
        readingDays.append(day)
        readingDays.sort()
        if readingDays.count > Self.maxReadingDays { readingDays.removeFirst(readingDays.count - Self.maxReadingDays) }
    }

    /// The review prompt was requested now by `version`.
    public mutating func noteRequested(at now: Date, version: String) {
        lastRequestAt = now
        lastRequestVersion = version
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// What is on screen when the app considers asking: the prompt only appears at a calm moment.
public struct ReviewPromptMoment: Sendable, Equatable {
    /// The welcome tour is open.
    public var isOnboarding: Bool
    /// A book or dictionary is being sent to the watch, a book is being imported, downloaded or uploaded.
    public var isTransferring: Bool
    /// An error or sync problem is shown (import error, Readest refresh error, sign in again).
    public var showsError: Bool
    /// A sheet, alert, confirmation dialog or file picker is open.
    public var isPresentingModal: Bool

    public init(isOnboarding: Bool = false, isTransferring: Bool = false, showsError: Bool = false,
                isPresentingModal: Bool = false) {
        self.isOnboarding = isOnboarding
        self.isTransferring = isTransferring
        self.showsError = showsError
        self.isPresentingModal = isPresentingModal
    }

    public var isCalm: Bool { !isOnboarding && !isTransferring && !showsError && !isPresentingModal }
}

/// When to request the system review prompt (`RequestReviewAction`). Apple shows it at most three times a year
/// anyway; this policy asks far less: only after real reading, once per app version, with a long cooldown.
public struct ReviewPromptPolicy: Sendable, Equatable {
    /// Distinct calendar days with reading progress.
    public var minimumReadingDays: Int
    /// Days since `ReviewPromptState.firstLaunchAt`.
    public var minimumDaysSinceFirstLaunch: Int
    /// Days between two requests (also across versions).
    public var cooldownDays: Int

    public static let `default` = ReviewPromptPolicy(minimumReadingDays: 3, minimumDaysSinceFirstLaunch: 7,
                                                     cooldownDays: 120)

    public init(minimumReadingDays: Int, minimumDaysSinceFirstLaunch: Int, cooldownDays: Int) {
        self.minimumReadingDays = minimumReadingDays
        self.minimumDaysSinceFirstLaunch = minimumDaysSinceFirstLaunch
        self.cooldownDays = cooldownDays
    }

    /// Whether to request the prompt now. `appVersion` is `CFBundleShortVersionString`; an empty one never asks
    /// (once per version could not be kept).
    public func shouldRequest(state: ReviewPromptState, now: Date, appVersion: String,
                              moment: ReviewPromptMoment) -> Bool {
        let version = appVersion.trimmingCharacters(in: .whitespaces)
        guard moment.isCalm, !version.isEmpty else { return false }
        guard let firstLaunch = state.firstLaunchAt,
              now.timeIntervalSince(firstLaunch) >= Self.days(minimumDaysSinceFirstLaunch) else { return false }
        guard state.readingDays.count >= minimumReadingDays else { return false }
        guard state.lastRequestVersion != version else { return false }
        if let last = state.lastRequestAt, now.timeIntervalSince(last) < Self.days(cooldownDays) { return false }
        return true
    }

    private static func days(_ n: Int) -> TimeInterval { TimeInterval(n) * 24 * 60 * 60 }
}

/// On-device storage of `ReviewPromptState` (UserDefaults; never sent anywhere).
public final class ReviewPromptStore: @unchecked Sendable {
    public static let key = "reviewPrompt.state"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> ReviewPromptState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(ReviewPromptState.self, from: data) else { return ReviewPromptState() }
        return state
    }

    public func save(_ state: ReviewPromptState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}
