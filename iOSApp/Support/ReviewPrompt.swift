import StoreKit
import SwiftUI
import ReaderCore

/// Asks for an App Store rating only after real reading (see `ReviewPromptPolicy` in ReaderCore): at least three
/// days with reading progress reported by the watch, a week after the first launch, once per app version and at
/// most every 120 days. The Library asks at a calm moment (`LibraryView`); everything is kept on the device.
@MainActor
final class ReviewPromptModel: ObservableObject {
    private let store: ReviewPromptStore
    private let policy: ReviewPromptPolicy
    private let appVersion: String
    private let now: () -> Date
    /// Off in UI-testing launches, so a system prompt never covers the screens under test (nothing is stored then).
    private let isEnabled: Bool
    private var state: ReviewPromptState

    init(store: ReviewPromptStore = ReviewPromptStore(), policy: ReviewPromptPolicy = .default,
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
         isEnabled: Bool = !UITesting.isActive, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.policy = policy
        self.appVersion = appVersion
        self.now = now
        self.isEnabled = isEnabled
        state = store.load()
        state.noteLaunch(at: now())
        if isEnabled { store.save(state) }
    }

    /// The watch reported its reading progress (`PhoneConnectivity.watchProgress`).
    func watchReported(progress: [String: Double]) {
        let before = state
        state.noteProgress(progress, at: now())
        if isEnabled, state != before { store.save(state) }
    }

    /// Requests the system prompt when the policy allows it at this moment; returns whether it did.
    @discardableResult
    func requestIfDue(moment: ReviewPromptMoment, requestReview: RequestReviewAction) -> Bool {
        guard isEnabled else { return false }
        let date = now()
        guard policy.shouldRequest(state: state, now: date, appVersion: appVersion, moment: moment) else { return false }
        state.noteRequested(at: date, version: appVersion)
        store.save(state)
        requestReview()
        return true
    }
}
