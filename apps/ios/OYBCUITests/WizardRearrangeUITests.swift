import XCTest

/// Board wizard Step 3 (Preview) → "Rearrange" — gesture/hit-area tests that
/// snapshots cannot cover.
///
/// Launches a DEBUG build with `-bypassAuth YES -uiTestSeedWizardPreview YES`,
/// which seeds a fully-placed one-off DRAFT 3×3 board
/// (`OYBC/Services/UITestSeed.swift`) and deep-links to it. The draft guard's
/// "Resume draft" button opens the wizard, which resumes on Preview. Each test
/// drives `RearrangeGrid` by its slot-positional ids (`rearrangeCell.<slot>`);
/// the FREE center (slot 4) is pinned.
///
/// Automated xcodebuild runs only — the owner's narrow exception to
/// CLAUDE.md's no-sim-driving rule (see §iOS verification).
final class WizardRearrangeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Every movable slot (all but the FREE center).
    private let movableSlots = [0, 1, 2, 3, 5, 6, 7, 8]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-bypassAuth", "YES",
            "-uiTestSeedWizardPreview", "YES",
            // Skip the first-run onboarding overlay (UserDefaults argument domain).
            "-oybc-onboarding-seen", "YES",
        ]
        app.launch()

        let resume = app.buttons["Resume draft"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "seeded draft never opened")
        resume.tap()
        XCTAssertTrue(cell(0).waitForExistence(timeout: 10), "wizard Preview grid never appeared")
    }

    // MARK: - Helpers

    private func cell(_ slot: Int) -> XCUIElement {
        app.descendants(matching: .any)["rearrangeCell.\(slot)"]
    }

    /// The task title shown at `slot` (the face's a11y label starts with it).
    private func title(_ slot: Int) -> String {
        let label = cell(slot).label
        return label.components(separatedBy: ",").first ?? label
    }

    private func order() -> [String] { movableSlots.map(title) }

    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// Taps the segment labelled `label` in the Preview ⇄ Rearrange toggle.
    private func selectMode(_ label: String) {
        let segment = app.buttons[label]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "\(label) segment missing")
        segment.tap()
    }

    private func enterRearrange() {
        selectMode("Rearrange")
        XCTAssertTrue(app.staticTexts["Drag to rearrange · tap two squares to swap"]
            .waitForExistence(timeout: 5), "Rearrange hint never appeared")
    }

    private func waitForTitle(_ slot: Int, _ expected: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", expected)
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: cell(slot))],
            timeout: 5
        )
        XCTAssertEqual(result, .completed, "slot \(slot) never showed \(expected); got '\(title(slot))'",
                       file: file, line: line)
    }

    // MARK: - Tests

    /// (c) Every square's on-screen frame sits at its own slot — not stacked.
    func testSquaresHaveDistinctFrames() {
        enterRearrange()
        let frames = (0..<9).map { cell($0).frame }
        let origins = Set(frames.map { "\(Int($0.midX.rounded())),\(Int($0.midY.rounded()))" })
        XCTAssertEqual(origins.count, 9, "frames overlap: \(frames)")
        XCTAssertLessThan(frames[0].midX, frames[2].midX)
        XCTAssertLessThan(frames[0].midY, frames[6].midY)
    }

    /// (a) Tap one square, then another → they swap.
    func testTapTwoSquaresSwapsThem() {
        enterRearrange()
        let before = order()
        let a = title(0), c = title(2)
        XCTAssertNotEqual(a, c)

        center(of: cell(0)).tap()
        center(of: cell(2)).tap()

        waitForTitle(0, c)
        waitForTitle(2, a)
        XCTAssertEqual(title(1), before[1], "the untouched middle square must stay put")
    }

    /// (a') Tap-to-swap on squares away from the top-left slot (lower rows) —
    /// catches hit regions that all stack on slot 0.
    func testTapSwapInLowerRows() {
        enterRearrange()
        let d = title(3), i = title(8)

        center(of: cell(3)).tap()
        center(of: cell(8)).tap()

        waitForTitle(3, i)
        waitForTitle(8, d)
    }

    /// (b) Drag a square onto another slot → it moves there (cascade).
    func testDragMovesSquare() {
        enterRearrange()
        let a = title(0), b = title(1)

        center(of: cell(0)).press(
            forDuration: 0.1,
            thenDragTo: center(of: cell(2)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )

        waitForTitle(2, a)
        XCTAssertTrue(title(0).hasPrefix(b), "cascade: slot 0 should now be \(b), got '\(title(0))'")
    }

    /// (b') Drag starting from a lower-row square into the top row.
    func testDragFromLowerRowMovesSquare() {
        enterRearrange()
        let moving = title(7)

        center(of: cell(7)).press(
            forDuration: 0.1,
            thenDragTo: center(of: cell(1)),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )

        waitForTitle(1, moving)
    }

    /// (d) The Preview ⇄ Rearrange toggle still works, and Preview is inert:
    /// taps there never swap.
    func testPreviewRearrangeToggle() {
        let before = order()
        let hint = app.staticTexts["Drag to rearrange · tap two squares to swap"]
        XCTAssertFalse(hint.exists, "hint must be hidden in Preview")

        // Preview is display-only.
        center(of: cell(0)).tap()
        center(of: cell(2)).tap()
        XCTAssertEqual(order(), before, "Preview must not rearrange")

        enterRearrange()
        selectMode("Preview")
        let gone = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hint)],
            timeout: 5
        )
        XCTAssertEqual(gone, .completed, "hint must hide again after returning to Preview")

        // Back into Rearrange: the grid is live again.
        enterRearrange()
        let a = title(0), c = title(2)
        center(of: cell(0)).tap()
        center(of: cell(2)).tap()
        waitForTitle(0, c)
        waitForTitle(2, a)
    }
}
