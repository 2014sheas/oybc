import XCTest
@testable import OYBC

/// Template-edit hydration: entering the board wizard with an
/// `editingTemplate` seeds the wizard from that template (name, board
/// size, timeframe, center, selected task ids) and records the template
/// id so completion updates the template rather than creating a board.
///
/// iOS twin of web's `useBoardWizard` editTemplate branch — this is the
/// destination the Profile "Recurring templates" card tap routes to
/// (via `CreateHubViewModel.loadTemplateAndEnterWizard`). Guarding it
/// here proves the seam hydrates before the wizard mounts.
final class BoardWizardTemplateEditTests: XCTestCase {

    private func makeTemplate(
        id: String = "tpl-1",
        name: String = "Weekly Reset",
        timeframe: Timeframe = .weekly,
        boardSize: Int = 5,
        centerSquareType: CenterSquareType = .free,
        seedTaskIds: [String]? = nil,
        poolIds: [String]? = nil,
        manualTaskIds: [String]? = nil,
        removedTaskIds: [String]? = nil
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: "u1",
            name: name,
            timeframe: timeframe,
            boardSize: boardSize,
            centerSquareType: centerSquareType,
            isRandomized: true,
            seedTaskIds: seedTaskIds ?? (0..<24).map { "task-\($0)" },
            poolIds: poolIds,
            manualTaskIds: manualTaskIds,
            removedTaskIds: removedTaskIds,
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    func testHydratesFromTemplate_NameTimeframeSizeSelection() {
        let tpl = makeTemplate(seedTaskIds: ["a", "b", "c"])
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl)

        XCTAssertEqual(vm.name, "Weekly Reset")
        XCTAssertEqual(vm.timeframe, .weekly)
        XCTAssertEqual(vm.size, 5)
        XCTAssertEqual(vm.centerType, .free)
        XCTAssertEqual(vm.selectedTaskIds, Set(["a", "b", "c"]))
        XCTAssertEqual(vm.editingTemplateId, tpl.id)
        XCTAssertTrue(vm.isRecurring, "editing a template enters recurring mode")
    }

    func testHydratesFromTemplate_MonthlyBoardSizeThree() {
        let tpl = makeTemplate(timeframe: .monthly, boardSize: 3, seedTaskIds: (0..<8).map { "m\($0)" })
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl)

        XCTAssertEqual(vm.timeframe, .monthly)
        XCTAssertEqual(vm.size, 3)
        XCTAssertEqual(vm.selectedTaskIds.count, 8)
        XCTAssertEqual(vm.editingTemplateId, tpl.id)
    }

    func testFreshWizard_NoTemplate_NotTemplateEdit() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        XCTAssertNil(vm.editingTemplateId)
        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertFalse(vm.isRecurring)
    }

    // MARK: - M2 (P1 final fix wave) — poolIds: [] must resolve via the
    // mix, never fall back to stale seedTaskIds.

    func testHydration_PoolIdsNil_FallsBackToSeedTaskIds() throws {
        // Genuinely un-migrated (poolIds absent) — the ONLY case that may
        // fall back.
        let db = try AppDatabase.makeTestInstance()
        let tpl = makeTemplate(seedTaskIds: ["a", "b"], poolIds: nil, manualTaskIds: nil, removedTaskIds: nil)
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl, database: db)

        XCTAssertEqual(vm.selectedTaskIds, Set(["a", "b"]))
    }

    func testHydration_PoolIdsEmptyNoManual_ResolvesToEmptyMix_NotSeedTaskIds() throws {
        // The "no pool yet" edge (defensive, shouldn't occur post-migration).
        // Must resolve through PoolMix.resolveMix (empty mix), NOT fall
        // back to seedTaskIds.
        let db = try AppDatabase.makeTestInstance()
        let tpl = makeTemplate(seedTaskIds: ["stale-should-never-appear"], poolIds: [], manualTaskIds: [], removedTaskIds: [])
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl, database: db)

        XCTAssertEqual(vm.selectedTaskIds, [])
    }

    func testHydration_PoolIdsEmptyWithManual_ResolvesToManualSelection_NotSeedTaskIds() throws {
        // The "flattened" defensive write-through shape
        // (BoardWizardPersist.swift's richer-shape branch: manualTaskIds
        // populated, poolIds: []). Falling back to seedTaskIds here would
        // silently drop the flatten's manual selection — the
        // destructive-edit bug this fix guards against.
        let db = try AppDatabase.makeTestInstance()
        let tpl = makeTemplate(
            seedTaskIds: ["stale-should-never-appear"],
            poolIds: [],
            manualTaskIds: ["m1", "m2"],
            removedTaskIds: []
        )
        let vm = BoardWizardViewModel(preferences: .defaults, editingTemplate: tpl, database: db)

        XCTAssertEqual(vm.selectedTaskIds, Set(["m1", "m2"]))
    }
}
