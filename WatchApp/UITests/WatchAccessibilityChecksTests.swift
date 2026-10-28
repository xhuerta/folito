import XCTest

/// Explicit accessibility checks on the main watch screens, complementing Xcode's automated audit
/// (WatchAccessibilityAuditTests):
/// - every interactive element (button, switch, stepper, slider, link) has a non-empty label that does not
///   look like a raw identifier, SF Symbol name, file name or document hash;
/// - key elements have the expected identifier, element type, label, value and selected state;
/// - at the largest accessibility text size (AX5, `UICTContentSizeCategoryAccessibilityXXXL`) the primary
///   controls of each screen still exist and are hittable.
/// See docs/ACCESSIBILITY.md, "Apple Watch > Automated checks".
final class WatchAccessibilityChecksTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Label checks

    private static let interactiveTypes: Set<XCUIElement.ElementType> = [.button, .switch, .stepper, .slider, .link]

    /// Interactive elements currently in the accessibility tree (on-screen rows of lazy lists only).
    @MainActor
    private func interactiveElements(in app: XCUIApplication) throws -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            if Self.interactiveTypes.contains(node.elementType), !node.frame.isEmpty { found.append(node) }
            node.children.forEach(walk)
        }
        walk(try app.snapshot())
        return found
    }

    @MainActor
    private func assertInteractiveElementsAreLabelled(_ app: XCUIApplication, screen: String,
                                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let elements = try interactiveElements(in: app)
        XCTAssertFalse(elements.isEmpty, "\(screen): no interactive element found", file: file, line: line)
        var problems: [String] = []
        for element in elements where !Self.isSystemBackButton(element) {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let what = "\(element.elementType.rawValue) id='\(element.identifier)' label='\(element.label)'"
            if label.isEmpty {
                problems.append("empty label: \(what)")
            } else if Self.looksLikeIdentifier(label) {
                problems.append("identifier-like label: \(what)")
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(screen):\n" + problems.joined(separator: "\n"), file: file, line: line)
    }

    /// The navigation bar's back chevron is drawn by watchOS (`NavigationStack`), not by the app: it has the
    /// system identifier "BackButton" and, on the watchOS 11 simulator, an empty label in the UI-test tree. The app
    /// cannot set its label, so it is skipped; see docs/ACCESSIBILITY.md.
    static func isSystemBackButton(_ element: XCUIElementSnapshot) -> Bool {
        element.elementType == .button && element.identifier == "BackButton"
    }

    /// True for labels that are clearly not words for people: SF Symbol names ("list.bullet", "gearshape"),
    /// file names ("sample.epub"), identifiers ("libraryRow", "reader_block", "a/b") and hashes.
    /// The app's real labels are Title Case words ("Settings", "Text Size") or titles with spaces.
    static func looksLikeIdentifier(_ label: String) -> Bool {
        if label.rangeOfCharacter(from: .whitespaces) != nil { return false }
        let patterns = [
            #"^[0-9a-fA-F]{16,}$"#,                                   // document hash
            #"(?i)\.(epub|book|json|plist|png|jpe?g|pdf|x?html?)$"#,   // file name
            #"[_/\\]"#,                                                // snake_case, paths
            #"^[a-z][a-z0-9]*(\.[a-z0-9]+)+$"#,                        // SF Symbol name / dotted key
            #"^[a-z]+[A-Z][A-Za-z0-9]*$"#,                             // camelCase identifier
            #"^[a-z]{2,}$"#,                                           // bare lowercase token ("gearshape", "trash")
        ]
        return patterns.contains { label.range(of: $0, options: .regularExpression) != nil }
    }

    func testIdentifierHeuristic() {
        for bad in ["gearshape", "list.bullet", "sample.epub", "libraryRow", "reader_block", "00000000000000000000000000a11ce0"] {
            XCTAssertTrue(Self.looksLikeIdentifier(bad), bad)
        }
        for good in ["Settings", "Text Size", "Reading Options", "Alice’s Adventures in Wonderland, Lewis Carroll, 0% read", "+", "Back"] {
            XCTAssertFalse(Self.looksLikeIdentifier(good), good)
        }
    }

    // MARK: Library

    @MainActor
    func testLibraryEmptyState() throws {
        let app = WatchUI.launch()
        XCTAssertFalse(WatchUI.libraryRow(in: app).exists, "Library should start empty")
        let settings = WatchUI.element("settingsButton", in: app)
        XCTAssertTrue(settings.exists)
        XCTAssertEqual(settings.elementType, .button)
        XCTAssertEqual(settings.label, "Settings")
        try assertInteractiveElementsAreLabelled(app, screen: "Library (empty)")
    }

    @MainActor
    func testLibraryWithBook() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        let row = WatchUI.libraryRow(in: app)
        // A NavigationLink row: one actionable element whose label reads "title, author, n% read".
        XCTAssertTrue([.button, .cell].contains(row.elementType), "Row type: \(row.elementType.rawValue)")
        XCTAssertTrue(row.label.contains(WatchUI.sampleTitle), "Row label lacks the title: \(row.label)")
        XCTAssertTrue(row.label.contains("Lewis Carroll"), "Row label lacks the author: \(row.label)")
        XCTAssertTrue(row.label.contains("read"), "Row label lacks the progress: \(row.label)")
        try assertInteractiveElementsAreLabelled(app, screen: "Library (one book)")
    }

    // MARK: Reader

    @MainActor
    func testReaderAndReadingOptions() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        WatchUI.openReader(app)
        let heading = WatchUI.element("readerBlock", in: app)
        XCTAssertTrue(heading.label.contains(WatchUI.sampleChapter), "First block should be the chapter heading: \(heading.label)")
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertEqual(options.elementType, .button)
        XCTAssertEqual(options.label, "Reading Options")
        try assertInteractiveElementsAreLabelled(app, screen: "Reader")

        WatchUI.openReaderMenu(app)
        assertTextSizeStepper(in: app)
        try assertInteractiveElementsAreLabelled(app, screen: "Reading Options")
        let chapter = WatchUI.element("chapterButton", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(chapter, in: app), "Chapter button not reachable")
        XCTAssertTrue(chapter.label.contains(WatchUI.sampleChapter), "Chapter label: \(chapter.label)")
        XCTAssertTrue(chapter.isSelected, "The current chapter must carry the selected trait (the bookmark glyph is hidden)")
        try assertInteractiveElementsAreLabelled(app, screen: "Reading Options (chapters)")
    }

    // MARK: Settings

    @MainActor
    func testSettingsAndTypography() throws {
        let app = WatchUI.launch()
        WatchUI.openSettings(app)
        assertTextSizeStepper(in: app)
        try assertInteractiveElementsAreLabelled(app, screen: "Settings")

        WatchUI.openTypography(app)
        let preview = WatchUI.element("typographyPreview", in: app)
        XCTAssertEqual(preview.label, "Text preview")
        try assertInteractiveElementsAreLabelled(app, screen: "Typography")
    }

    /// "Text Size, 16 points": a labelled, adjustable control whose value is spoken in words.
    @MainActor
    private func assertTextSizeStepper(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let stepper = WatchUI.element("textSizeStepper", in: app)
        XCTAssertTrue(stepper.exists, "Text size stepper missing", file: file, line: line)
        XCTAssertEqual(stepper.label, "Text Size", file: file, line: line)
        let value = stepper.value as? String ?? ""
        XCTAssertTrue(value.hasSuffix("points"), "Stepper value should read 'n points', got '\(value)'", file: file, line: line)
    }

    // MARK: Largest accessibility text size (AX5)

    @MainActor
    func testPrimaryControlsAtAccessibilityXXXL_Library() throws {
        let app = WatchUI.launch(extraArguments: WatchUI.accessibilityXXXLArguments)
        XCTAssertTrue(WatchUI.emptyLibraryMessage(in: app).exists)
        XCTAssertTrue(WatchUI.element("settingsButton", in: app).isHittable, "Settings button not hittable at AX5")
        try assertInteractiveElementsAreLabelled(app, screen: "Library (empty, AX5)")
    }

    @MainActor
    func testPrimaryControlsAtAccessibilityXXXL_LibraryWithBook() throws {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: WatchUI.accessibilityXXXLArguments)
        XCTAssertTrue(WatchUI.libraryRow(in: app).isHittable, "Book row not hittable at AX5")
        XCTAssertTrue(WatchUI.element("settingsButton", in: app).isHittable, "Settings button not hittable at AX5")
        try assertInteractiveElementsAreLabelled(app, screen: "Library (one book, AX5)")
    }

    @MainActor
    func testPrimaryControlsAtAccessibilityXXXL_Reader() throws {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: WatchUI.accessibilityXXXLArguments)
        WatchUI.openReader(app)
        XCTAssertTrue(WatchUI.element("readerOptionsButton", in: app).isHittable, "Reading Options not hittable at AX5")
        WatchUI.openReaderMenu(app)
        let stepper = WatchUI.element("textSizeStepper", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(stepper, in: app), "Text size stepper not reachable at AX5")
        let chapter = WatchUI.element("chapterButton", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(chapter, in: app), "Chapter button not reachable at AX5")
    }

    @MainActor
    func testPrimaryControlsAtAccessibilityXXXL_Settings() throws {
        let app = WatchUI.launch(extraArguments: WatchUI.accessibilityXXXLArguments)
        WatchUI.openSettings(app)
        let stepper = WatchUI.element("textSizeStepper", in: app)
        XCTAssertTrue(WatchUI.scrollToHittable(stepper, in: app), "Text size stepper not reachable at AX5")
        try assertInteractiveElementsAreLabelled(app, screen: "Settings (AX5)")
    }
}
