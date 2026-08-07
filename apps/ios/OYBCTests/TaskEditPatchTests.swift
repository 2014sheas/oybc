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
            operatorType: nil, threshold: nil,
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

    // MARK: - Compound (PR 2)

    private func compoundPatch(_ children: [ChildPatch], title: String = "Routine") -> TaskEditPatch {
        var p = TaskEditPatch(title: title); p.children = children
        return p
    }

    private func simpleStep(_ title: String, id: String = "c1") -> ChildPatch {
        ChildPatch(id: id, childTaskId: id, title: title, isProgress: false)
    }

    private func progressStep(_ title: String, id: String = "p1", goal: String = "3", unit: String = "km") -> ChildPatch {
        var c = ChildPatch(id: id, childTaskId: id, title: title, isProgress: true)
        c.action = title; c.goal = goal; c.unit = unit
        return c
    }

    func test_childPatch_from_counting_task_is_progress() {
        let child = makeTask(id: "cc", type: .counting, title: "Run 3 km", action: "Run", unit: "km", maxCount: 3)
        let cp = ChildPatch(from: child)
        XCTAssertTrue(cp.isProgress)
        XCTAssertEqual(cp.childTaskId, "cc")
        XCTAssertEqual(cp.action, "Run"); XCTAssertEqual(cp.goal, "3"); XCTAssertEqual(cp.unit, "km")
        XCTAssertFalse(cp.isNew)
    }

    func test_childPatch_from_normal_task_is_simple() {
        let cp = ChildPatch(from: makeTask(id: "cn", type: .normal, title: "Stretch"))
        XCTAssertFalse(cp.isProgress)
        XCTAssertEqual(cp.title, "Stretch")
    }

    func test_compound_empty_title_blocks() {
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")]); p.title = "  "
        XCTAssertEqual(p.validate(type: .compound), "A title is required.")
    }

    func test_compound_needs_two_steps() {
        let p = compoundPatch([simpleStep("only", id: "a")])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two steps.")
    }

    func test_compound_blank_titled_steps_dont_count() {
        let p = compoundPatch([simpleStep("A", id: "a"), simpleStep("   ", id: "b"), simpleStep("", id: "c")])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two steps.")
    }

    func test_compound_deleted_steps_dont_count() {
        var deleted = simpleStep("B", id: "b"); deleted.markedDeleted = true
        let p = compoundPatch([simpleStep("A", id: "a"), deleted])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two steps.")
    }

    func test_compound_two_simple_steps_valid() {
        let p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
        XCTAssertNil(p.validate(type: .compound))
    }

    func test_compound_progress_step_missing_goal_blocks() {
        var noGoal = progressStep("Run", id: "p"); noGoal.goal = "0"
        let p = compoundPatch([simpleStep("A", id: "a"), noGoal])
        XCTAssertEqual(p.validate(type: .compound), "Progress step \"Run\" needs a goal and a unit.")
    }

    func test_compound_progress_step_missing_unit_blocks() {
        var noUnit = progressStep("Run", id: "p"); noUnit.unit = ""
        let p = compoundPatch([simpleStep("A", id: "a"), noUnit])
        XCTAssertEqual(p.validate(type: .compound), "Progress step \"Run\" needs a goal and a unit.")
    }

    func test_compound_valid_with_progress_step() {
        let p = compoundPatch([simpleStep("A", id: "a"), progressStep("Run", id: "p")])
        XCTAssertNil(p.validate(type: .compound))
    }

    func test_apply_compound_sets_title() {
        let base = makeTask(id: "cmp", type: .compound, title: "Old")
        let p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")], title: "Morning")
        let out = p.applied(to: base)
        XCTAssertEqual(out.title, "Morning")
    }
}
