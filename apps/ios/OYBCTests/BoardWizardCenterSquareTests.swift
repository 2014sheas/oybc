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
}
