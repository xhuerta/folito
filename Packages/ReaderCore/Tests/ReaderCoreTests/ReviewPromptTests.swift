import XCTest
@testable import ReaderCore

final class ReviewPromptTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = ReviewPromptPolicy.default
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// First launch at t0 and reading on days 1, 2 and 3: eligible from day 7 on.
    private func eligibleState() -> ReviewPromptState {
        var s = ReviewPromptState()
        s.noteLaunch(at: t0)
        for d in 1...3 { s.noteReadingDay(t0 + Double(d) * day, calendar: calendar) }
        return s
    }

    // MARK: Thresholds

    func testAsksAfterSevenDaysAndThreeReadingDays() {
        let s = eligibleState()
        XCTAssertTrue(policy.shouldRequest(state: s, now: t0 + 7 * day, appVersion: "1.1", moment: .init()))
        XCTAssertFalse(policy.shouldRequest(state: s, now: t0 + 7 * day - 1, appVersion: "1.1", moment: .init()))
    }

    func testNeedsThreeDistinctReadingDays() {
        var s = ReviewPromptState()
        s.noteLaunch(at: t0)
        s.noteReadingDay(t0 + day, calendar: calendar)
        s.noteReadingDay(t0 + day + 3600, calendar: calendar) // same day
        s.noteReadingDay(t0 + 2 * day, calendar: calendar)
        XCTAssertEqual(s.readingDays.count, 2)
        XCTAssertFalse(policy.shouldRequest(state: s, now: t0 + 30 * day, appVersion: "1.1", moment: .init()))
        s.noteReadingDay(t0 + 5 * day, calendar: calendar)
        XCTAssertTrue(policy.shouldRequest(state: s, now: t0 + 30 * day, appVersion: "1.1", moment: .init()))
    }

    func testNeverWithoutFirstLaunchOrVersion() {
        var s = eligibleState()
        XCTAssertFalse(policy.shouldRequest(state: s, now: t0 + 30 * day, appVersion: " ", moment: .init()))
        s.firstLaunchAt = nil
        XCTAssertFalse(policy.shouldRequest(state: s, now: t0 + 30 * day, appVersion: "1.1", moment: .init()))
    }

    func testFirstLaunchIsKept() {
        var s = ReviewPromptState()
        s.noteLaunch(at: t0)
        s.noteLaunch(at: t0 + 10 * day)
        XCTAssertEqual(s.firstLaunchAt, t0)
    }

    func testOnlyAtACalmMoment() {
        let s = eligibleState()
        let now = t0 + 10 * day
        for moment in [ReviewPromptMoment(isOnboarding: true), ReviewPromptMoment(isTransferring: true),
                       ReviewPromptMoment(showsError: true), ReviewPromptMoment(isPresentingModal: true)] {
            XCTAssertFalse(moment.isCalm)
            XCTAssertFalse(policy.shouldRequest(state: s, now: now, appVersion: "1.1", moment: moment))
        }
        XCTAssertTrue(policy.shouldRequest(state: s, now: now, appVersion: "1.1", moment: .init()))
    }

    // MARK: Once per version, cooldown

    func testOncePerVersion() {
        var s = eligibleState()
        let asked = t0 + 10 * day
        s.noteRequested(at: asked, version: "1.1")
        // Same version: never again, even long after the cooldown.
        XCTAssertFalse(policy.shouldRequest(state: s, now: asked + 400 * day, appVersion: "1.1", moment: .init()))
        // A new version after the cooldown: yes.
        XCTAssertTrue(policy.shouldRequest(state: s, now: asked + 400 * day, appVersion: "1.2", moment: .init()))
    }

    func testCooldownAcrossVersions() {
        var s = eligibleState()
        let asked = t0 + 10 * day
        s.noteRequested(at: asked, version: "1.1")
        XCTAssertFalse(policy.shouldRequest(state: s, now: asked + 119 * day, appVersion: "1.2", moment: .init()))
        XCTAssertTrue(policy.shouldRequest(state: s, now: asked + 120 * day, appVersion: "1.2", moment: .init()))
        // A clock set back does not reopen the window.
        XCTAssertFalse(policy.shouldRequest(state: s, now: asked - 200 * day, appVersion: "1.2", moment: .init()))
    }

    // MARK: Reading signal

    func testFirstProgressReportIsOnlyTheBaseline() {
        var s = ReviewPromptState()
        s.noteProgress([:], at: t0, calendar: calendar)
        XCTAssertNil(s.progressBaseline, "an empty report carries no information")
        s.noteProgress(["a": 0.40, "b": 0.10], at: t0, calendar: calendar)
        XCTAssertEqual(s.progressBaseline, ["a": 40, "b": 10])
        XCTAssertTrue(s.readingDays.isEmpty)
    }

    func testAdvancingProgressRecordsTheDay() {
        var s = ReviewPromptState()
        s.noteProgress(["a": 0.40], at: t0, calendar: calendar)
        // Same values again (e.g. the context re-delivered on activation): nothing.
        s.noteProgress(["a": 0.40], at: t0 + day, calendar: calendar)
        XCTAssertTrue(s.readingDays.isEmpty)
        // Going back (restarted the book): nothing.
        s.noteProgress(["a": 0.10], at: t0 + day, calendar: calendar)
        XCTAssertTrue(s.readingDays.isEmpty)
        s.noteProgress(["a": 0.12], at: t0 + 2 * day, calendar: calendar)
        XCTAssertEqual(s.readingDays, [ReviewPromptState.dayKey(t0 + 2 * day, calendar: calendar)])
        // A newly opened book counts from 0 %.
        s.noteProgress(["a": 0.12, "c": 0.02], at: t0 + 3 * day, calendar: calendar)
        XCTAssertEqual(s.readingDays.count, 2)
        // A book missing from a report keeps its baseline.
        s.noteProgress(["c": 0.02], at: t0 + 4 * day, calendar: calendar)
        XCTAssertEqual(s.progressBaseline?["a"], 12)
        XCTAssertEqual(s.readingDays.count, 2)
    }

    func testReadingDaysAreCapped() {
        var s = ReviewPromptState()
        for d in 0..<(ReviewPromptState.maxReadingDays + 5) { s.noteReadingDay(t0 + Double(d) * day, calendar: calendar) }
        XCTAssertEqual(s.readingDays.count, ReviewPromptState.maxReadingDays)
        XCTAssertEqual(s.readingDays.last, ReviewPromptState.dayKey(t0 + Double(ReviewPromptState.maxReadingDays + 4) * day,
                                                                    calendar: calendar))
    }

    func testStoreRoundTrip() {
        let name = "ReviewPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewPromptStore(defaults: defaults)
        XCTAssertEqual(store.load(), ReviewPromptState())
        var s = eligibleState()
        s.noteRequested(at: t0 + 10 * day, version: "1.1")
        store.save(s)
        XCTAssertEqual(ReviewPromptStore(defaults: defaults).load(), s)
        defaults.set(Data("garbage".utf8), forKey: ReviewPromptStore.key)
        XCTAssertEqual(store.load(), ReviewPromptState())
    }
}
