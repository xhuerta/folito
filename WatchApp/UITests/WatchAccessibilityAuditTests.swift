import XCTest

/// Runs Xcode's automated accessibility audit (`XCUIApplication.performAccessibilityAudit`, watchOS 10+) on
/// every main watch screen: empty library, library with one book, reader, Reading Options, Settings and
/// Typography. The app is launched with `-UITesting` / `-UITestingSeedSampleBook` (Debug builds only; see
/// WatchApp/Support/UITestingSupport.swift).
///
/// Consciously accepted findings are listed in `isAccepted(_:)` and in docs/ACCESSIBILITY.md
/// ("Apple Watch > Accepted audit findings").
final class WatchAccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The audit types `performAccessibilityAudit(for: .all)` covers, run one at a time: a single `.all` audit
    /// of a whole screen can exceed XCTest's internal audit time limit on slower CI simulators
    /// ("Audit failed to complete in time"), while each type alone finishes well within it.
    private static let auditTypes: [XCUIAccessibilityAuditType] = {
        let known: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                   .sufficientElementDescription, .dynamicType, .textClipped, .trait]
        let rest = XCUIAccessibilityAuditType.all.subtracting(known.reduce(into: []) { $0.formUnion($1) })
        return rest.isEmpty ? known : known + [rest]
    }()

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        for type in Self.auditTypes {
            do {
                try auditOnce(app, type)
            } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
                // Timed out (simulator busy); retry this one type once, then let a second timeout fail the test.
                print("Accessibility audit timed out for type \(type.rawValue); retrying once")
                try auditOnce(app, type)
            }
        }
    }

    @MainActor
    private func auditOnce(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) throws {
        try app.performAccessibilityAudit(for: type) { issue in
            let accepted = Self.isAccepted(issue)
            let element = issue.element
            print("Accessibility audit issue (\(accepted ? "accepted" : "FAILS")): type=\(issue.auditType.rawValue) "
                  + "\"\(issue.compactDescription)\" element=\(element?.elementType.rawValue ?? 0) "
                  + "id=\(element?.identifier ?? "<none>") label=\(element?.label ?? "<none>")")
            return accepted // true = ignore this issue; false = report it as a test failure
        }
    }

    /// Findings we accept on purpose (each one is explained in docs/ACCESSIBILITY.md).
    @MainActor
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        switch issue.element?.identifier {
        case "typographyPreview":
            // Content, not chrome: drawn at the reader's own point size and theme colours (what the reader shows).
            return issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped
        case "readerBlock":
            // Book text uses the reader's text size (Dynamic Type only with "Match System Text Size", off by
            // default), and blocks at the top/bottom edge of the scroll view are partly off screen by design.
            return issue.auditType == .dynamicType || issue.auditType == .textClipped
        default:
            return false
        }
    }

    // MARK: Library

    @MainActor
    func testLibraryEmptyStateAudit() throws {
        let app = WatchUI.launch()
        try audit(app)
    }

    @MainActor
    func testLibraryWithBookAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        try audit(app)
    }

    // MARK: Reader

    @MainActor
    func testReaderAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        WatchUI.openReader(app)
        try audit(app)
    }

    @MainActor
    func testReadingOptionsAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        WatchUI.openReader(app)
        WatchUI.openReaderMenu(app)
        try audit(app)
    }

    // MARK: Settings

    @MainActor
    func testSettingsAudit() throws {
        let app = WatchUI.launch()
        WatchUI.openSettings(app)
        try audit(app)
    }

    @MainActor
    func testTypographyAudit() throws {
        let app = WatchUI.launch()
        WatchUI.openSettings(app)
        WatchUI.openTypography(app)
        try audit(app)
    }
}
