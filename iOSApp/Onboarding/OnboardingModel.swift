import SwiftUI

/// Whether the welcome tour is on screen. It opens by itself once, on the first launch, and again whenever the user
/// picks "Show Welcome Tour" in Settings › About. Finishing or skipping it at any page records completion in
/// `UserDefaults`.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var isPresented: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        isPresented = OnboardingPolicy.shouldShowOnLaunch(
            completedVersion: defaults.integer(forKey: OnboardingPolicy.completedVersionKey),
            override: OnboardingPolicy.launchOverride(arguments: arguments))
    }

    var isCompleted: Bool {
        defaults.integer(forKey: OnboardingPolicy.completedVersionKey) >= OnboardingPolicy.currentVersion
    }

    /// Done or Skip: closes the tour and keeps it from opening by itself again.
    func finish() {
        defaults.set(OnboardingPolicy.currentVersion, forKey: OnboardingPolicy.completedVersionKey)
        isPresented = false
    }

    /// Settings › About › Show Welcome Tour.
    func show() {
        isPresented = true
    }
}

/// The pure part of the first-launch decision (unit-tested).
enum OnboardingPolicy {
    /// Bump to show a substantially new tour once more to people who completed an older one.
    static let currentVersion = 1
    static let completedVersionKey = "onboarding.completedVersion"

    /// Forces the tour on (`-UITestingShowOnboarding`) or off (`-UITestingSkipOnboarding`) for UI tests. Every other
    /// UI-testing launch (`-UITesting`, `-UITestingSeedSampleBook`) skips it too, so existing UI tests start on the
    /// Library. Debug builds only: in Release the arguments are ignored.
    enum LaunchOverride: Equatable {
        case show, skip
    }

    static let showArgument = "-UITestingShowOnboarding"
    static let skipArgument = "-UITestingSkipOnboarding"

    static func launchOverride(arguments: [String]) -> LaunchOverride? {
        #if DEBUG
        if arguments.contains(showArgument) { return .show }
        if arguments.contains(skipArgument) { return .skip }
        if arguments.contains(UITesting.isolateArgument) || arguments.contains(UITesting.seedSampleBookArgument) {
            return .skip
        }
        #endif
        return nil
    }

    static func shouldShowOnLaunch(completedVersion: Int, override: LaunchOverride?) -> Bool {
        switch override {
        case .show?: return true
        case .skip?: return false
        case nil: return completedVersion < currentVersion
        }
    }
}

/// Opens the welcome tour from anywhere in the view hierarchy (Settings › About) without passing the model down.
struct ShowWelcomeTourAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

private struct ShowWelcomeTourKey: EnvironmentKey {
    static let defaultValue = ShowWelcomeTourAction {}
}

extension EnvironmentValues {
    var showWelcomeTour: ShowWelcomeTourAction {
        get { self[ShowWelcomeTourKey.self] }
        set { self[ShowWelcomeTourKey.self] = newValue }
    }
}

/// Settings › About › Show Welcome Tour.
struct ShowWelcomeTourButton: View {
    @Environment(\.showWelcomeTour) private var showWelcomeTour

    var body: some View {
        Button { showWelcomeTour() } label: {
            Label("Show Welcome Tour", systemImage: "hand.wave")
        }
        .accessibilityIdentifier("showWelcomeTour")
    }
}
