import Foundation

/// Shows a "busy" state (the reader's syncing glyph) only for a request that is still running after `delay`
/// seconds, so a quick answer ("nothing there", issue #167) never flashes the glyph.
///
/// Usage: `let token = indicator.begin()` before the request, `indicator.end(token)` after it. Only the latest
/// request counts: a request that ended, or was superseded by a newer `begin()`, never turns the state on.
@MainActor
public final class SlowRequestIndicator {
    /// About one second: long enough for a quick answer to pass unseen, short enough that a slow request still
    /// shows that something is happening.
    public nonisolated static let defaultDelay: TimeInterval = 1

    public private(set) var isShowing = false
    /// Called with every change of `isShowing`.
    public var onChange: ((Bool) -> Void)?

    private let delay: TimeInterval
    private let clock: SyncClock
    private var current: Int?
    private var counter = 0
    /// The timer of the latest request (tests await it).
    private var timer: Task<Void, Never>?

    public init(delay: TimeInterval = SlowRequestIndicator.defaultDelay, clock: SyncClock = SystemSyncClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// A request starts: the state turns on after `delay` unless `end` comes first.
    @discardableResult
    public func begin() -> Int {
        counter += 1
        let token = counter
        current = token
        timer?.cancel()
        let clock = self.clock
        let wait = delay
        timer = Task { [weak self] in
            do { try await clock.sleep(seconds: wait) } catch { return }
            self?.fire(token)
        }
        return token
    }

    /// The request with `token` finished (successfully or not): the state turns off.
    public func end(_ token: Int) {
        guard current == token else { return }
        current = nil
        timer?.cancel()
        timer = nil
        set(false)
    }

    /// Waits until the latest timer has run or was cancelled (tests).
    public func settle() async {
        await timer?.value
    }

    private func fire(_ token: Int) {
        guard current == token, !Task.isCancelled else { return }
        set(true)
    }

    private func set(_ showing: Bool) {
        guard isShowing != showing else { return }
        isShowing = showing
        onChange?(showing)
    }
}
