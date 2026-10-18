import XCTest
import GRDB
@testable import OYBC

/// TASK_WINDOW_REWORK slice 3a — `AppDatabase.setPlacementParams` (set / merge /
/// clear / version / enqueue) and the Board Edit parameter-vs-task-edit split
/// (`BoardEditParamSplit`, `SquareEditTaskSheet.patchHasNonParameterFields`).
@MainActor
final class PlacementParamsWriteTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let start = "2026-09-01T00:00:00.000Z", end = "2026-09-30T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("t", maxCount: 10))
        try db.saveBoard(K.board(id: "b1", startDate: start, endDate: end, size: 3))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "t", size: 3))
        return db
    }

    private func stored(_ db: AppDatabase) throws -> BoardTask {
        try XCTUnwrap(try db.fetchBoardTask(id: "bt"))
    }

    private func queued(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try K.queue(db, type: "boardTasks", id: "bt")
    }

    // MARK: - setPlacementParams

    func test_set_writesFields_bumpsVersion_enqueuesUpdate() throws {
        let db = try makeDb()
        let wrote = try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            targetOverride: .set(25), targetKind: .set(.discrete), titleOverride: .set("  Big run ")
        ))
        XCTAssertTrue(wrote)
        let bt = try stored(db)
        XCTAssertEqual(bt.targetOverride, 25)
        XCTAssertEqual(bt.targetKind, .discrete)
        XCTAssertEqual(bt.titleOverride, "Big run", "normalised (trimmed)")
        XCTAssertEqual(bt.version, 2)
        let items = try queued(db)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].operationType, .update)
        let payload = try JSONSerialization.jsonObject(with: Data(items[0].payload.utf8)) as? [String: Any]
        XCTAssertEqual(payload?["targetOverride"] as? Double, 25)
        XCTAssertEqual(payload?["titleOverride"] as? String, "Big run")
    }

    func test_merge_keepsUntouchedFields() throws {
        let db = try makeDb()
        try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            targetOverride: .set(25), targetKind: .set(.discrete)
        ))
        try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            childTargets: .set([PlacementChildTarget(childId: "c1", target: 4)]), titleOverride: .set("T")
        ))
        let bt = try stored(db)
        XCTAssertEqual(bt.targetOverride, 25, "kept")
        XCTAssertEqual(bt.childTargets, [PlacementChildTarget(childId: "c1", target: 4)])
        XCTAssertEqual(bt.titleOverride, "T")
        XCTAssertEqual(bt.version, 3)
    }

    func test_clear_writesExplicitNull_andTheEnqueuePayloadOmitsTheKey() throws {
        let db = try makeDb()
        try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            targetOverride: .set(25), targetKind: .set(.discrete), titleOverride: .set("T")
        ))
        try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            targetOverride: .clear, targetKind: .clear
        ))
        // The column is NULL on disk (save() alone would have left it).
        let raw = try db.read { try Row.fetchOne($0, sql: "SELECT targetOverride, targetKind, titleOverride FROM board_tasks WHERE id = 'bt'") }
        XCTAssertNil(raw?["targetOverride"] as Double?)
        XCTAssertNil(raw?["targetKind"] as String?)
        XCTAssertEqual(raw?["titleOverride"] as String?, "T", "an unrelated field stays")
        let last = try XCTUnwrap(try queued(db).last)
        let payload = try JSONSerialization.jsonObject(with: Data(last.payload.utf8)) as? [String: Any]
        XCTAssertNil(payload?["targetOverride"], "an absent key is what the clearable-field delete keys on")
        XCTAssertNil(payload?["targetKind"])
        XCTAssertEqual(try stored(db).version, 3)
    }

    func test_noChange_writesNothing() throws {
        let db = try makeDb()
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(targetOverride: .clear)))
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch()))
        try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(titleOverride: .set("Same")))
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(titleOverride: .set("Same"))))
        XCTAssertEqual(try stored(db).version, 2)
        XCTAssertEqual(try queued(db).count, 1)
    }

    func test_invalidOverride_isNormalisedAway() throws {
        let db = try makeDb()
        // A fractional goal at a whole kind drops the override AND the kind.
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(
            targetOverride: .set(2.5), targetKind: .set(.discrete)
        )))
        XCTAssertNil(try stored(db).targetOverride)
    }

    func test_tombstonedPlacement_andSealedBoard_areLeftAlone() throws {
        let db = try makeDb()
        try db.write { try $0.execute(sql: "UPDATE board_tasks SET isDeleted = 1 WHERE id = 'bt'") }
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(titleOverride: .set("X"))))
        try db.write { try $0.execute(sql: "UPDATE board_tasks SET isDeleted = 0 WHERE id = 'bt'; UPDATE boards SET sealedAt = '2026-10-01T00:00:00.000Z' WHERE id = 'b1'") }
        XCTAssertFalse(try db.setPlacementParams(boardTaskId: "bt", patch: PlacementParamsPatch(titleOverride: .set("X"))))
    }

    func test_goalOverride_reDerivesTheBoard() throws {
        let db = try makeDb()
        var counting = K.task("c", maxCount: 10, currentCount: 4)
        counting.title = "Run"
        try db.saveTask(counting)
        try db.saveBoardTask(K.placement(id: "bt2", boardId: "b1", taskId: "c", cell: 1, size: 3))
        try K.addIncrement(db, taskId: "c", delta: 4, occurredAt: "2026-09-10T00:00:00.000Z")
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).completedTasks, 0)
        try db.setPlacementParams(boardTaskId: "bt2", patch: PlacementParamsPatch(
            targetOverride: .set(4), targetKind: .set(.discrete)
        ))
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).completedTasks, 1, "4 of a per-board goal of 4")
    }

    // MARK: - Split

    private func counting(goal: CountValue = 5) -> Task {
        K.task("c", maxCount: goal, title: "Run 5 miles")
    }

    private func override(
        _ title: String = "", type: TaskType = .counting, action: String? = "Run", unit: String? = "miles",
        goal: CountValue? = 5, kind: CountKind? = nil, compound: TaskEditPatch? = nil
    ) -> StagedTaskOverride {
        StagedTaskOverride(title: title, type: type, action: action, unit: unit, maxCount: goal, compound: compound, countKind: kind)
    }

    func test_untouchedSheet_hasNoNonParameterFields() {
        let t = counting()
        XCTAssertFalse(BoardEditParamSplit.hasNonParameterFields(task: t, override: override(), storedChildren: nil))
        XCTAssertFalse(SquareEditTaskSheet.patchHasNonParameterFields(
            task: t,
            patch: .init(title: "", type: .counting, action: "Run", unit: "miles", maxCount: 5, countKind: .discrete),
            storedChildren: nil
        ))
    }

    func test_goalAndTitle_areParameters_actionUnitKindType_areNot() {
        let t = counting()
        XCTAssertFalse(BoardEditParamSplit.hasNonParameterFields(task: t, override: override("Evening run", goal: 9), storedChildren: nil))
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: t, override: override(action: "Jog"), storedChildren: nil))
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: t, override: override(unit: "km"), storedChildren: nil))
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: t, override: override(kind: .continuous), storedChildren: nil))
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: t, override: override(type: .normal), storedChildren: nil))
    }

    func test_compoundChildGoal_isAParameter_structureIsNot() throws {
        var parent = K.task("p", maxCount: nil)
        parent.type = .compound
        parent.operatorType = .and
        let c1 = K.task("c1", maxCount: 10), c2 = K.task("c2", maxCount: 3)
        var structure = TaskEditPatch(title: "p")
        structure.operatorType = .and
        structure.children = [ChildPatch(from: c1), ChildPatch(from: c2)]
        let ov = { (s: TaskEditPatch) in
            StagedTaskOverride(title: "p", type: .compound, action: nil, unit: nil, maxCount: nil, compound: s)
        }
        XCTAssertFalse(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(structure), storedChildren: [c1, c2]))

        var goalOnly = structure
        goalOnly.children[0].goal = "20"
        XCTAssertFalse(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(goalOnly), storedChildren: [c1, c2]),
                       "an existing child's goal is a childTargets entry")

        var removed = structure
        removed.children[1].markedDeleted = true
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(removed), storedChildren: [c1, c2]))
        var reordered = structure
        reordered.children.reverse()
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(reordered), storedChildren: [c1, c2]))
        var op = structure
        op.operatorType = .or
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(op), storedChildren: [c1, c2]))
        var childAction = structure
        childAction.children[0].action = "Swim"
        XCTAssertTrue(BoardEditParamSplit.hasNonParameterFields(task: parent, override: ov(childAction), storedChildren: [c1, c2]))
    }

    func test_wouldFork_isFalseForAParameterOnlyDraft() {
        XCTAssertFalse(SquareEditTaskSheet.wouldFork(taskId: "t", draft: nil, forkingTaskIds: ["t"], rows: [:], hasNonParameter: false))
        XCTAssertTrue(SquareEditTaskSheet.wouldFork(taskId: "t", draft: nil, forkingTaskIds: ["t"], rows: [:], hasNonParameter: true))
        XCTAssertFalse(SquareEditTaskSheet.wouldFork(taskId: "t", draft: nil, forkingTaskIds: [], rows: [:], hasNonParameter: true))
    }

    func test_parameterPatch_goalTitleAndRevert() {
        let t = counting()
        var bt = K.placement(id: "bt", boardId: "b1", taskId: "c")
        var p = BoardEditParamSplit.parameterPatch(override: override("Evening run", goal: 9), task: t, placement: bt, storedChildren: nil)
        XCTAssertEqual(p.targetOverride, .set(9))
        XCTAssertEqual(p.targetKind, .set(.discrete))
        XCTAssertEqual(p.titleOverride, .set("Evening run"))
        // Back to the task's own goal clears the override; a blank (auto) title clears the title.
        bt.targetOverride = 9
        bt.targetKind = .discrete
        p = BoardEditParamSplit.parameterPatch(override: override("", goal: 5), task: t, placement: bt, storedChildren: nil)
        XCTAssertEqual(p.targetOverride, .clear)
        XCTAssertEqual(p.titleOverride, .clear)
        // The task's own title carries no override.
        p = BoardEditParamSplit.parameterPatch(override: override("Run 5 miles", goal: 5), task: t, placement: bt, storedChildren: nil)
        XCTAssertEqual(p.titleOverride, .clear)
    }

    func test_parameterPatch_compoundChildTargets() {
        var parent = K.task("p", maxCount: nil)
        parent.type = .compound
        let c1 = K.task("c1", maxCount: 10)
        var structure = TaskEditPatch(title: "p")
        structure.children = [ChildPatch(from: c1)]
        structure.children[0].goal = "4"
        let ov = StagedTaskOverride(title: "p", type: .compound, action: nil, unit: nil, maxCount: nil, compound: structure)
        let bt = K.placement(id: "bt", boardId: "b1", taskId: "p")
        let p = BoardEditParamSplit.parameterPatch(override: ov, task: parent, placement: bt, storedChildren: [c1])
        XCTAssertEqual(p.childTargets, .set([PlacementChildTarget(childId: "c1", target: 4)]))
        // Back to the child's own goal removes the entry.
        structure.children[0].goal = "10"
        var withEntry = bt
        withEntry.childTargets = [PlacementChildTarget(childId: "c1", target: 4)]
        let back = BoardEditParamSplit.parameterPatch(
            override: StagedTaskOverride(title: "p", type: .compound, action: nil, unit: nil, maxCount: nil, compound: structure),
            task: parent, placement: withEntry, storedChildren: [c1]
        )
        XCTAssertEqual(back.childTargets, .set([]))
    }
}
