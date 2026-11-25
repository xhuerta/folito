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
    private func launch(seedSampleBook: Bool = false, largestText: Bool = false,
                        showTour: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += seedSampleBook ? ["-UITestingSeedSampleBook"] : ["-UITesting"]
        app.launchArguments += extraArguments
        if showTour { app.launchArguments += ["-UITestingShowOnboarding"] }
        if largestText { app.launchArguments += Self.largestTextArguments }
        app.launch()
        if showTour {
            XCTAssertTrue(app.descendants(matching: .any)["onboardingTitle"].waitForExistence(timeout: 15),
                          "Welcome tour did not appear")
        } else {
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        }
        return app
    }

    /// The audit types `performAccessibilityAudit(for: .all)` covers, run one at a time: a single `.all` audit
    /// of a whole screen can exceed XCTest's internal audit time limit on slower CI simulators
    /// ("Audit failed to complete in time"), while each type alone finishes well within it.
    private static let allTypes: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                                 .sufficientElementDescription, .dynamicType,
                                                                 .textClipped, .trait]

    private static let largestTextTypes: [XCUIAccessibilityAuditType] = [.dynamicType, .textClipped]
    private static let defaultSizeTypes = allTypes.filter { !largestTextTypes.contains($0) }

    // MARK: Screen audit

    /// Which passes `auditScreen` runs.
    enum AuditSizes { case both, defaultOnly, largestOnly }

    /// Audits one screen at the default text size and at the largest accessibility size (see the type comment)
    /// and fails the test, after logging every finding, if any finding is not accepted.
    /// `open` navigates from the Library to the screen; `openAtLargestText`, if given, replaces it for the largest
    /// size. `formFooterFindingsAtLargestText` accepts, at the largest size only, the element-less findings that
    /// the screen's `Form` section footers cause (see `verdict`). `afterScrollAtLargestText`, if given, runs after
    /// each scroll of the largest-size pass (to scroll past rows another test audits). `sizes` runs only one of
    /// the two passes, for a screen whose two passes together do not fit in one test's 300 s (the audit of the
    /// other size is then a test of its own).
    @MainActor
    private func auditScreen(_ name: String, seedSampleBook: Bool = false, showTour: Bool = false,
                             extraArguments: [String] = [],
                             sizes: AuditSizes = .both,
                             formFooterFindingsAtLargestText: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line,
                             afterScrollAtLargestText: (@MainActor (XCUIApplication) -> Void)? = nil,
                             openAtLargestText: (@MainActor (XCUIApplication) -> Void)? = nil,
                             open: @MainActor (XCUIApplication) -> Void) throws {
        var failures: [String] = []
        // Contrast findings accepted only because the element was under a bar's scroll edge effect (key -> log
        // line), and elements that passed the contrast audit clear of the bars on some page.
        var underBars: [String: String] = [:]
        var seenClear: Set<String> = []

        if sizes != .largestOnly {
            Self.output("Auditing \(name) at the default text size")
            let app = launch(seedSampleBook: seedSampleBook, showTour: showTour, extraArguments: extraArguments)
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
        }

        if sizes != .defaultOnly {
            Self.output("Auditing \(name) at the largest accessibility text size")
            let large = launch(seedSampleBook: seedSampleBook, largestText: true, showTour: showTour,
                               extraArguments: extraArguments)
            if let openAtLargestText { openAtLargestText(large) } else { open(large) }
            try forEachPage(of: large, afterScroll: afterScrollAtLargestText) {
                for type in Self.largestTextTypes {
                    failures += try audit(large, type, acceptFormFooterFindings: formFooterFindingsAtLargestText).failures
                }
            }
        }

        if !failures.isEmpty {
            XCTFail("\(name): \(failures.count) accessibility audit finding(s):\n" + failures.joined(separator: "\n"),
                    file: file, line: line)
        }
    }

    /// Runs `body` on the current scroll position, then scrolls down by about 40% of the screen and runs it
    /// again, until the content stops moving (at most 10 pages). Small steps, so that every element is audited
    /// at least once away from the top and bottom bars. `afterScroll` runs after each scroll.
    @MainActor
    private func forEachPage(of app: XCUIApplication, afterScroll: (@MainActor (XCUIApplication) -> Void)? = nil,
                             _ body: @MainActor () throws -> Void) throws {
        for _ in 0..<10 {
            try body()
            guard Self.scrollDownIfPossible(app, afterScroll: afterScroll) else { break }
        }
    }

    /// Scrolls down once and tells whether the content moved. A drag that leaves the content where it was is
    /// tried once more before it counts as the end of the content: on CI (PR #124, e0f1a73) the first drag on
    /// Book detail left the screen unchanged, the pass ended after its first page, and the rows it had found
    /// under the tab bar ("Information", "Publisher") were never audited clear of the bars, although every
    /// other run scrolled that screen three times.
    @MainActor
    private static func scrollDownIfPossible(_ app: XCUIApplication,
                                             afterScroll: (@MainActor (XCUIApplication) -> Void)? = nil) -> Bool {
        let before = layoutSignature(app)
        for _ in 0..<2 {
            scrollDown(app)
            afterScroll?(app)
            if layoutSignature(app) != before { return true }
        }
        return false
    }

    @MainActor
    private static func scrollDown(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitForScrollToSettle(app)
    }

    /// Waits until the content stops moving after a drag. The list keeps decelerating after XCTest's idle wait
    /// returns: in the AX5 Settings pass (CI on 240711f) `skipBookDetailsRows` read the button's frame while it
    /// was still moving, saw it not yet fully on screen, and the audit a moment later found it fully on screen.
    @MainActor
    private static func waitForScrollToSettle(_ app: XCUIApplication) {
        var previous = layoutSignature(app)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            let current = layoutSignature(app)
            if current == previous { return }
            previous = current
        }
    }

    /// Scrolls down until the content stops moving.
    @MainActor
    private static func scrollToEnd(_ app: XCUIApplication) {
        for _ in 0..<8 {
            guard scrollDownIfPossible(app) else { break }
        }
    }

    /// Labels and positions of the texts on screen: unchanged after a scroll means the end was reached.
    @MainActor
    private static func layoutSignature(_ app: XCUIApplication) -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        let screen = app.windows.firstMatch.frame
        return snapshotElements(snapshot, of: [.staticText])
            .filter { $0.frame.intersects(screen) }
            .map { "\($0.label)@\(Int($0.frame.minY))" }
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

    /// Scrolls until the point where `element` is tapped (its centre) is clear of the bars, then taps it, with
    /// `RowNavigation` (shared with CatalogsUITests): drags from the left margin, where no row is, by a computed
    /// distance without a fling. With drags from the middle of the screen, a slow drag on an AX5 catalog row
    /// became a tap and opened the wrong catalog (CI run 45522603339, `testCatalogSignInAudit`); and requiring the
    /// whole frame between the bars could scroll a row taller than the clear area minus one step past the top
    /// (CI run 45490867043). With `expecting`, the tap is repeated once if it did not navigate (the element is
    /// still there and the destination did not appear); the caller still asserts the destination.
    @MainActor
    private static func scrollAndTap(_ element: XCUIElement, in app: XCUIApplication,
                                     expecting destination: XCUIElement? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) {
        RowNavigation.reveal(element, in: app)
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable", file: file, line: line)
        if let destination {
            RowNavigation.open(element, in: app, expecting: destination)
        } else {
            element.tap()
        }
    }

    // MARK: Bars and the scroll edge effect

    /// The part of the screen between the navigation bar and the tab bar. The screens use hard scroll edges
    /// (`readableScrollEdges()`), so text is drawn at full contrast up to the bars; text scrolled under a bar is
    /// covered by it, and the contrast audit measures it against the bar.
    @MainActor
    private static func clearArea(in app: XCUIApplication) -> (top: CGFloat, bottom: CGFloat) {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let tabBar = app.tabBars.firstMatch
        // The scroll edge effect reaches a little past the bars' frames: text within 16 pt of a bar was flagged
        // for contrast although a screenshot measured 21:1 (CI run 41647325837, "Paragraph Spacing").
        let top = (navigationBar.exists ? navigationBar.frame.maxY : window.minY) + 16
        let bottom = (tabBar.exists ? tabBar.frame.minY : window.maxY) - 16
        return (top, bottom)
    }

    /// A navigation bar at least this tall shows its expanded large title (106 pt at the default size on CI's
    /// iPhone; the collapsed, inline bar is 54 pt).
    private static let largeTitleBarMinHeight: CGFloat = 80

    @MainActor
    private static func clearOfBars(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let area = clearArea(in: app)
        let width = app.windows.firstMatch.frame.width
        return !frame.isEmpty && frame.minY >= area.top && frame.maxY <= area.bottom && frame.minX >= 0
            && frame.maxX <= width
    }

    /// Within 40 pt below the navigation bar's bottom edge while it shows its collapsed (inline) bar, where the
    /// hard scroll edge effect can still lower measured contrast once content is scrolled under the bar. Edit
    /// Catalog's default-size content is a few points taller than the screen: after a drag it rests about 12 pt
    /// up, the first card's top edge under the bar, and its first label ("Name", top 33 pt below the bar's frame,
    /// 126 to 159 pt) was flagged although a screenshot measured 21:1 there and the same label passed at rest (CI runs
    /// 45508887501, 45516248728; 32 pt, as for the tab bar, missed it by 1 pt).
    @MainActor
    private static func nearNavigationBar(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let navigationBar = app.navigationBars.firstMatch
        return navigationBar.exists && navigationBar.frame.height < largeTitleBarMinHeight
            && frame.minY < navigationBar.frame.maxY + 40
    }

    /// Within 32 pt of the tab bar's top edge, where its scroll edge effect can still lower measured contrast.
    @MainActor
    private static func nearTabBar(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let tabBar = app.tabBars.firstMatch
        return tabBar.exists && frame.maxY > tabBar.frame.minY - 32
    }

    @MainActor
    private static func key(_ element: XCUIElement) -> String {
        key(type: element.elementType, label: element.label, frame: element.frame)
    }

    private static func key(type: XCUIElement.ElementType, label: String, frame: CGRect) -> String {
        "\(type.rawValue):\(label)@\(Int(frame.minX))"
    }

    /// Keys of the texts and buttons that are entirely in the clear area right now.
    ///
    /// While the navigation bar shows its expanded large title, the content is at rest at the top of the list:
    /// nothing is scrolled under the bar, so there is no scroll edge effect below it and the 16 pt margin of
    /// `clearArea` does not apply at the top. Without this, the first row of a list that is too short to scroll
    /// it clear of the collapsed bar (the compact "No Apple Watch" notice in the Readest offline library, CI on
    /// 240711f: 168 pt bar bottom, notice right below it at the top, under the collapsed bar once scrolled) could
    /// never count as audited clear of the bars, although its contrast was audited, and passed, at the top.
    @MainActor
    private static func textsClearOfBars(in app: XCUIApplication) -> Set<String> {
        guard let snapshot = try? app.snapshot() else { return [] }
        var area = clearArea(in: app)
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists, navigationBar.frame.height >= largeTitleBarMinHeight {
            area.top = navigationBar.frame.maxY
        }
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
    private func audit(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType,
                       acceptFormFooterFindings: Bool = false) throws -> AuditResult {
        var attempt = 1
        while true {
            do {
                return try auditOnce(app, type, acceptFormFooterFindings: acceptFormFooterFindings)
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
    private func auditOnce(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType,
                           acceptFormFooterFindings: Bool) throws -> AuditResult {
        // The handler only records findings; element queries and screenshots happen after the audit returns.
        var issues: [XCUIAccessibilityAuditIssue] = []
        try app.performAccessibilityAudit(for: type) { issue in
            issues.append(issue)
            return true // handled here: unaccepted findings fail the test in `auditScreen` after they are logged
        }
        var result = AuditResult()
        for issue in issues {
            let verdict = Self.verdict(issue, in: app, acceptFormFooterFindings: acceptFormFooterFindings)
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

    private static let formFooterDescriptions: Set<String> = ["Dynamic Type font sizes are unsupported",
                                                              "Dynamic Type font sizes are partially unsupported",
                                                              "Text clipped"]

    private enum Verdict: String {
        case accepted, underBar = "under a bar", fails = "FAILS"
    }

    /// Findings we accept (each one is explained in docs/ACCESSIBILITY.md, "Accepted audit findings").
    @MainActor
    private static func verdict(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication,
                                acceptFormFooterFindings: Bool = false) -> Verdict {
        // Settings and Acknowledgements at AX5: Dynamic Type and Text clipped findings with no element, caused by
        // the system's rendering of `Form` / `List` section footers (removing only the footer texts removed every
        // one of them on Acknowledgements and all but one on Settings, PR #39). The footer text itself scales and
        // is not clipped (its frame grows to 267 pt at AX5), and the audit names no element to check.
        if acceptFormFooterFindings, issue.element == nil,
           issue.auditType == .dynamicType || issue.auditType == .textClipped,
           formFooterDescriptions.contains(issue.compactDescription) {
            return .accepted
        }
        guard let element = issue.element, element.exists else { return .fails }
        // The reading preview is content, not chrome: it is drawn at the reader's own point size and theme
        // colours (exactly what the watch shows), so it neither follows Dynamic Type nor the system contrast.
        if element.identifier == "typographyPreview",
           issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped {
            return .accepted
        }
        // Contrast measured on text partly scrolled under a bar (measured against the bar, not the page).
        // Accepted for now; `auditScreen` then requires the same element to pass on another page.
        // Above the tab bar the effect reaches further: "327 bytes" on Book detail, ending 2.7 pt inside the
        // 16 pt margin, failed the audit although a screenshot measured 5.64:1 (PR #124). So a contrast finding
        // within 32 pt of the tab bar also counts as under a bar. It is still verified: the same text must pass
        // clear of the bars, with the usual 16 pt margin, on another page. The same applies within 40 pt below a
        // collapsed navigation bar (`nearNavigationBar`; "Name" on Edit Catalog, 33 pt below the bar, measured 21:1).
        if issue.auditType == .contrast,
           !clearOfBars(element.frame, in: app) || nearTabBar(element.frame, in: app)
            || nearNavigationBar(element.frame, in: app) {
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
            Self.waitForWatchStatus(app)
        }
    }

    @MainActor
    func testLibraryWithBookAudit() throws {
        try auditScreen("Library (one book)", seedSampleBook: true,
                        afterScrollAtLargestText: Self.scrollToLastRow,
                        openAtLargestText: Self.openWatchNoticeAtTop) { app in
            let row = app.descendants(matching: .any)["libraryRow"]
            // At the largest text size the watch status above the book can fill the screen: scroll to the row.
            for _ in 0..<6 where !row.waitForExistence(timeout: 2) { Self.scrollDown(app) }
            XCTAssertTrue(row.exists, "Seeded sample book not shown")
            XCTAssertTrue(row.label.contains("Alice"), "Row should be one element that includes the title: \(row.label)")
        }
    }

    /// A mocked Readest library (`-UITestingMockReadest`): one local book that is also in Readest and three
    /// cloud-only rows with covers and download buttons. At the largest size the local row is audited by
    /// `testLibraryReadestLocalRowAudit` (see `openCloudRowsAtLargestText`).
    @MainActor
    func testLibraryWithReadestAudit() throws {
        try auditScreen("Library (Readest)", seedSampleBook: true, extraArguments: ["-UITestingMockReadest"],
                        openAtLargestText: Self.openCloudRowsAtLargestText, open: Self.openCloudRowsAtTop)
    }

    /// The same library offline: cloud-only rows are dimmed and say they need a connection.
    @MainActor
    func testLibraryReadestOfflineAudit() throws {
        try auditScreen("Library (Readest, offline)", seedSampleBook: true,
                        extraArguments: ["-UITestingMockReadest", "-UITestingReadestOffline"],
                        openAtLargestText: Self.openCloudRowsAtLargestText, open: Self.openCloudRowsAtTop)
    }

    /// The Readest library filtered to *On This iPhone*: the local book that is also in Readest (with its
    /// Readest icon) is the last row, as in `testLibraryWithBookAudit`.
    @MainActor
    func testLibraryReadestLocalRowAudit() throws {
        try auditScreen("Library (Readest, on this iPhone)", seedSampleBook: true,
                        extraArguments: ["-UITestingMockReadest", "-library.filter", "onThisDevice"],
                        afterScrollAtLargestText: Self.scrollToLastRow,
                        openAtLargestText: Self.openWatchNoticeAtTop) { app in
            let row = app.descendants(matching: .any)["libraryRow"]
            for _ in 0..<6 where !row.waitForExistence(timeout: 2) { Self.scrollDown(app) }
            XCTAssertTrue(row.exists, "Local book not shown")
            XCTAssertFalse(app.descendants(matching: .any)["libraryCloudRow"].exists, "Filter should hide Readest-only books")
        }
    }

    @MainActor
    private static func openCloudRows(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["libraryCloudRow"]
        // The Readest rows load after the Library appears: give them time before scrolling to them.
        _ = row.waitForExistence(timeout: 10)
        for _ in 0..<6 where !row.waitForExistence(timeout: 2) { scrollDown(app) }
        XCTAssertTrue(row.exists, "Readest-only books not shown")
    }

    /// `openCloudRows`, then back to the top if it had to scroll. At the default size the Readest library is only a
    /// little taller than the screen: once scrolled, the list cannot scroll on, and the compact watch notice stays
    /// within 16 pt of the navigation bar on every page, where its contrast is never audited clear of the bars.
    /// At the top of the list the notice is the first row, right below the large title, as in the one-book audit:
    /// the check is that it is back there, wholly below the navigation bar. 16 pt clear is not reachable at the top,
    /// and not needed there: with the large title expanded nothing is under the bar (`textsClearOfBars`).
    /// A tap on the status bar scrolls the list to its top without pulling it past the top (it is refreshable).
    /// Fallback: slow drags by the distance the notice still needs, held before release so the list does not fling.
    @MainActor
    private static func openCloudRowsAtTop(_ app: XCUIApplication) {
        openCloudRows(app)
        let notice = app.descendants(matching: .any)["libraryWatchNotice"]
        let window = app.windows.firstMatch
        let navigationBar = app.navigationBars.firstMatch
        func barBottom() -> CGFloat { navigationBar.exists ? navigationBar.frame.maxY : window.frame.minY }
        func atTop() -> Bool { notice.exists && !notice.frame.isEmpty && notice.frame.minY >= barBottom() - 0.5 }
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.width * 0.2, dy: 20)).tap()
        for _ in 0..<12 where !(notice.waitForExistence(timeout: 2) && atTop()) {
            let distance = notice.exists ? min(max(barBottom() - notice.frame.minY + 8, 30), 300) : 150
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(atTop(), "Watch notice not back at the top of the list: "
                      + "\(notice.exists ? "\(notice.frame)" : "missing"), navigation bar bottom \(barBottom())")
    }

    /// Waits for the Library's watch status (the "No Apple Watch" card on CI). It shows nothing until the watch
    /// session has activated, which can take longer than the Library takes to appear: on CI (PR #124, e0f1a73)
    /// the first page of the empty Library was apparently audited before the card was there (no finding at all on
    /// it, not even the bottom buttons flagged in other runs), so the card's title was never
    /// audited clear of the bars; on the only other page it was scrolled under the navigation bar.
    @MainActor
    private static func waitForWatchStatus(_ app: XCUIApplication) {
        let titles = ["No Apple Watch", "Folito Isn’t on Your Apple Watch", "Apple Watch connected",
                      "Books are sent to your Apple Watch in the background."]
        let status = app.staticTexts.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        // 30 s: the first test of a shard launches the app on a freshly booted simulator, where the launch alone
        // took 10 s and the session had not activated 10 s after the Library appeared (PR #211, job 139333803759,
        // `testLibraryEmptyStateAudit`, which passed on another branch's run the same day).
        XCTAssertTrue(status.waitForExistence(timeout: 30), "Watch status not shown")
        waitForScrollToSettle(app)
    }

    /// Largest-size pass of the libraries whose book is the last row: the first page is the top of the list (the
    /// compact watch notice), not scrolled to the row first.
    @MainActor
    private static func openWatchNoticeAtTop(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["libraryWatchNotice"].waitForExistence(timeout: 10),
                      "Compact watch notice not shown")
    }

    /// After the first page of the largest-size pass, go straight to the end of the list. At AX5 the compact watch
    /// notice is shorter than the old card, so on a page in between the book row was fully on screen in the middle
    /// of the list, the case described above `openCloudRowsAtLargestText`: the audits re-render the screen at
    /// smaller sizes at that offset, the row moves off the screen and its texts are flagged. At the end it is the
    /// last row of a list that cannot stay scrolled, where it passes.
    @MainActor
    private static func scrollToLastRow(_ app: XCUIApplication) {
        scrollToEnd(app)
        XCTAssertTrue(app.descendants(matching: .any)["libraryRow"].exists, "Book row not shown at the end of the list")
    }

    /// At the largest size the "No Apple Watch" card fills the first screen, so the local row is fully on screen
    /// only at a scroll offset in the middle of the list. The Dynamic Type and Text clipped audits re-render the
    /// screen at smaller sizes at that same offset, where the shorter rows have moved the local row off the
    /// screen, and they flag every text in it (CI runs on d8be657 and 92d96bf; the same row passes as the last
    /// row of the list). So this pass starts below the local row, which `testLibraryReadestLocalRowAudit` audits.
    @MainActor
    private static func openCloudRowsAtLargestText(_ app: XCUIApplication) {
        openCloudRows(app)
        let local = app.descendants(matching: .any)["libraryRow"]
        for _ in 0..<6 where local.exists && local.frame.maxY > clearArea(in: app).top { scrollDown(app) }
        XCTAssertFalse(local.exists && local.frame.maxY > clearArea(in: app).top, "Local row still on screen")
        XCTAssertTrue(app.descendants(matching: .any)["libraryCloudRow"].exists, "Readest-only books not shown")
    }

    // MARK: Library search and browse (#114, shard `browse`)

    /// Types `text` (ending in a return, which closes the keyboard) into the Library's search field.
    @MainActor
    private static func searchLibrary(_ text: String, in app: XCUIApplication) {
        waitForWatchStatus(app)
        let field = app.textFields["librarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Library search field missing")
        RowNavigation.reveal(field, in: app)
        field.tap()
        field.typeText(text)
        waitForScrollToSettle(app)
    }

    /// Searches, then scrolls to the end of the list and checks that `expected` is there. At the largest size the
    /// "No Apple Watch" notice under the field fills the screen, so the results start below it, and List rows
    /// below the screen are not in the accessibility tree (CI job 139333803627: "mars" found nothing to look at
    /// right after typing). The largest-size pass starts at the end, where the last row is the last row of the
    /// list (see "Rows in the middle of a long list at AX5" in docs/ACCESSIBILITY.md); the field at the top is
    /// audited at that size by `testLibraryNoResultsAudit`'s first page.
    @MainActor
    private static func searchAndScrollToEnd(_ text: String, expecting identifier: String, _ message: String,
                                             in app: XCUIApplication) {
        searchLibrary(text, in: app)
        let expected = app.descendants(matching: .any)[identifier]
        RowNavigation.reveal(expected, in: app)
        XCTAssertTrue(expected.waitForExistence(timeout: 5), message)
        scrollToEnd(app)
        XCTAssertTrue(expected.exists, message)
    }

    /// Eight books (`-UITestingSeedLargeLibrary`, so the search field shows) searched for "mars": the field with
    /// its text and clear button, and the three Barsoom books. At the largest size the pass starts at the end of
    /// the results (`searchAndScrollToEnd`).
    @MainActor
    func testLibrarySearchAudit() throws {
        try auditScreen("Library (search)", extraArguments: ["-UITestingSeedLargeLibrary"],
                        afterScrollAtLargestText: Self.scrollToLastRow,
                        openAtLargestText: { app in
                            Self.searchAndScrollToEnd("mars\n", expecting: "libraryRow", "No search results", in: app)
                        }) { app in
            Self.searchLibrary("mars\n", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["libraryRow"].waitForExistence(timeout: 5), "No search results")
            XCTAssertTrue(app.buttons["librarySearchClear"].exists, "Clear Search button missing")
        }
    }

    /// A search that finds nothing: the No Results view under the field. At the largest size the first page is
    /// the top of the list (the field with its text and *Clear Search*), then the view, which is below the watch
    /// notice there.
    @MainActor
    func testLibraryNoResultsAudit() throws {
        try auditScreen("Library (no results)", extraArguments: ["-UITestingSeedLargeLibrary"],
                        openAtLargestText: { app in
                            Self.searchLibrary("zzzz\n", in: app)
                            XCTAssertTrue(app.buttons["librarySearchClear"].exists, "Clear Search button missing")
                        }) { app in
            Self.searchLibrary("zzzz\n", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["libraryNoResults"].waitForExistence(timeout: 5),
                          "No Results not shown")
        }
    }

    /// The No Results view itself at the largest size, which the pass above reaches only by scrolling: revealed,
    /// then audited from there to the end.
    @MainActor
    func testLibraryNoResultsLargestTextAudit() throws {
        try auditScreen("Library (no results)", extraArguments: ["-UITestingSeedLargeLibrary"], sizes: .largestOnly) { app in
            Self.searchAndScrollToEnd("zzzz\n", expecting: "libraryNoResults", "No Results not shown", in: app)
        }
    }

    @MainActor
    private static func openAuthors(_ app: XCUIApplication) {
        waitForWatchStatus(app)
        XCTAssertTrue(app.descendants(matching: .any)["librarySectionHeader"].waitForExistence(timeout: 10),
                      "Author sections not shown")
    }

    @MainActor
    private static func openSeries(_ app: XCUIApplication) {
        waitForWatchStatus(app)
        let barsoom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'librarySectionHeader' AND label == 'Barsoom'")).firstMatch
        XCTAssertTrue(barsoom.waitForExistence(timeout: 10), "Barsoom section not shown")
    }

    private static let authorsArguments = ["-UITestingSeedCovers", "-library.browse", "authors"]
    private static let seriesArguments = ["-UITestingSeedCovers", "-library.browse", "series"]

    /// *By Author* (`-library.browse authors`) with the three `-UITestingSeedCovers` books: a section per author,
    /// its header a header. The two sizes are two tests: together they took 229 s on CI (job 139333803627),
    /// over the 180 s per-test allowance.
    @MainActor
    func testLibraryAuthorsAudit() throws {
        try auditScreen("Library (by author)", extraArguments: Self.authorsArguments, sizes: .defaultOnly,
                        open: Self.openAuthors)
    }

    /// The same at the largest size: the top of the list, then its end (`scrollToLastRow`).
    @MainActor
    func testLibraryAuthorsLargestTextAudit() throws {
        try auditScreen("Library (by author)", extraArguments: Self.authorsArguments, sizes: .largestOnly,
                        afterScrollAtLargestText: Self.scrollToLastRow, open: Self.openAuthors)
    }

    /// *By Series* (`-library.browse series`): *Barsoom* (The Gods of Mars), then *Not in a Series*.
    @MainActor
    func testLibrarySeriesAudit() throws {
        try auditScreen("Library (by series)", extraArguments: Self.seriesArguments, sizes: .defaultOnly,
                        open: Self.openSeries)
    }

    @MainActor
    func testLibrarySeriesLargestTextAudit() throws {
        try auditScreen("Library (by series)", extraArguments: Self.seriesArguments, sizes: .largestOnly,
                        afterScrollAtLargestText: Self.scrollToLastRow, open: Self.openSeries)
    }

    // MARK: Book detail

    /// The detail screen of a book with a cover, series and description (`-UITestingSeedCovers`).
    @MainActor
    func testBookDetailAudit() throws {
        try auditScreen("Book detail", extraArguments: ["-UITestingSeedCovers"]) { app in
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH 'The Gods of Mars'")).firstMatch
            for _ in 0..<8 where !(row.exists && row.isHittable) { Self.scrollDown(app) }
            XCTAssertTrue(row.exists, "Seeded book not shown")
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5)
                          || app.navigationBars["The Gods of Mars"].waitForExistence(timeout: 5), "Detail did not open")
        }
    }

    /// *Find Details Online* with a mocked Open Library (`-UITestingMockOnlineMetadata`): the sheet with one match
    /// (cover, title, author, year, description, the separate Use actions). docs/ONLINE_METADATA.md.
    @MainActor
    func testOnlineMatchSheetAudit() throws {
        try auditScreen("Find Details Online", seedSampleBook: true, extraArguments: ["-UITestingMockOnlineMetadata"]) { app in
            let row = app.descendants(matching: .any)["libraryRow"]
            for _ in 0..<8 where !(row.exists && row.isHittable) { Self.scrollDown(app) }
            XCTAssertTrue(row.exists, "Sample book not shown")
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5), "Detail did not open")
            Self.scrollAndTap(app.buttons["bookDetailFindOnline"], in: app)
            XCTAssertTrue(app.descendants(matching: .any)["onlineMatchReview"].waitForExistence(timeout: 10), "Match not shown")
            _ = app.buttons["onlineUseCover"].waitForExistence(timeout: 5)
        }
    }

    // MARK: Catalogs (OPDS)

    /// Library › + › Catalogs with `-UITestingMockCatalogs`: fixed feeds built in code, no network (docs/OPDS.md).
    @MainActor
    private static func openCatalogs(_ app: XCUIApplication) {
        let menu = app.buttons["libraryAddMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add menu missing")
        menu.tap()
        let item = app.buttons["libraryCatalogs"].exists ? app.buttons["libraryCatalogs"] : app.buttons["Catalogs"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Catalogs menu item missing")
        item.tap()
        XCTAssertTrue(app.navigationBars["Catalogs"].waitForExistence(timeout: 5), "Catalogs did not open")
        _ = app.descendants(matching: .any)["catalogRow"].waitForExistence(timeout: 5)
    }

    /// Opens Standard Ebooks (a page of books from the fixture) and waits for its rows.
    @MainActor
    private static func openCatalogPage(_ app: XCUIApplication) {
        openCatalogs(app)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'catalogRow' AND label BEGINSWITH 'Standard Ebooks'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Standard Ebooks not listed")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["catalogBookRow"].waitForExistence(timeout: 10), "Catalog page did not load")
        waitForScrollToSettle(app)
    }

    /// The Catalogs list: the two presets (with the note under them) and two added catalogs, one signed in
    /// ("Signed in as"), with *Add Catalog…*.
    @MainActor
    func testCatalogsListAudit() throws {
        try auditScreen("Catalogs", extraArguments: ["-UITestingMockCatalogs"], open: Self.openCatalogs)
    }

    /// Opens the Add Catalog form from the Catalogs list.
    @MainActor
    private static func openAddCatalog(_ app: XCUIApplication) {
        openCatalogs(app)
        scrollAndTap(app.buttons["catalogsAdd"], in: app, expecting: app.navigationBars["Add Catalog"])
        XCTAssertTrue(app.navigationBars["Add Catalog"].waitForExistence(timeout: 5), "Add Catalog did not open")
    }

    /// The Add Catalog form (labels above the fields, footer, the Add Catalog action row), at the default text
    /// size. Its two passes are two tests: together they took 232 to 360 s on CI, past the 300 s allowance (the
    /// largest-size pass alone about 200 s; PR #193, job 139009834893).
    @MainActor
    func testAddCatalogAudit() throws {
        try auditScreen("Add Catalog", extraArguments: ["-UITestingMockCatalogs"], sizes: .defaultOnly,
                        open: Self.openAddCatalog)
    }

    /// The Add Catalog form at the largest accessibility text size (see `testAddCatalogAudit`).
    @MainActor
    func testAddCatalogLargestTextAudit() throws {
        try auditScreen("Add Catalog", extraArguments: ["-UITestingMockCatalogs"], sizes: .largestOnly,
                        formFooterFindingsAtLargestText: true, open: Self.openAddCatalog)
    }

    /// A page of a catalog: books with covers, one offered only as PDF ("Not available as EPUB"), Load More.
    @MainActor
    func testCatalogPageAudit() throws {
        try auditScreen("Catalog page", extraArguments: ["-UITestingMockCatalogs"], open: Self.openCatalogPage)
    }

    /// A catalog book: cover, title, author, Download, description and the information card.
    @MainActor
    func testCatalogBookAudit() throws {
        try auditScreen("Catalog book", extraArguments: ["-UITestingMockCatalogs"]) { app in
            Self.openCatalogPage(app)
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'catalogBookRow' AND label BEGINSWITH 'A Fighting Man of Mars'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Book row missing")
            row.tap()
            XCTAssertTrue(app.buttons["catalogDownload"].waitForExistence(timeout: 5), "Book screen did not open")
            Self.waitForScrollToSettle(app)
        }
    }

    /// Opens the added "Family Server", which answers 401 without a sign-in, and waits for its Sign In button.
    @MainActor
    private static func openSignInNeeded(_ app: XCUIApplication) {
        openCatalogs(app)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'catalogRow' AND label BEGINSWITH 'Family Server'")).firstMatch
        scrollAndTap(row, in: app, expecting: app.buttons["catalogSignIn"])
        XCTAssertTrue(app.buttons["catalogSignIn"].waitForExistence(timeout: 10), "Sign In not offered")
        waitForScrollToSettle(app)
    }

    /// A catalog page that needs a sign-in: the message, Sign In… and Try Again.
    @MainActor
    func testCatalogSignInNeededAudit() throws {
        try auditScreen("Catalog sign-in needed", extraArguments: ["-UITestingMockCatalogs"], open: Self.openSignInNeeded)
    }

    /// The Sign In form (user name and password with labels above them, the footer, the Sign In action row).
    @MainActor
    func testCatalogSignInAudit() throws {
        try auditScreen("Catalog sign-in", extraArguments: ["-UITestingMockCatalogs"],
                        formFooterFindingsAtLargestText: true) { app in
            Self.openSignInNeeded(app)
            Self.scrollAndTap(app.buttons["catalogSignIn"], in: app)
            XCTAssertTrue(app.navigationBars["Sign In"].waitForExistence(timeout: 5), "Sign In did not open")
        }
    }

    /// Edit Catalog for "Home Library", which has a saved sign-in: name, address, sign-in fields and footers,
    /// Save, Remove Sign-In and Remove Catalog. Opened from the catalog page's Edit button.
    @MainActor
    func testEditCatalogAudit() throws {
        try auditScreen("Edit Catalog", extraArguments: ["-UITestingMockCatalogs"],
                        formFooterFindingsAtLargestText: true) { app in
            Self.openCatalogs(app)
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'catalogRow' AND label BEGINSWITH 'Home Library'")).firstMatch
            Self.scrollAndTap(row, in: app, expecting: app.buttons["catalogEdit"])
            let edit = app.buttons["catalogEdit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit not offered")
            edit.tap()
            XCTAssertTrue(app.navigationBars["Edit Catalog"].waitForExistence(timeout: 5), "Edit Catalog did not open")
        }
    }

    /// Search results of the signed-in "Home Library" (its feed offers OpenSearch), reached through the page's
    /// search field: the heading with the terms, book rows with covers and Load More.
    @MainActor
    func testCatalogSearchAudit() throws {
        try auditScreen("Catalog search", extraArguments: ["-UITestingMockCatalogs"]) { app in
            Self.openCatalogs(app)
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'catalogRow' AND label BEGINSWITH 'Home Library'")).firstMatch
            let field = app.textFields["catalogSearchField"]
            Self.scrollAndTap(row, in: app, expecting: field)
            XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field missing")
            field.tap()
            field.typeText("mars\n")
            XCTAssertTrue(app.descendants(matching: .any)["catalogBookRow"].waitForExistence(timeout: 10), "No results")
            Self.waitForScrollToSettle(app)
        }
    }

    // MARK: Welcome tour

    /// The tour's first page (it opens on first launch). Its later pages use the same layout.
    @MainActor
    func testWelcomeTourAudit() throws {
        try auditScreen("Welcome tour", showTour: true) { _ in }
    }

    // MARK: Settings

    @MainActor
    private static func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// The whole Settings screen. At the largest size the pass skips the pages where the *Book Details* rows
    /// are fully on screen in the middle of the list (`skipBookDetailsRows`); `testSettingsBookDetailsAudit`
    /// audits them.
    @MainActor
    func testSettingsAudit() throws {
        try auditScreen("Settings", formFooterFindingsAtLargestText: true,
                        afterScrollAtLargestText: Self.skipBookDetailsRows, open: Self.openSettings)
    }

    /// The *Book Details* section alone (`-UITestingSettingsBookDetailsOnly`): its rows are at the top of the
    /// screen, fully visible at scroll offset 0, at every text size.
    @MainActor
    func testSettingsBookDetailsAudit() throws {
        try auditScreen("Settings (Book Details)", extraArguments: ["-UITestingSettingsBookDetailsOnly"],
                        formFooterFindingsAtLargestText: true) { app in
            Self.openSettings(app)
            let start = app.buttons["onlineBulkStart"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "Book Details not shown")
            XCTAssertTrue(start.exists && Self.clearOfBars(start.frame, in: app),
                          "Book Details rows not on the first screen: \(start.frame)")
            XCTAssertFalse(app.descendants(matching: .any)["syncSettingsLink"].exists, "Only Book Details should be shown")
        }
    }

    /// At the largest size *Look Up Missing Details Now* is fully on screen only in the middle of the Settings
    /// list. There the Dynamic Type audit, which re-renders the screen at smaller sizes at the same scroll
    /// offset, flagged it ("partially unsupported") while the toggle above and the link below, also fully on
    /// screen, passed, and on no other page (CI on c849128). The same artifact as the
    /// Library's mid-list row (`openCloudRowsAtLargestText`). So on those pages the pass scrolls on until the
    /// button is above the screen.
    ///
    /// The skip starts as soon as any part of the button is on screen, not only when all of it is: the audit
    /// re-renders the screen at smaller sizes at the same scroll offset, where the rows above the button are
    /// shorter and it moves up. On CI (PR #124) the button was partly below the screen at AX5 when this ran, so
    /// a "fully on screen" check did not skip, and the audit then reported it fully on screen at 349–567 pt.
    @MainActor
    private static func skipBookDetailsRows(_ app: XCUIApplication) {
        let start = app.buttons["onlineBulkStart"]
        let screen = app.windows.firstMatch.frame
        guard start.exists else { return }
        let frame = start.frame
        guard !frame.isEmpty, frame.intersects(screen) else { return }
        output("Skipping the Book Details rows at the largest size (button at \(frame))")
        for _ in 0..<6 where start.exists && start.frame.maxY > clearArea(in: app).top { scrollDown(app) }
        XCTAssertFalse(start.exists && start.frame.maxY > clearArea(in: app).top, "Book Details rows still on screen")
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
        try auditScreen("Acknowledgements", formFooterFindingsAtLargestText: true) { app in
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
