import XCTest
@testable import OYBC

/// `BoardWizardViewModel.setRepeats(_:)` — Task Pools + Recurring Boards
/// Rework, P4. The Step-1 "Repeats" segmented control (`nil` = Once, a
/// `Timeframe` = the repeat cadence) is now the ONLY way to enter/leave
/// recurring mode inside the wizard (the separate "Create a recurring
/// board" CTA / `startRecurring` init flag retired). This sets
/// `isRecurring` and `timeframe` together, remembers the prior one-off
/// timeframe across a round trip through recurring mode, and coerces a
/// CHOSEN center away (recurring boards can't use CHOSEN — the center
/// picker itself suppresses the option, but a stale mark from before a
/// cadence was picked must still be cleared).
final class BoardWizardRepeatsTests: XCTestCase {

    // MARK: - Once → cadence

    func testSetRepeats_OnceToCadence_SetsRecurringAndTimeframeTogether() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        XCTAssertFalse(vm.isRecurring)
        XCTAssertNil(vm.repeatsValue)

        vm.setRepeats(.daily)

        XCTAssertTrue(vm.isRecurring)
        XCTAssertEqual(vm.timeframe, .daily)
        XCTAssertEqual(vm.repeatsValue, .daily)
    }

    func testSetRepeats_OnceToCadence_CoercesChosenCenterAway() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        vm.size = 5 // odd, so CHOSEN is a legal one-off selection
        vm.updateCenterType(.chosen)
        vm.setCenterTaskId("some-task-id")
        XCTAssertEqual(vm.centerType, .chosen)

        vm.setRepeats(.weekly)

        XCTAssertEqual(vm.centerType, .free)
        XCTAssertNil(vm.centerTaskId)
    }

    // MARK: - Cadence → Once restores the prior one-off timeframe

    func testSetRepeats_CadenceToOnce_RestoresPriorOneOffTimeframe() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        vm.timeframe = .weekly // the one-off timeframe the user had picked

        vm.setRepeats(.daily)
        XCTAssertEqual(vm.timeframe, .daily, "cadence takes over the timeframe field")

        vm.setRepeats(nil)

        XCTAssertFalse(vm.isRecurring)
        XCTAssertNil(vm.repeatsValue)
        XCTAssertEqual(vm.timeframe, .weekly, "restores the one-off value captured before entering recurring mode")
    }

    func testSetRepeats_CadenceToCadence_DoesNotClobberRememberedOneOffValue() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        vm.timeframe = .monthly

        vm.setRepeats(.daily)   // captures .monthly as the one-off fallback
        vm.setRepeats(.weekly)  // cadence-to-cadence — must NOT recapture .daily
        vm.setRepeats(nil)

        XCTAssertEqual(vm.timeframe, .monthly)
    }

    func testSetRepeats_CadenceToOnce_CoercesCustomToIndefinite() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        vm.timeframe = .custom // a repeating board can't use CUSTOM

        vm.setRepeats(.monthly)
        vm.setRepeats(nil)

        XCTAssertEqual(vm.timeframe, .indefinite, "CUSTOM is coerced to INDEFINITE when captured")
    }

    // MARK: - Fresh VM: setRepeats(nil) before any cadence was ever picked

    /// A wizard that starts in recurring mode (editing an existing
    /// template) and is flipped straight back to Once — WITHOUT ever
    /// having been in Once first — must not crash, and must land on a
    /// sane non-CUSTOM timeframe (the `lastOneOffTimeframe` init seed).
    func testSetRepeats_FreshRecurringVM_ToOnce_DoesNotCrash_LandsOnSaneTimeframe() {
        let tpl = RecurringBoardTemplate(
            id: "tpl-1", userId: "u1", name: "Weekly Reset",
            timeframe: .weekly, boardSize: 5, centerSquareType: .free,
            isRandomized: true,
            seedTaskIds: (0..<24).map { "t\($0)" },
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl)
        XCTAssertTrue(vm.isRecurring, "editing a template starts in recurring mode")

        // The very first call is setRepeats(nil) — never preceded by a
        // setRepeats(cadence) call, so `lastOneOffTimeframe` is still at
        // its init-seeded value.
        vm.setRepeats(nil)

        XCTAssertFalse(vm.isRecurring)
        XCTAssertNil(vm.repeatsValue)
        XCTAssertNotEqual(vm.timeframe, .custom, "must land on a form-valid timeframe, not raw CUSTOM")
    }

    /// A plain fresh (non-recurring) VM's `lastOneOffTimeframe` seed is
    /// exercised the same way, as a baseline sanity check alongside the
    /// recurring-entry case above.
    func testSetRepeats_FreshOneOffVM_SetRepeatsNil_IsSafeNoOp() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        XCTAssertFalse(vm.isRecurring)

        vm.setRepeats(nil)

        XCTAssertFalse(vm.isRecurring)
        XCTAssertNotEqual(vm.timeframe, .custom)
    }
}
