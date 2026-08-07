import XCTest
@testable import OYBC

/// Issue #321 — Recurring-boards UX pass. Covers the two pure/logic
/// deltas that aren't already exercised by `RecurringBoardTemplatesTests`
/// (which covers `computePoolPreview`):
///   1. The `RisoRecurringBadge.shouldShow(for:)` derivation predicate
///      (`board.spawnedFromTemplateId != nil`, no schema change).
///   2. `BoardWizardViewModel`'s `initialStep` seeding — the Recurring-
///      templates card's "Add tasks" affordance opens the wizard on the
///      Tasks step (2) instead of Setup (1).
final class RecurringBoardsUXPassTests: XCTestCase {

    // MARK: - Fixtures

    private func makeBoard(spawnedFromTemplateId: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "Test board",
            "status": BoardStatus.active.rawValue, "boardSize": 5,
            "timeframe": Timeframe.weekly.rawValue,
            "startDate": "2026-05-01T00:00:00.000Z",
            "endDate": "2026-05-07T23:59:59.000Z",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": true,
            "totalTasks": 24, "completedTasks": 0, "linesCompleted": 0,
            "completedLineIds": "[]",
            "createdAt": "2026-05-01T00:00:00.000Z",
            "updatedAt": "2026-05-01T00:00:00.000Z",
            "version": 1, "isCore": false, "isDeleted": false,
        ]
        if let tid = spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - RisoRecurringBadge.shouldShow

    func testShouldShow_SpawnedFromTemplate_True() {
        let board = makeBoard(spawnedFromTemplateId: "tpl-1")
        XCTAssertTrue(RisoRecurringBadge.shouldShow(for: board))
    }

    func testShouldShow_NotSpawned_False() {
        let board = makeBoard(spawnedFromTemplateId: nil)
        XCTAssertFalse(RisoRecurringBadge.shouldShow(for: board))
    }

    // MARK: - BoardWizardViewModel.initialStep

    func testWizard_DefaultInitialStep_IsSetup() {
        let vm = BoardWizardViewModel(preferences: .defaults)
        XCTAssertEqual(vm.currentStep, 1)
    }

    func testWizard_InitialStepTwo_StartsOnTasksStep() {
        // Mirrors the "Add tasks" card affordance: hydrate from a template
        // AND request step 2 so the user lands directly on the pool
        // picker instead of re-walking Setup.
        let tpl = RecurringBoardTemplate(
            id: "tpl-1", userId: "u1", name: "Morning Routine",
            timeframe: .weekly, boardSize: 5, centerSquareType: .free,
            isRandomized: true,
            seedTaskIds: (0..<24).map { "t\($0)" },
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: "2026-05-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        let vm = BoardWizardViewModel(preferences: .defaults, initialStep: 2, editingTemplate: tpl)
        XCTAssertEqual(vm.currentStep, 2)
        // Hydration still ran — this isn't a fresh wizard.
        XCTAssertEqual(vm.editingTemplateId, tpl.id)
        XCTAssertEqual(vm.selectedTaskIds.count, 24)
    }
}
