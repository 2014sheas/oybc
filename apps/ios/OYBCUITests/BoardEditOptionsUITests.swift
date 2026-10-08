import XCTest

/// Board Edit consolidation — device-independent coverage for the Edit
/// screen's BOARD section (rows sourced from `BoardMenuItems`) and for the
/// squares-hidden variant on a CLOSED board.
///
/// Automated xcodebuild runs only, matching `SquaresEditGridUITests`'s
/// owner-authorized exception to CLAUDE.md's no-sim-driving rule.
final class BoardEditOptionsUITests: XCTestCase {

    // MARK: - Active board: BOARD section rows present alongside SQUARES

    /// `-uiTestSeedEditBoard` seeds an active, unsealed, far-future ad-hoc
    /// board (`UITestSeed.seedIfRequested`) — SQUARES stays editable and the
    /// BOARD section renders the live-ad-hoc row set (Board details… ·
    /// Repeat this board… · Archive · Delete, per `BoardMenuItems.items`).
    func testActiveBoard_editShowsSquaresAndBoardSectionRows() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-bypassAuth", "YES",
            "-uiTestSeedEditBoard", "YES",
            "-oybc-onboarding-seen", "YES",
        ]
        app.launch()

        let edit = app.buttons["Edit board"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "seeded board never opened")
        edit.tap()

        // SQUARES still renders (this board is fully editable).
        let firstCell = app.descendants(matching: .any)["squaresEditCell.0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10), "squares grid should render for an editable board")

        // BOARD section header + every expected row.
        XCTAssertTrue(app.staticTexts["BOARD"].waitForExistence(timeout: 5), "BOARD section header missing")
        XCTAssertTrue(app.buttons["Board details…"].exists)
        XCTAssertTrue(app.buttons["Repeat this board…"].exists)
        XCTAssertTrue(app.buttons["Archive"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)

        // The retired "…" popover trigger must be gone.
        XCTAssertFalse(app.buttons["Board menu"].exists, "the retired '…' menu button should no longer exist")
    }

    // MARK: - Closed board: SQUARES hidden, Reopen works

    /// `-uiTestSeedEditBoardClosed` seeds a sealed, ended, ad-hoc board
    /// (`UITestSeed.seedClosedIfRequested`) — SQUARES is hidden behind the
    /// D4 reason line, the top-left control reads "Done", and the BOARD
    /// section leads with Reopen. Tapping Reopen → confirm → exits Edit back
    /// to the play surface, whose pill flips CLOSED → ENDED.
    func testClosedBoard_squaresHiddenAndReopenWorks() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-bypassAuth", "YES",
            "-uiTestSeedEditBoardClosed", "YES",
            "-oybc-onboarding-seen", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["CLOSED"].waitForExistence(timeout: 20), "seeded closed board never opened")

        let edit = app.buttons["Edit board"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit should still be offered on a closed board (D2)")
        edit.tap()

        // D4 — no grid on a closed board.
        let firstCell = app.descendants(matching: .any)["squaresEditCell.0"]
        XCTAssertFalse(firstCell.waitForExistence(timeout: 3), "squares grid must be hidden on a closed board")
        XCTAssertTrue(app.buttons["Reopen board"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No changes"].exists, "no save bar on the squares-locked variant")
        XCTAssertTrue(app.buttons["Done editing"].exists, "top-left control should read Done, not Cancel")

        // BOARD section leads with Reopen (D12 — closed, ad-hoc).
        let reopenRow = app.buttons["Reopen board"]
        XCTAssertTrue(reopenRow.waitForExistence(timeout: 5))
        reopenRow.tap()

        let confirmReopen = app.alerts["Reopen this board?"].buttons["Reopen"]
        XCTAssertTrue(confirmReopen.waitForExistence(timeout: 5))
        confirmReopen.tap()

        // D9 — success exits Edit back to the play surface; the pill flip
        // (CLOSED → ENDED, its window is still in the past) is the feedback.
        XCTAssertTrue(app.staticTexts["ENDED"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Edit board"].waitForExistence(timeout: 5), "should be back on the play surface")
    }
}
