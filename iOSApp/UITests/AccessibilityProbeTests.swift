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
                if issues.contains(where: { $0.element == nil }) { Self.dumpFrames(app, "\(screen) [\(variant)] page=\(page)") }
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

    /// Where the bars and the texts are when an element-less finding is reported.
    @MainActor
    private static func dumpFrames(_ app: XCUIApplication, _ tag: String) {
        guard let root = try? app.snapshot() else { return }
        var parts: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            let f = node.frame
            if [.navigationBar, .tabBar].contains(node.elementType) {
                parts.append("BAR\(node.elementType.rawValue)@\(Int(f.minY))-\(Int(f.maxY))")
            } else if [.staticText, .button, .cell].contains(node.elementType), !f.isEmpty {
                parts.append("\(node.elementType.rawValue):\(node.label.prefix(18))@\(Int(f.minY))-\(Int(f.maxY))")
            }
            stack.append(contentsOf: node.children.reversed())
        }
        output("PROBE FRAMES \(tag): " + parts.joined(separator: " | "))
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
        let tabTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
        for _ in 0..<10 where !(row.exists && row.isHittable && row.frame.maxY < tabTop - 16) { scrollDown(app) }
        row.tap()
    }

    @MainActor
    private static func openReading(_ app: XCUIApplication) {
        app.tabBars.buttons["Reading"].tap()
    }

    // Settings and Acknowledgements at AX5 (Dynamic Type, Text clipped).
    @MainActor func testSettings0Base() throws { try probe("Settings", "base", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings1NoHeaders() throws { try probe("Settings", "noHeaders", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings2NoFooterTexts() throws { try probe("Settings", "noFooterTexts", largestText: true, open: Self.openSettings) }
    @MainActor func testSettings3FixedFooters() throws { try probe("Settings", "fixedFooters", largestText: true, open: Self.openSettings) }

    @MainActor func testAck0Base() throws { try probe("Ack", "base", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck1NoHeaders() throws { try probe("Ack", "noHeaders", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck2NoFooterTexts() throws { try probe("Ack", "noFooterTexts", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck3FixedFooters() throws { try probe("Ack", "fixedFooters", largestText: true, open: Self.openAcknowledgements) }
    @MainActor func testAck4NoTabBar() throws { try probe("Ack", "noTabBar", largestText: true, open: Self.openAcknowledgements) }

    // Reading at the default size (element detection: "Potentially inaccessible text").
    @MainActor func testReading0Base() throws { try probe("Reading", "base", largestText: false, open: Self.openReading) }
    @MainActor func testReading1SliderCombine() throws { try probe("Reading", "sliderCombine", largestText: false, open: Self.openReading) }
}
