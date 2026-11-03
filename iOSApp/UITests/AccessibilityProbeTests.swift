import XCTest

// TEMPORARY (branch fix/ax-elementless): bisects the audit findings that come without an element. Each test
// launches the app with one `-AXProbe <variant>` switch (see iOSApp/Support/AXProbe.swift), audits one screen
// page by page and logs "PROBE" lines with the findings per variant. It never fails on findings.
final class AccessibilityProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        executionTimeAllowance = 300
    }

    private static func output(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    @MainActor
    private func probe(_ screen: String, _ variant: String, largestText: Bool,
                       open: @MainActor (XCUIApplication) -> Void) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        if variant != "base" { app.launchArguments += ["-AXProbe", variant] }
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15))
        open(app)
        Thread.sleep(forTimeInterval: 2)
        let types: [XCUIAccessibilityAuditType] = largestText ? [.dynamicType, .textClipped] : [.elementDetection]
        var counts: [String: Int] = [:]
        var total = 0
        for page in 0..<10 {
            for type in types {
                var issues: [XCUIAccessibilityAuditIssue] = []
                do {
                    try app.performAccessibilityAudit(for: type) { issues.append($0); return true }
                } catch {
                    Self.output("PROBE \(screen) [\(variant)] page=\(page) audit error: \(error)")
                }
                for issue in issues {
                    total += 1
                    let element = issue.element
                    let named = element.map { "\($0.elementType.rawValue):\($0.label)" } ?? "nil"
                    if element == nil { counts[issue.compactDescription, default: 0] += 1 }
                    Self.output("PROBE \(screen) [\(variant)] page=\(page) \"\(issue.compactDescription)\" "
                                + "element=\(named) detail=\"\(issue.detailedDescription)\"")
                }
            }
            let before = Self.signature(app)
            Self.scrollDown(app)
            if Self.signature(app) == before { break }
        }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        Self.output("PROBE SUMMARY \(screen) [\(variant)] total=\(total) elementless: \(summary.isEmpty ? "none" : summary)")
        app.terminate()
    }

    @MainActor
    private static func scrollDown(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    }

    @MainActor
    private static func signature(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node.elementType == .staticText { found.append("\(node.label)@\(Int(node.frame.minY))") }
            stack.append(contentsOf: node.children)
        }
        return found
    }

    @MainActor
    private static func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
    }

    @MainActor
    private static func openAcknowledgements(_ app: XCUIApplication) {
        openSettings(app)
        Thread.sleep(forTimeInterval: 1)
        let row = app.buttons["Acknowledgements"]
        let tabTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<10 where !(row.exists && row.isHittable && row.frame.maxY < tabTop - 16) { scrollDown(app) }
        row.tap()
    }

    @MainActor
    private static func openReading(_ app: XCUIApplication) {
        app.tabBars.buttons["Reading"].tap()
    }

    // Settings and Acknowledgements at AX5 (Dynamic Type, Text clipped).
    @MainActor func testSettings0Base() throws { try probe("Settings", "base", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings1SoftEdges() throws { try probe("Settings", "softEdges", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings2NoTabBar() throws { try probe("Settings", "noTabBar", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings3InlineTitle() throws { try probe("Settings", "inlineTitle", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings4NoTitle() throws { try probe("Settings", "noTitle", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings5PlainRows() throws { try probe("Settings", "plainRows", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings6NoLinks() throws { try probe("Settings", "noLinks", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings7NoFooters() throws { try probe("Settings", "noFooters", largestText: true, open: Self.openSettings) }

    @MainActor func testAck0Base() throws { try probe("Ack", "base", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck1SoftEdges() throws { try probe("Ack", "softEdges", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck2NoTabBar() throws { try probe("Ack", "noTabBar", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck4NoTitle() throws { try probe("Ack", "noTitle", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck5PlainRows() throws { try probe("Ack", "plainRows", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck6NoLinks() throws { try probe("Ack", "noLinks", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck7NoFooters() throws { try probe("Ack", "noFooters", largestText: true, open: Self.openAcknowledgements) }

    // Reading at the default size (element detection: "Potentially inaccessible text").
    @MainActor func testReading0Base() throws { try probe("Reading", "base", largestText: false, open: Self.openReading) }
    @MainActor func testReading1SoftEdges() throws { try probe("Reading", "softEdges", largestText: false, open: Self.openReading) }
    @MainActor func testReading2NoTabBar() throws { try probe("Reading", "noTabBar", largestText: false, open: Self.openReading) }
    @MainActor func testReading3InlineTitle() throws { try probe("Reading", "inlineTitle", largestText: false, open: Self.openReading) }
    @MainActor func testReading8NoPreview() throws { try probe("Reading", "noPreview", largestText: false, open: Self.openReading) }
    @MainActor func testReading9SliderTextVisible() throws { try probe("Reading", "sliderTextVisible", largestText: false, open: Self.openReading) }
}
