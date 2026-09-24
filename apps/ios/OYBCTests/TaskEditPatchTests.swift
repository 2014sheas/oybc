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
        ChildPatch(id: id, childTaskId: id, title: title, isCounting: false)
    }

    private func progressStep(_ title: String, id: String = "p1", goal: String = "3", unit: String = "km") -> ChildPatch {
        var c = ChildPatch(id: id, childTaskId: id, title: title, isCounting: true)
        c.action = title; c.goal = goal; c.unit = unit
        return c
    }

    func test_childPatch_from_counting_task_is_progress() {
        let child = makeTask(id: "cc", type: .counting, title: "Run 3 km", action: "Run", unit: "km", maxCount: 3)
        let cp = ChildPatch(from: child)
        XCTAssertTrue(cp.isCounting)
        XCTAssertEqual(cp.childTaskId, "cc")
        XCTAssertEqual(cp.action, "Run"); XCTAssertEqual(cp.goal, "3"); XCTAssertEqual(cp.unit, "km")
        XCTAssertFalse(cp.isNew)
    }

    func test_childPatch_from_normal_task_is_simple() {
        let cp = ChildPatch(from: makeTask(id: "cn", type: .normal, title: "Stretch"))
        XCTAssertFalse(cp.isCounting)
        XCTAssertEqual(cp.title, "Stretch")
    }

    func test_childPatch_carries_the_linked_task_type_including_compound() {
        XCTAssertEqual(ChildPatch(from: makeTask(id: "cc", type: .counting, title: "Run", action: "Run", unit: "km", maxCount: 3)).childType, .counting)
        XCTAssertEqual(ChildPatch(from: makeTask(id: "cn", type: .normal, title: "Stretch")).childType, .normal)
        // A picked nested compound badges C but stays a title-only card:
        // not counting, so no Action/Goal/Unit fields.
        let nested = ChildPatch(from: makeTask(id: "k", type: .compound, title: "Evening routine"))
        XCTAssertEqual(nested.childType, .compound)
        XCTAssertFalse(nested.isCounting)
    }

    func test_new_childPatch_defaults_childType_from_isCounting() {
        XCTAssertEqual(ChildPatch(id: "a", childTaskId: nil, title: "", isCounting: true).childType, .counting)
        XCTAssertEqual(ChildPatch(id: "b", childTaskId: nil, title: "", isCounting: false).childType, .normal)
    }

    func test_subtask_badge_accessibility_labels() {
        XCTAssertEqual(RisoCompoundEditFieldsView.subtaskTypeLabel(.normal), "Normal sub-task")
        XCTAssertEqual(RisoCompoundEditFieldsView.subtaskTypeLabel(.counting), "Counting sub-task")
        XCTAssertEqual(RisoCompoundEditFieldsView.subtaskTypeLabel(.compound), "Compound sub-task")
    }

    // MARK: - Quick-add append paths (RisoCompoundEditFieldsView)

    func test_appendPicked_links_the_existing_task_with_its_own_type() {
        var d = TaskEditPatch(title: "P")
        d.children = [ChildPatch(id: "a", childTaskId: "a", title: "A", isCounting: false)]
        let run = makeTask(id: "r", type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        RisoCompoundEditFieldsView.appendPicked(run, to: &d)
        XCTAssertEqual(d.children.count, 2)
        let added = d.children[1]
        XCTAssertEqual(added.id, "r")
        XCTAssertEqual(added.childTaskId, "r")
        XCTAssertFalse(added.isNew)
        XCTAssertEqual(added.title, "Run 5 km")
        XCTAssertTrue(added.isCounting)
        XCTAssertEqual(added.childType, .counting)
        XCTAssertEqual(added.goal, "5")
        XCTAssertEqual(added.unit, "km")
        XCTAssertEqual(d.keptChildTaskIds, ["a", "r"])
    }

    func test_appendTyped_normal_appends_a_new_titled_subtask() {
        var d = TaskEditPatch(title: "P")
        RisoCompoundEditFieldsView.appendTyped("Third", isCounting: false, to: &d)
        XCTAssertEqual(d.children.count, 1)
        let added = d.children[0]
        XCTAssertTrue(added.isNew)
        XCTAssertEqual(added.title, "Third")
        XCTAssertFalse(added.isCounting)
        XCTAssertEqual(added.childType, .normal)
        XCTAssertEqual(added.action, "")
        XCTAssertEqual(d.liveChildren.count, 1)
    }

    func test_appendTyped_counting_takes_the_text_as_its_action() {
        var d = TaskEditPatch(title: "P")
        RisoCompoundEditFieldsView.appendTyped("Swim", isCounting: true, to: &d)
        RisoCompoundEditFieldsView.appendTyped("Swim", isCounting: true, to: &d)
        let added = d.children[0]
        XCTAssertTrue(added.isNew)
        XCTAssertEqual(added.title, "Swim")
        XCTAssertEqual(added.action, "Swim")
        XCTAssertTrue(added.isCounting)
        XCTAssertEqual(added.childType, .counting)
        XCTAssertEqual(added.goal, "")
        XCTAssertEqual(added.unit, "")
        // Each typed entry is its own new sub-task (fresh ids).
        XCTAssertNotEqual(d.children[0].id, d.children[1].id)
        // Live, so validation then asks for its Goal / Unit on the card.
        XCTAssertEqual(d.liveChildren.count, 2)
    }

    func test_compound_empty_title_blocks() {
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")]); p.title = "  "
        XCTAssertEqual(p.validate(type: .compound), "A title is required.")
    }

    func test_compound_needs_two_steps() {
        let p = compoundPatch([simpleStep("only", id: "a")])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two sub-tasks.")
    }

    func test_compound_blank_titled_steps_dont_count() {
        let p = compoundPatch([simpleStep("A", id: "a"), simpleStep("   ", id: "b"), simpleStep("", id: "c")])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two sub-tasks.")
    }

    func test_compound_deleted_steps_dont_count() {
        var deleted = simpleStep("B", id: "b"); deleted.markedDeleted = true
        let p = compoundPatch([simpleStep("A", id: "a"), deleted])
        XCTAssertEqual(p.validate(type: .compound), "A compound task needs at least two sub-tasks.")
    }

    func test_compound_two_simple_steps_valid() {
        let p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
        XCTAssertNil(p.validate(type: .compound))
    }

    func test_compound_progress_step_missing_goal_blocks() {
        var noGoal = progressStep("Run", id: "p"); noGoal.goal = "0"
        let p = compoundPatch([simpleStep("A", id: "a"), noGoal])
        XCTAssertEqual(p.validate(type: .compound), "Counting sub-task \"Run\" needs a goal and a unit.")
    }

    func test_compound_progress_step_missing_unit_blocks() {
        var noUnit = progressStep("Run", id: "p"); noUnit.unit = ""
        let p = compoundPatch([simpleStep("A", id: "a"), noUnit])
        XCTAssertEqual(p.validate(type: .compound), "Counting sub-task \"Run\" needs a goal and a unit.")
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

    // MARK: - Compound operator/threshold (Inline Compound Editor Rework)

    func test_mOfN_missing_threshold_blocks() {
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
        p.operatorType = .mOfN
        p.threshold = nil
        XCTAssertEqual(p.validate(type: .compound), "Choose how many sub-tasks must complete.")
    }

    func test_mOfN_threshold_above_live_count_blocks() {
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
        p.operatorType = .mOfN
        p.threshold = 3
        XCTAssertEqual(p.validate(type: .compound), "Choose how many sub-tasks must complete.")
    }

    func test_mOfN_valid_threshold_passes() {
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
        p.operatorType = .mOfN
        p.threshold = 2
        XCTAssertNil(p.validate(type: .compound))
    }

    func test_and_or_dont_require_threshold() {
        for op: OperatorType in [.and, .or] {
            var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")])
            p.operatorType = op
            p.threshold = nil
            XCTAssertNil(p.validate(type: .compound), "\(op) shouldn't require a threshold")
        }
    }

    func test_apply_compound_roundtrips_operator_and_threshold() {
        let base = makeTask(id: "cmp", type: .compound, title: "Old")
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")], title: "Morning")
        p.operatorType = .mOfN
        p.threshold = 2
        let out = p.applied(to: base)
        XCTAssertEqual(out.operatorType, .mOfN)
        XCTAssertEqual(out.threshold, 2)
    }

    func test_apply_compound_and_clears_threshold() {
        let base = makeTask(id: "cmp", type: .compound, title: "Old")
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")], title: "Morning")
        p.operatorType = .and
        p.threshold = 5 // stale — should be cleared, AND carries no threshold.
        let out = p.applied(to: base)
        XCTAssertEqual(out.operatorType, .and)
        XCTAssertNil(out.threshold)
    }

    func test_apply_compound_mOfN_clamps_threshold_to_live_child_count() {
        let base = makeTask(id: "cmp", type: .compound, title: "Old")
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")], title: "Morning")
        p.operatorType = .mOfN
        p.threshold = 99 // stale (e.g. sub-tasks were removed after the value was set)
        let out = p.applied(to: base)
        XCTAssertEqual(out.threshold, 2, "clamps to the live child count")
    }

    func test_apply_compound_mOfN_clamps_nil_threshold_to_one() {
        let base = makeTask(id: "cmp", type: .compound, title: "Old")
        var p = compoundPatch([simpleStep("A", id: "a"), simpleStep("B", id: "b")], title: "Morning")
        p.operatorType = .mOfN
        p.threshold = nil
        let out = p.applied(to: base)
        XCTAssertEqual(out.threshold, 1)
    }

    func test_init_from_compound_task_seeds_operator_and_threshold() {
        let base = makeTask(id: "cmp", type: .compound, title: "Routine")
        var withOperator = base
        withOperator.operatorType = .mOfN
        withOperator.threshold = 3
        let p = TaskEditPatch(from: withOperator)
        XCTAssertEqual(p.operatorType, .mOfN)
        XCTAssertEqual(p.threshold, 3)
    }

    // MARK: - Editor seeding (Inline Compound Editor Rework, Bug #5)

    func test_seededForEditor_counting_blanks_title_when_it_matches_autogenerated() {
        let autoTitle = TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 5, unit: "km")
        let base = makeTask(type: .counting, title: autoTitle, action: "Run", unit: "km", maxCount: 5)
        let p = TaskEditPatch.seededForEditor(from: base)
        XCTAssertEqual(p.title, "", "an auto-generated title should reseed blank so it keeps deriving")
        XCTAssertEqual(p.action, "Run")
        XCTAssertEqual(p.goal, "5")
        XCTAssertEqual(p.unit, "km")
    }

    func test_seededForEditor_counting_keeps_custom_title() {
        let base = makeTask(type: .counting, title: "My custom run", action: "Run", unit: "km", maxCount: 5)
        let p = TaskEditPatch.seededForEditor(from: base)
        XCTAssertEqual(p.title, "My custom run")
    }

    func test_seededForEditor_normal_task_unaffected() {
        let base = makeTask(type: .normal, title: "Stretch")
        let p = TaskEditPatch.seededForEditor(from: base)
        XCTAssertEqual(p.title, "Stretch")
    }

    func test_seededForEditor_reseeded_title_still_rederives_on_apply() {
        // The bug this fixes: after a blank reseed, changing the goal should
        // produce a freshly-derived title through the normal apply path.
        let autoTitle = TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 5, unit: "km")
        let base = makeTask(type: .counting, title: autoTitle, action: "Run", unit: "km", maxCount: 5)
        var p = TaskEditPatch.seededForEditor(from: base)
        p.goal = "10"
        let out = p.applied(to: base)
        XCTAssertEqual(out.title, TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 10, unit: "km"))
    }
}
