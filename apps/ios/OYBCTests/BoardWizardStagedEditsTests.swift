import XCTest
@testable import OYBC

/// Staged-edit map + display overlay on the wizard VM (Inline Task Editing
/// PR 1, Task 3).
final class BoardWizardStagedEditsTests: XCTestCase {

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: .defaults, database: try! AppDatabase.makeTestInstance())
    }

    private func makeTask(id: String, title: String, type: TaskType = .normal) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: title, description: nil, type: type,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil, isOrdered: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_stage_returns_nil_first_time() {
        let vm = makeVM()
        let prev = vm.stageEdit(TaskEditPatch(title: "New"), for: "x")
        XCTAssertNil(prev)
        XCTAssertEqual(vm.stagedEdits["x"]?.title, "New")
    }

    func test_stage_returns_previous_patch() {
        let vm = makeVM()
        _ = vm.stageEdit(TaskEditPatch(title: "New"), for: "x")
        let prev = vm.stageEdit(TaskEditPatch(title: "Newer"), for: "x")
        XCTAssertEqual(prev?.title, "New")
        XCTAssertEqual(vm.stagedEdits["x"]?.title, "Newer")
    }

    func test_revert_to_previous_restores_it() {
        let vm = makeVM()
        _ = vm.stageEdit(TaskEditPatch(title: "New"), for: "x")
        let prev = vm.stageEdit(TaskEditPatch(title: "Newer"), for: "x")
        vm.revertEdit(for: "x", to: prev)
        XCTAssertEqual(vm.stagedEdits["x"]?.title, "New")
    }

    func test_revert_to_nil_removes_the_edit() {
        let vm = makeVM()
        _ = vm.stageEdit(TaskEditPatch(title: "New"), for: "x")
        vm.revertEdit(for: "x", to: nil)
        XCTAssertNil(vm.stagedEdits["x"])
    }

    func test_effectiveTask_overlays_staged_title() {
        let vm = makeVM()
        let base = makeTask(id: "x", title: "Old")
        _ = vm.stageEdit(TaskEditPatch(title: "Renamed"), for: "x")
        XCTAssertEqual(vm.effectiveTask(base).title, "Renamed")
    }

    func test_effectiveTask_passthrough_when_unstaged() {
        let vm = makeVM()
        let base = makeTask(id: "y", title: "Untouched")
        XCTAssertEqual(vm.effectiveTask(base).title, "Untouched")
    }

    func test_removing_task_drops_its_staged_edit() {
        let vm = makeVM()
        vm.toggleTaskSelection("x")
        _ = vm.stageEdit(TaskEditPatch(title: "New"), for: "x")
        vm.toggleTaskSelection("x") // remove
        XCTAssertNil(vm.stagedEdits["x"])
    }
}
