import XCTest

/// Board Edit squares editor — gesture tests that snapshots cannot cover.
///
/// Launches a DEBUG build with `-bypassAuth YES -uiTestSeedEditBoard YES`,
/// which seeds a deterministic 3×3 board (`OYBC/Services/UITestSeed.swift`):
///
///     Alpha   Beta    Gamma
///     Delta   FREE    Epsilon
///     Zeta    Eta     Theta(locked)
///
/// and deep-links straight to it. Each test enters "Edit squares" and drives
/// the grid by its slot-positional ids (`squaresEditCell.<slot>`).
///
/// Automated xcodebuild runs only — explicitly authorized by the owner as a
/// narrow exception to CLAUDE.md's no-sim-driving rule (see §iOS testing).
final class SquaresEditGridUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-bypassAuth", "YES",
            "-uiTestSeedEditBoard", "YES",
            // Skip the first-run onboarding overlay (UserDefaults argument domain).
            "-oybc-onboarding-seen", "YES",
        ]
        app.launch()

        let edit = app.buttons["Edit squares"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "seeded board never opened")
        edit.tap()
        XCTAssertTrue(cell(0).waitForExistence(timeout: 10), "squares editor never appeared")
    }

    // MARK: - Helpers

    private func cell(_ slot: Int) -> XCUIElement {
        app.descendants(matching: .any)["squaresEditCell.\(slot)"]
    }

    private func label(_ slot: Int) -> String { cell(slot).label }

    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    private var noChangesLabel: XCUIElement { app.staticTexts["No changes"] }
    private var squareMenuButton: XCUIElement { app.buttons["Replace task…"] }

    /// Hold `from` long enough to lift, drag slowly onto `to`, pause, release.
    private func holdAndDrag(from: Int, to: Int) {
        center(of: cell(from)).press(
            forDuration: 0.8,
            thenDragTo: center(of: cell(to)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
    }

    private func waitForLabel(_ slot: Int, containing title: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", title)
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: cell(slot))],
            timeout: 5
        )
        XCTAssertEqual(result, .completed, "slot \(slot) never showed \(title); got '\(label(slot))'",
                       file: file, line: line)
    }

    private func assertOriginalOrder(file: StaticString = #filePath, line: UInt = #line) {
        let expected = ["Alpha", "Beta", "Gamma", "Delta", "FREE", "Epsilon", "Zeta", "Eta", "Theta"]
        for (slot, title) in expected.enumerated() {
            XCTAssertTrue(label(slot).contains(title),
                          "slot \(slot) expected \(title), got '\(label(slot))'", file: file, line: line)
        }
    }

    // MARK: - Tests

    /// Every square must sit at its own on-screen spot — for touches AND
    /// VoiceOver. (Root cause of the bug: all nine frames collapsed onto
    /// slot 0 because hit/a11y modifiers sat after `.offset`.)
    func testSquaresHaveDistinctFrames() {
        let frames = (0..<9).map { cell($0).frame }
        XCTAssertEqual(Set(frames.map { "\($0.minX),\($0.minY)" }).count, 9, "frames overlap: \(frames)")
        XCTAssertLessThan(frames[0].minX, frames[2].minX)
        XCTAssertLessThan(frames[0].minY, frames[6].minY)
    }

    /// The reported bug: press-and-hold then drag must move the square.
    func testHoldThenDragMovesSquare() {
        assertOriginalOrder()
        XCTAssertTrue(noChangesLabel.exists)

        holdAndDrag(from: 0, to: 2)

        waitForLabel(2, containing: "Alpha")
        XCTAssertTrue(label(0).contains("Beta"), "cascade: slot 0 should now be Beta, got '\(label(0))'")
        XCTAssertTrue(label(1).contains("Gamma"), "cascade: slot 1 should now be Gamma, got '\(label(1))'")
        XCTAssertFalse(noChangesLabel.exists, "edit counter should count the move")
    }

    /// A hold-drag into a lower row (vertical motion — the ScrollView's axis)
    /// still moves the square rather than scrolling.
    func testHoldThenDragVerticallyMovesSquare() {
        holdAndDrag(from: 1, to: 7)
        waitForLabel(7, containing: "Beta")
        XCTAssertFalse(noChangesLabel.exists)
    }

    /// A quick tap opens THAT square's menu (an unlocked square offers
    /// "Lock in place"). Before the fix a tap on the face was eaten by the
    /// face's own no-op tap gesture, and the only live hit region (slot 0)
    /// opened the LAST square's menu.
    func testTapOpensTheTappedSquaresMenu() {
        cell(5).tap()
        XCTAssertTrue(squareMenuButton.waitForExistence(timeout: 5), "square menu did not open")
        XCTAssertTrue(app.buttons["Lock in place"].exists, "menu is not the unlocked Epsilon's")
        XCTAssertFalse(app.buttons["Unlock"].exists)
    }

    /// Tapping the locked square opens its own (locked) menu.
    func testTapLockedSquareOpensItsMenu() {
        cell(8).tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 5), "locked square's menu did not open")
    }

    /// Hold-and-release without moving lifts and drops in place: no reorder
    /// and — critically — the trailing tap must NOT open the square menu.
    func testHoldAndReleaseInPlaceDoesNothing() {
        center(of: cell(3)).press(forDuration: 0.8)
        XCTAssertFalse(squareMenuButton.waitForExistence(timeout: 1.5), "hold-release opened the menu")
        assertOriginalOrder()
        XCTAssertTrue(noChangesLabel.exists)
    }

    /// A locked square never lifts, even with a full hold-and-drag.
    func testLockedSquareDoesNotMove() {
        holdAndDrag(from: 8, to: 6)
        // Give any (wrong) reorder a chance to land before asserting.
        _ = app.staticTexts["1 edit"].waitForExistence(timeout: 1.5)
        assertOriginalOrder()
        XCTAssertTrue(noChangesLabel.exists)
    }

    /// A quick swipe (no hold) is never a move — and it must not leave the
    /// grid stuck mid-drag: a subsequent hold-drag still works.
    func testQuickSwipeDoesNotMoveAndGridStaysLive() {
        center(of: cell(3)).press(forDuration: 0.01, thenDragTo: center(of: cell(0)),
                                  withVelocity: .fast, thenHoldForDuration: 0)
        _ = app.staticTexts["1 edit"].waitForExistence(timeout: 1.5)
        assertOriginalOrder()
        XCTAssertTrue(noChangesLabel.exists)

        holdAndDrag(from: 0, to: 1)
        waitForLabel(1, containing: "Alpha")
    }
}
