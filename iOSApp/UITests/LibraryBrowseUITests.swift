import XCTest

/// Search, sort and browse in the Library (#114) with eight seeded books (`-UITestingSeedLargeLibrary`, Debug
/// builds only): three of Barsoom (books 1 to 3), two by Jane Austen, titles with accents. The sort order and
/// browse mode live in throw-away defaults in UI-testing launches, so every launch starts at *Recently Read*,
/// *All Books*. Every state is attached as a screenshot (macos.yml exports them with the other UI suites).
///
/// The search field is in the page, not `.searchable` (docs/OPDS.md, PR #193): the tests open a book from the
/// results and check that the Library comes back with its navigation bar, its field, the search and the results.
final class LibraryBrowseUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Launch, typing and a push and back; well under the 180 s per-test allowance of CI.
        executionTimeAllowance = 170
    }

    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedLargeLibrary", "-UITestingSkipOnboarding"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'librarySectionHeader' AND label == %@", text)).firstMatch
    }

    /// Types `text` into the search field and waits for `expected` to be listed.
    @MainActor
    private func search(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["librarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search field missing")
        RowNavigation.reveal(field, in: app)
        field.tap()
        field.typeText(text)
        return field
    }

    /// Picks `option` in the Sort and Browse menu.
    @MainActor
    private func choose(_ option: String, in app: XCUIApplication) {
        let menu = app.buttons["librarySortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Sort and Browse menu missing")
        menu.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(option) missing from the menu")
        item.tap()
    }

    /// Search ignores case and accents and matches the author and series; opening a result and coming back keeps
    /// the navigation bar, the field, the search and the results.
    @MainActor
    func testSearchThenOpenABookAndComeBack() throws {
        let app = launch()
        let field = search("MISERABLES", in: app)
        let hugo = row(app, "Les Misérables")
        XCTAssertTrue(hugo.waitForExistence(timeout: 5), "accent-insensitive search found nothing")
        XCTAssertFalse(row(app, "Emma").exists, "a book that does not match is still listed")
        screenshot(app, "library-search-1-results")

        RowNavigation.open(hugo, in: app, expecting: app.descendants(matching: .any)["bookDetail"])
        XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5), "Book details did not open")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "Library came back without its navigation bar")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Library came back without its search field")
        XCTAssertEqual(field.value as? String, "MISERABLES", "the search was lost")
        XCTAssertTrue(row(app, "Les Misérables").exists, "the results were lost")
        XCTAssertFalse(row(app, "Emma").exists, "the search no longer filters")
        screenshot(app, "library-search-2-back-from-book")

        // Author and series names match too; the clear button brings every book back.
        app.buttons["librarySearchClear"].tap()
        field.tap()
        field.typeText("barsoom\n")
        XCTAssertTrue(row(app, "A Princess of Mars").waitForExistence(timeout: 5), "series name did not match")
        XCTAssertFalse(row(app, "Persuasion").exists)
        app.buttons["librarySearchClear"].tap()
        XCTAssertTrue(row(app, "Persuasion").waitForExistence(timeout: 5) || row(app, "Emma").exists,
                      "clearing the search did not bring the books back")
    }

    /// The same round trip at the largest text size, where the field and the rows are far taller: the "No Apple
    /// Watch" notice under the field fills the screen and the results start below it, and List rows below the
    /// screen are not in the accessibility tree, so each check scrolls to what it looks for.
    @MainActor
    func testSearchRoundTripAtLargestTextSize() throws {
        let app = launch(Self.largestText)
        let field = search("verne\n", in: app)
        let verne = row(app, "Vingt mille")
        RowNavigation.reveal(verne, in: app)
        XCTAssertTrue(verne.waitForExistence(timeout: 5), "author search found nothing")
        XCTAssertFalse(row(app, "Emma").exists, "a book that does not match is still listed")
        screenshot(app, "library-search-3-ax5")
        RowNavigation.open(verne, in: app, expecting: app.descendants(matching: .any)["bookDetail"])
        XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5), "Book details did not open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "Library came back without its navigation bar")
        // The results are where they were left.
        RowNavigation.reveal(row(app, "Vingt mille"), in: app)
        XCTAssertTrue(row(app, "Vingt mille").waitForExistence(timeout: 5), "the results were lost")
        // The field is the first row of the list: back to the top (a tap on the status bar).
        scrollToTop(app, until: field)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Library came back without its search field")
        XCTAssertEqual(field.value as? String, "verne", "the search was lost")
        screenshot(app, "library-search-3b-ax5-back-at-top")
    }

    /// Scrolls the list to its top with a tap on the status bar until `element` is in the tree, then waits for
    /// it to settle. Slow, held drags downwards as a fallback (no fling past the top).
    @MainActor
    private func scrollToTop(_ app: XCUIApplication, until element: XCUIElement) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.width * 0.2, dy: 20)).tap()
        RowNavigation.waitForSettle(app)
        for _ in 0..<10 where !element.exists {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.35))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            RowNavigation.waitForSettle(app)
        }
    }

    @MainActor
    func testSearchWithNoResults() throws {
        let app = launch()
        _ = search("zzzz\n", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["libraryNoResults"].waitForExistence(timeout: 5), "No Results missing")
        XCTAssertFalse(app.descendants(matching: .any)["libraryRow"].exists)
        screenshot(app, "library-search-4-no-results")
    }

    /// *Title* sorts A to Z; *Recently Added* puts the last seeded book first.
    @MainActor
    func testSortOrders() throws {
        let app = launch()
        choose("Title", in: app)
        let first = app.descendants(matching: .any).matching(identifier: "libraryRow").element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // "A Princess of Mars" and "Alice’s Adventures in Wonderland" come first (in the locale's order).
        XCTAssertTrue(first.label.hasPrefix("A"), "Title order should start with a title in A: \(first.label)")
        XCTAssertFalse(first.label.hasPrefix("Vingt mille"), "the last title should not be at the top")
        XCTAssertEqual(app.buttons["librarySortMenu"].value as? String, "Title, All Books")
        screenshot(app, "library-sort-1-title")
        choose("Recently Added", in: app)
        let newest = app.descendants(matching: .any).matching(identifier: "libraryRow").element(boundBy: 0)
        XCTAssertTrue(newest.label.hasPrefix("Vingt mille"), "the last seeded book should be first: \(newest.label)")
    }

    /// *By Series*: a section per series, the books in series order, then the books in no series.
    @MainActor
    func testBrowseBySeries() throws {
        let app = launch()
        choose("By Series", in: app)
        let barsoom = header(app, "Barsoom")
        XCTAssertTrue(barsoom.waitForExistence(timeout: 5), "Barsoom section missing")
        let one = row(app, "A Princess of Mars"), two = row(app, "The Gods of Mars"), three = row(app, "The Warlord of Mars")
        XCTAssertTrue(one.exists && two.exists && three.exists, "Barsoom books missing")
        XCTAssertLessThan(one.frame.minY, two.frame.minY)
        XCTAssertLessThan(two.frame.minY, three.frame.minY)
        screenshot(app, "library-browse-1-series")
        RowNavigation.reveal(header(app, "Not in a Series"), in: app)
        XCTAssertTrue(header(app, "Not in a Series").exists, "Not in a Series section missing")
    }

    /// *By Author* with a search: the sections hold only the matching books.
    @MainActor
    func testBrowseByAuthorWithSearch() throws {
        let app = launch()
        choose("By Author", in: app)
        XCTAssertTrue(header(app, "Edgar Rice Burroughs").waitForExistence(timeout: 5), "author section missing")
        screenshot(app, "library-browse-2-authors")
        _ = search("austen\n", in: app)
        XCTAssertTrue(header(app, "Jane Austen").waitForExistence(timeout: 5), "Jane Austen section missing")
        XCTAssertFalse(header(app, "Edgar Rice Burroughs").exists, "a section without matches is still listed")
        XCTAssertTrue(row(app, "Emma").exists && row(app, "Persuasion").exists)
        XCTAssertEqual(app.buttons["librarySortMenu"].value as? String, "Recently Read, By Author")
        screenshot(app, "library-browse-3-authors-search")
    }

    // MARK: Collections (#164)

    /// Waits for `element`, then scrolls it into the clear part of the screen.
    @MainActor
    private func reveal(_ element: XCUIElement, _ message: String, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), message)
        RowNavigation.reveal(element, in: app)
    }

    /// Waits until `element` is selected (or not).
    @MainActor
    private func waitForSelection(_ element: XCUIElement, _ selected: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    /// The whole life of a collection: created from the empty *By Collection*, a book added from its details,
    /// browsed, the book opened from the collection and back, then the collection deleted (after a confirmation
    /// that says the books are kept): the book is still in the Library.
    @MainActor
    func testCollectionLifecycle() throws {
        let app = launch(["-library.browse", "collections"])
        let new = app.buttons["collectionsNew"]
        reveal(new, "By Collection should explain collections and offer New Collection", in: app)
        screenshot(app, "library-collections-1-empty")
        new.tap()

        let field = app.textFields["collectionNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "collection name field missing")
        field.tap()
        field.typeText("Holiday Reading")
        screenshot(app, "library-collections-2-new")
        app.buttons["collectionNameSave"].tap()
        XCTAssertTrue(app.buttons["libraryManageCollections"].waitForExistence(timeout: 5), "collection was not created")

        // Add Emma from its details.
        let bookDetail = app.descendants(matching: .any)["bookDetail"]
        let emma = row(app, "Emma")
        reveal(emma, "Emma missing", in: app)
        RowNavigation.open(emma, in: app, expecting: bookDetail)
        XCTAssertTrue(bookDetail.waitForExistence(timeout: 5), "Book details did not open")
        let add = app.buttons["bookDetailAddToCollection"]
        reveal(add, "Add to Collection missing from the book details", in: app)
        add.tap()
        let choice = app.buttons.matching(NSPredicate(format: "identifier == 'collectionPickerRow' AND label == 'Holiday Reading'")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the new collection is not offered")
        XCTAssertTrue(waitForSelection(choice, false), "Emma should not be in the collection yet")
        choice.tap()
        XCTAssertTrue(waitForSelection(choice, true), "the collection is not marked as holding the book")
        screenshot(app, "library-collections-3-picker")
        app.buttons["collectionPickerDone"].tap()
        let listed = app.staticTexts.matching(NSPredicate(format: "identifier == 'bookDetailCollection' AND label == 'Holiday Reading'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 5), "the book details do not list the collection")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Browse by collection: the collection's section holds Emma.
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "Library did not come back")
        let section = header(app, "Holiday Reading")
        reveal(section, "the collection's section is missing", in: app)
        XCTAssertEqual(app.buttons["librarySortMenu"].value as? String, "Recently Read, By Collection")
        let inCollection = row(app, "Emma")
        reveal(inCollection, "Emma is not in the collection's section", in: app)
        XCTAssertLessThan(section.frame.minY, inCollection.frame.minY)
        screenshot(app, "library-collections-4-browse")

        // Open the book from the collection and come back.
        RowNavigation.open(inCollection, in: app, expecting: bookDetail)
        XCTAssertTrue(bookDetail.waitForExistence(timeout: 5), "Book details did not open from the collection")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "Library came back without its navigation bar")
        reveal(header(app, "Holiday Reading"), "the collection's section was lost", in: app)

        // Delete the collection: the confirmation says the books are kept, and Emma is still there.
        let manage = app.buttons["libraryManageCollections"]
        reveal(manage, "Manage Collections missing", in: app)
        manage.tap()
        let collectionRow = app.buttons.matching(identifier: "collectionRow").firstMatch
        XCTAssertTrue(collectionRow.waitForExistence(timeout: 5), "Collections screen does not list the collection")
        screenshot(app, "library-collections-5-manage")
        collectionRow.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "swipe to delete missing")
        swipeDelete.tap()
        let confirm = app.buttons["Delete Collection"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting a collection is not confirmed")
        XCTAssertTrue(app.staticTexts["Only the collection is deleted. Its books stay in your Library and in any other collections."].exists,
                      "the confirmation does not say that the books are kept")
        screenshot(app, "library-collections-6-confirm-delete")
        confirm.tap()
        XCTAssertTrue(app.buttons["collectionsNew"].waitForExistence(timeout: 5), "the collection was not deleted")
        XCTAssertFalse(collectionRow.exists, "the collection is still listed")
        app.buttons["collectionsDone"].tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertFalse(header(app, "Holiday Reading").exists, "the deleted collection is still listed")
        let kept = row(app, "Emma")
        reveal(kept, "deleting the collection deleted its book", in: app)
        screenshot(app, "library-collections-7-deleted")
    }

    /// Two seeded collections (`-UITestingSeedCollections`): sections in the user's order, a book in both is in
    /// both; then *Add Books to a Collection* adds two books at once.
    @MainActor
    func testBrowseByCollectionAndAddSeveralBooks() throws {
        let app = launch(["-UITestingSeedCollections", "-library.browse", "collections"])
        let toRead = header(app, "To Read")
        reveal(toRead, "To Read section missing", in: app)
        screenshot(app, "library-collections-8-seeded")
        let select = app.buttons["librarySelectForCollection"]
        reveal(select, "Add Books to a Collection missing", in: app)
        select.tap()

        for title in ["Persuasion", "Les Misérables"] {
            let book = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'collectionSelectRow' AND label BEGINSWITH %@", title)).firstMatch
            reveal(book, "\(title) is not offered", in: app)
            book.tap()
        }
        screenshot(app, "library-collections-9-select")
        let addButton = app.buttons["collectionSelectAdd"]
        XCTAssertTrue(addButton.isEnabled, "Add to Collection stays disabled with two books chosen")
        addButton.tap()
        let club = app.buttons.matching(NSPredicate(format: "identifier == 'collectionPickerRow' AND label == 'Book Club'")).firstMatch
        XCTAssertTrue(club.waitForExistence(timeout: 5), "Book Club is not offered")
        club.tap()
        XCTAssertTrue(waitForSelection(club, true), "the books were not added")
        app.buttons["collectionPickerDone"].tap()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "the selection screen did not close")
        let bookClub = header(app, "Book Club")
        reveal(bookClub, "Book Club section missing", in: app)
        let persuasion = row(app, "Persuasion")
        reveal(persuasion, "Persuasion is not listed", in: app)
        XCTAssertLessThan(bookClub.frame.minY, persuasion.frame.minY, "Persuasion should be in Book Club")
        screenshot(app, "library-collections-10-added")
    }
}
