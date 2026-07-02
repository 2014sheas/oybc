import XCTest
@testable import OYBC

/// Regression tests for `BoardWizardViewModel.updateSize` center-square
/// coercion.
///
/// The bug: `updateSize` coerced a NONE center to FREE whenever the new
/// size was odd AND the current center was NONE — but it fired on *every*
/// odd-size selection, not just the even→odd crossing. So a user who
/// deliberately picked "None" on an odd board, then re-touched the size
/// card (even re-selecting the same size) while paging back and forth in
/// the wizard, silently got a FREE center on the created board.
///
/// The fix only coerces NONE→FREE when actually crossing from an even
/// board (which forces NONE) to an odd one. These tests pin that contract.
final class BoardWizardCenterSquareTests: XCTestCase {

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: UserPreferences.defaults)
    }

    /// Re-selecting the same — or another — ODD size must preserve a
    /// deliberate NONE center. This is the exact regression the user hit.
    func testOddToOddReselectPreservesNoneCenter() {
        let vm = makeVM()
        vm.updateSize(5)            // odd
        vm.updateCenterType(.none)  // user deliberately chooses "None"
        XCTAssertEqual(vm.centerType, .none)

        vm.updateSize(5)            // re-tap the SAME odd size
        XCTAssertEqual(
            vm.centerType, .none,
            "Re-tapping the same odd size must not revert None→Free"
        )

        vm.updateSize(3)            // switch to ANOTHER odd size
        XCTAssertEqual(
            vm.centerType, .none,
            "Switching odd→odd must not revert None→Free"
        )
    }

    /// Crossing EVEN→ODD should give the (otherwise hidden) center a
    /// visible FREE default, since the even board had forced NONE.
    func testEvenToOddCoercesNoneToFree() {
        let vm = makeVM()
        vm.updateSize(4)            // even forces NONE
        XCTAssertEqual(vm.centerType, .none)

        vm.updateSize(5)            // even→odd crossing
        XCTAssertEqual(
            vm.centerType, .free,
            "Crossing even→odd should default a forced None to Free"
        )
    }

    /// A non-NONE odd center is preserved across an odd→odd size change.
    func testOddToOddPreservesChosenCenter() {
        let vm = makeVM()
        vm.updateSize(5)
        vm.updateCenterType(.chosen)
        vm.setCenterTaskId("task-123")

        vm.updateSize(3)            // odd→odd
        XCTAssertEqual(vm.centerType, .chosen)
        XCTAssertEqual(vm.centerTaskId, "task-123")
    }

    /// Switching to an EVEN size always forces NONE and clears any chosen
    /// center task (even boards have no center concept).
    func testEvenForcesNoneAndClearsChosenTask() {
        let vm = makeVM()
        vm.updateSize(5)
        vm.updateCenterType(.chosen)
        vm.setCenterTaskId("task-123")

        vm.updateSize(4)            // even
        XCTAssertEqual(vm.centerType, .none)
        XCTAssertNil(
            vm.centerTaskId,
            "Even boards have no center; chosen task id must clear"
        )
    }

    // MARK: - Persisted BoardTask.isCenter (bugfix/ios-wizard-draft-leakage)
    //
    // The bug: `persistWizardBoard` set `isCenter` for `.none` centers too,
    // so the play grid rendered a gold "FREE" cell over a real task (the
    // preview never did — it gates on `centerType != .none`). These pin the
    // shared `makeWizardBoardTaskRows` helper both the wizard and recurring
    // spawn use.

    private func t(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: "T\(id)", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-07-01T12:00:00.000", updatedAt: "2026-07-01T12:00:00.000",
            version: 1, isDeleted: false, createdInWizard: false
        )
    }

    /// 3×3 placement with a real task in every cell (center = index 4).
    private func full3x3() -> WizardPlacement { (0..<9).map { i -> OYBC.Task? in t("t\(i)") } }

    func testPersistedCenterFlaggedOnlyForChosen() {
        let now = "2026-07-01T12:00:00.000"

        let chosen = makeWizardBoardTaskRows(placement: full3x3(), boardId: "b", size: 3, centerType: .chosen, now: now)
        XCTAssertEqual(chosen.count, 9)
        XCTAssertTrue(chosen.first { $0.row == 1 && $0.col == 1 }!.isCenter,
                      "A CHOSEN center task must be flagged isCenter")
        XCTAssertEqual(chosen.filter { $0.isCenter }.count, 1)

        let none = makeWizardBoardTaskRows(placement: full3x3(), boardId: "b", size: 3, centerType: .none, now: now)
        XCTAssertFalse(none.first { $0.row == 1 && $0.col == 1 }!.isCenter,
                       "A NONE center holds an ordinary task and must NOT be isCenter (was rendering a FREE cell)")
        XCTAssertEqual(none.filter { $0.isCenter }.count, 0)
    }

    func testPersistedFreeCenterHasNoRow() {
        // FREE / CUSTOM_FREE reserve the center as a nil slot → no BoardTask row,
        // and nothing is flagged isCenter (the play grid renders FREE positionally).
        var p = full3x3()
        p[4] = nil
        let rows = makeWizardBoardTaskRows(placement: p, boardId: "b", size: 3, centerType: .free, now: "n")
        XCTAssertEqual(rows.count, 8)
        XCTAssertFalse(rows.contains { $0.row == 1 && $0.col == 1 }, "No row at the reserved FREE center")
        XCTAssertEqual(rows.filter { $0.isCenter }.count, 0)
    }
}
