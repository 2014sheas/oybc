import XCTest
@testable import OYBC

/// Pure validation/apply for the staged inline-edit patch (Inline Task Editing
/// PR 1, Task 2).
final class TaskEditPatchTests: XCTestCase {

    private func makeTask(
        id: String = "t1",
        type: TaskType,
        title: String = "Task",
        action: String? = nil,
        unit: String? = nil,
        maxCount: Int? = nil
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: title, description: nil, type: type,
            action: action, unit: unit, maxCount: maxCount,
            operatorType: nil, threshold: nil, isOrdered: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func countingPatch(
        _ title: String = "Run", _ action: String = "Run",
        _ goal: String = "5", _ unit: String = "km"
    ) -> TaskEditPatch {
        var p = TaskEditPatch(title: title); p.action = action; p.goal = goal; p.unit = unit
        return p
    }

    // MARK: - Validation

    func test_counting_zero_goal_blocks() {
        var p = countingPatch(); p.goal = "0"
        XCTAssertEqual(p.validate(type: .counting), "Set a goal above zero.")
    }

    func test_counting_unparsed_goal_blocks() {
        var p = countingPatch(); p.goal = "abc"
        XCTAssertEqual(p.validate(type: .counting), "Set a goal above zero.")
    }

    func test_counting_empty_unit_blocks() {
        var p = countingPatch(); p.unit = "  "
        XCTAssertEqual(p.validate(type: .counting), "Add a unit, like km or pages.")
    }

    func test_valid_counting_passes() {
        XCTAssertNil(countingPatch().validate(type: .counting))
    }

    func test_normal_empty_title_blocks() {
        XCTAssertEqual(TaskEditPatch(title: "   ").validate(type: .normal), "A title is required.")
    }

    func test_normal_only_needs_title() {
        XCTAssertNil(TaskEditPatch(title: "Stretch").validate(type: .normal))
    }

    // MARK: - init(from:)

    func test_init_from_counting_task_clones_fields() {
        let base = makeTask(type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        let p = TaskEditPatch(from: base)
        XCTAssertEqual(p.title, "Run 5 km")
        XCTAssertEqual(p.action, "Run")
        XCTAssertEqual(p.goal, "5")
        XCTAssertEqual(p.unit, "km")
    }

    // MARK: - applied(to:)

    func test_apply_counting_updates_fields_and_autotitle() {
        let base = makeTask(type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        var p = TaskEditPatch(from: base); p.title = ""; p.action = "Walk"; p.goal = "3"; p.unit = "mi"
        let out = p.applied(to: base)
        XCTAssertEqual(out.action, "Walk")
        XCTAssertEqual(out.maxCount, 3)
        XCTAssertEqual(out.unit, "mi")
        // Blank title auto-generates from the counting fields.
        XCTAssertEqual(out.title, TaskTitle.generateCounterTaskTitle(action: "Walk", maxCount: 3, unit: "mi"))
    }

    func test_apply_counting_keeps_typed_title() {
        let base = makeTask(type: .counting, title: "Old", action: "Run", unit: "km", maxCount: 5)
        var p = TaskEditPatch(from: base); p.title = "My run"
        XCTAssertEqual(p.applied(to: base).title, "My run")
    }

    func test_apply_normal_sets_title() {
        let base = makeTask(type: .normal, title: "Old")
        let out = TaskEditPatch(title: "Renamed").applied(to: base)
        XCTAssertEqual(out.title, "Renamed")
    }

    // MARK: - Preview

    func test_preview_string() {
        XCTAssertEqual(countingPatch().countingPreview, "Reads as: Run — 5 — km")
    }

    func test_preview_partial_uses_dashes() {
        var p = TaskEditPatch(title: ""); p.action = "Run"
        XCTAssertEqual(p.countingPreview, "Reads as: Run — — — —")
    }

    func test_preview_nil_when_all_blank() {
        XCTAssertNil(TaskEditPatch(title: "anything").countingPreview)
    }
}
