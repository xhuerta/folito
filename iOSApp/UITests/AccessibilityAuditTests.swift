import XCTest

/// Runs Xcode's automated accessibility audit (`performAccessibilityAudit`, iOS 17+) on every main screen.
/// The app is launched with `-UITesting` so it uses an empty, throw-away library (Debug builds only; see
/// iOSApp/Support/UITestingSupport.swift), or with `-UITestingSeedSampleBook` for a one-book library.
///
/// Each screen is audited twice, scrolled page by page so every element is audited while it is on screen:
/// - at the default text size with every audit type except Dynamic Type and Text clipped;
/// - launched at the largest accessibility text size (AX5) with Dynamic Type and Text clipped.
/// Run at the default size, those two audits enlarge the text themselves and report every element that
/// the larger text pushes off the screen ("partially unsupported", "may be clipped"), even standard text
/// styles in a `Form`; at AX5 they check the text actually shown at the largest size.
///
/// Consciously accepted findings are listed in `isAccepted(_:in:)` and in docs/ACCESSIBILITY.md.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Two launches and several pages per screen; the audits alone take a few seconds each on CI.
        executionTimeAllowance = 300
    }

    /// Starts the app at the largest accessibility text size (`UIContentSizeCategory.accessibilityExtraExtraExtraLarge`).
    private static let largestTextArguments = ["-UIPreferredContentSizeCategoryName",
                                               "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    private func launch(seedSampleBook: Bool = false, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += seedSampleBook ? ["-UITestingSeedSampleBook"] : ["-UITesting"]
        if largestText { app.launchArguments += Self.largestTextArguments }
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        return app
    }

    /// The audit types `performAccessibilityAudit(for: .all)` covers, run one at a time: a single `.all` audit
    /// of a whole screen can exceed XCTest's internal audit time limit on slower CI simulators
    /// ("Audit failed to complete in time"), while each type alone finishes well within it.
    private static let allTypes: [XCUIAccessibilityAuditType] = {
        let known: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                   .sufficientElementDescription, .dynamicType, .textClipped, .trait]
        let rest = XCUIAccessibilityAuditType.all.subtracting(known.reduce(into: []) { $0.formUnion($1) })
        return rest.isEmpty ? known : known + [rest]
    }()

    private static let largestTextTypes: [XCUIAccessibilityAuditType] = [.dynamicType, .textClipped]
    private static let defaultSizeTypes = allTypes.filter { !largestTextTypes.contains($0) }

    // MARK: Screen audit

    /// Audits one screen at the default text size and at the largest accessibility size (see the type comment)
    /// and fails the test, after logging every finding, if any finding is not accepted.
    /// `open` navigates from the Library to the screen.
    @MainActor
    private func auditScreen(_ name: String, seedSampleBook: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line,
                             open: @MainActor (XCUIApplication) -> Void) throws {
        var failures: [String] = []
        // Contrast findings accepted only because the element was under a bar's scroll edge effect (key -> log
        // line), and elements that passed the contrast audit clear of the bars on some page.
        var underBars: [String: String] = [:]
        var seenClear: Set<String> = []

        Self.output("Auditing \(name) at the default text size")
        let app = launch(seedSampleBook: seedSampleBook)
        open(app)
        try forEachPage(of: app) {
            for type in Self.defaultSizeTypes {
                let result = try audit(app, type)
                failures += result.failures
                underBars.merge(result.underBars) { old, _ in old }
                if type == .contrast {
                    seenClear.formUnion(Self.textsClearOfBars(in: app).subtracting(result.flaggedKeys))
                }
            }
        }
        // A contrast finding under a bar is only accepted if the same element passed the audit elsewhere.
        for (key, line) in underBars where !seenClear.contains(key) {
            failures.append("Never audited clear of the bars (contrast unverified): \(line)")
        }
        app.terminate()

        Self.output("Auditing \(name) at the largest accessibility text size")
        let large = launch(seedSampleBook: seedSampleBook, largestText: true)
        open(large)
        try forEachPage(of: large) {
            for type in Self.largestTextTypes {
                failures += try audit(large, type).failures
            }
        }

        if !failures.isEmpty {
            XCTFail("\(name): \(failures.count) accessibility audit finding(s):\n" + failures.joined(separator: "\n"),
                    file: file, line: line)
        }
    }

    /// Runs `body` on the current scroll position, then scrolls down by about 40% of the screen and runs it
    /// again, until the content stops moving (at most 10 pages). Small steps, so that every element is audited
    /// at least once away from the top and bottom bars.
    @MainActor
    private func forEachPage(of app: XCUIApplication, _ body: @MainActor () throws -> Void) throws {
        for _ in 0..<10 {
            try body()
            let before = Self.layoutSignature(app)
            Self.scrollDown(app)
            if Self.layoutSignature(app) == before { break }
        }
    }

    @MainActor
    private static func scrollDown(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    private static func layoutSignature(_ app: XCUIApplication) -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        return snapshotElements(snapshot, of: [.staticText]).prefix(12).map { "\($0.label)@\(Int($0.frame.minY))" }
    }

    /// Texts and buttons of the screen from one snapshot (a single query, instead of one per element).
    private static func snapshotElements(_ root: XCUIElementSnapshot,
                                         of types: Set<XCUIElement.ElementType>) -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        var stack = [root]
        while let node = stack.popLast() {
            if types.contains(node.elementType) { found.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// Scrolls down until `element` is visible above the tab bar, then taps it.
    @MainActor
    private static func scrollAndTap(_ element: XCUIElement, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 where !(element.exists && element.isHittable && clearOfBars(element.frame, in: app)) {
            scrollDown(app)
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable", file: file, line: line)
        element.tap()
    }

    // MARK: Bars and the scroll edge effect

    /// The part of the screen between the navigation bar and the tab bar, minus the bands where the system's
    /// scroll edge effect fades content scrolling under the bars (iOS 26). Text in those bands is drawn
    /// faded on purpose, and the contrast audit measures it there; the CI audit flagged rows up to 20 pt
    /// above the tab bar and rows under the navigation bar.
    @MainActor
    private static func clearArea(in app: XCUIApplication) -> (top: CGFloat, bottom: CGFloat) {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let tabBar = app.tabBars.firstMatch
        let top = (navigationBar.exists ? navigationBar.frame.maxY : window.minY) + 24
        let bottom = (tabBar.exists ? tabBar.frame.minY : window.maxY) - 56
        return (top, bottom)
    }

    @MainActor
    private static func clearOfBars(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let area = clearArea(in: app)
        let width = app.windows.firstMatch.frame.width
        return !frame.isEmpty && frame.minY >= area.top && frame.maxY <= area.bottom && frame.minX >= 0
            && frame.maxX <= width
    }

    @MainActor
    private static func key(_ element: XCUIElement) -> String {
        key(type: element.elementType, label: element.label, frame: element.frame)
    }

    private static func key(type: XCUIElement.ElementType, label: String, frame: CGRect) -> String {
        "\(type.rawValue):\(label)@\(Int(frame.minX))"
    }

    /// Keys of the texts and buttons that are entirely in the clear area right now.
    @MainActor
    private static func textsClearOfBars(in app: XCUIApplication) -> Set<String> {
        guard let snapshot = try? app.snapshot() else { return [] }
        let area = clearArea(in: app)
        let width = app.windows.firstMatch.frame.width
        return Set(snapshotElements(snapshot, of: [.staticText, .button]).filter {
            !$0.frame.isEmpty && $0.frame.minY >= area.top && $0.frame.maxY <= area.bottom && $0.frame.minX >= 0
                && $0.frame.maxX <= width
        }.map { key(type: $0.elementType, label: $0.label, frame: $0.frame) })
    }

    // MARK: One audit

    private struct AuditResult {
        var failures: [String] = []
        var underBars: [String: String] = [:]
        var flaggedKeys: Set<String> = []
    }

    /// Runs one audit type (retrying when the audit itself times out) and sorts its findings.
    @MainActor
    private func audit(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) throws -> AuditResult {
        var attempt = 1
        while true {
            do {
                return try auditOnce(app, type)
            } catch let error as NSError
                        where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 && attempt < 3 {
                // "Audit failed to complete in time" (busy CI simulator): not a finding. Let the app settle and
                // run this one type again; a third timeout fails the test.
                Self.output("Accessibility audit timed out for type \(type.rawValue) (attempt \(attempt)); retrying")
                attempt += 1
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    @MainActor
    private func auditOnce(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) throws -> AuditResult {
        // The handler only records findings; element queries and screenshots happen after the audit returns.
        var issues: [XCUIAccessibilityAuditIssue] = []
        try app.performAccessibilityAudit(for: type) { issue in
            issues.append(issue)
            return true // handled here: unaccepted findings fail the test in `auditScreen` after they are logged
        }
        var result = AuditResult()
        for issue in issues {
            let verdict = Self.verdict(issue, in: app)
            let line = Self.log(issue, verdict: verdict, in: app)
            if let element = issue.element, element.exists { result.flaggedKeys.insert(Self.key(element)) }
            switch verdict {
            case .accepted: break
            case .underBar: result.underBars[Self.key(issue.element!)] = line
            case .fails: result.failures.append(line)
            }
        }
        return result
    }

    private enum Verdict: String {
        case accepted, underBar = "under a bar", fails = "FAILS"
    }

    /// Findings we accept (each one is explained in docs/ACCESSIBILITY.md, "Accepted audit findings").
    @MainActor
    private static func verdict(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Verdict {
        guard let element = issue.element, element.exists else { return .fails }
        // The reading preview is content, not chrome: it is drawn at the reader's own point size and theme
        // colours (exactly what the watch shows), so it neither follows Dynamic Type nor the system contrast.
        if element.identifier == "typographyPreview",
           issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped {
            return .accepted
        }
        // Contrast measured inside the scroll edge effect of a bar (the system fades content scrolled under it).
        // Accepted for now; `auditScreen` then requires the same element to pass on another page.
        if issue.auditType == .contrast, !clearOfBars(element.frame, in: app) {
            return .underBar
        }
        return .fails
    }

    /// Writes to the CI log right away: the runner's stdout is a pipe, so `print` is block-buffered and its
    /// output is lost when a test is killed (time limit, crash).
    private static func output(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Prints a finding with its element, frame (and the bars') and, for contrast findings, the contrast
    /// measured from a screenshot of the element, so the CI log shows exactly what was found and why. Failing
    /// findings also attach a screenshot of the screen.
    @MainActor
    @discardableResult
    private static func log(_ issue: XCUIAccessibilityAuditIssue, verdict: Verdict, in app: XCUIApplication) -> String {
        let element = issue.element
        var line = "Accessibility audit issue (\(verdict.rawValue)): type=\(issue.auditType.rawValue) "
            + "\"\(issue.compactDescription)\" element=\(element?.elementType.rawValue ?? 0) "
            + "id=\(element?.identifier ?? "<none>") label=\(element?.label ?? "<none>")"
        if let element, element.exists {
            let area = clearArea(in: app)
            line += " frame=\(element.frame) clearArea=\(Int(area.top))...\(Int(area.bottom))"
            if issue.auditType == .contrast, let measured = ContrastProbe.measure(element) {
                line += " measured=\(measured)"
            }
        }
        if verdict == .fails {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(issue.compactDescription): \(element?.label ?? "")"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Audit finding") { $0.add(attachment) }
        }
        line += " detail=\"\(issue.detailedDescription)\""
        output(line)
        return line
    }

    // MARK: Library

    @MainActor
    func testLibraryEmptyStateAudit() throws {
        try auditScreen("Library (empty)") { app in
            XCTAssertFalse(app.descendants(matching: .any)["libraryRow"].exists, "Library should start empty")
        }
    }

    @MainActor
    func testLibraryWithBookAudit() throws {
        try auditScreen("Library (one book)", seedSampleBook: true) { app in
            let row = app.descendants(matching: .any)["libraryRow"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded sample book not shown")
            XCTAssertTrue(row.label.contains("Alice"), "Row should be one element that includes the title: \(row.label)")
        }
    }

    // MARK: Settings

    @MainActor
    private static func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsAudit() throws {
        try auditScreen("Settings", open: Self.openSettings)
    }

    @MainActor
    func testProgressSyncAudit() throws {
        try auditScreen("Progress Sync") { app in
            Self.openSettings(app)
            app.descendants(matching: .any)["syncSettingsLink"].tap()
            XCTAssertTrue(app.navigationBars["Progress Sync"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Create account"].exists, "Account creation must stay out of the app (5.1.1(v))")
        }
    }

    @MainActor
    func testAcknowledgementsAudit() throws {
        try auditScreen("Acknowledgements") { app in
            Self.openSettings(app)
            Self.scrollAndTap(app.buttons["Acknowledgements"], in: app)
            XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testReadingSettingsAudit() throws {
        try auditScreen("Reading") { app in
            app.tabBars.buttons["Reading"].tap()
            XCTAssertTrue(app.navigationBars["Reading"].waitForExistence(timeout: 5))
        }
    }
}
