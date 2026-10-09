import XCTest
import GRDB
@testable import OYBC

/// The global editor's type switch (Task Detail / Tasks tab): Simple ⇄
/// Counting and Simple / Counting → Compound through `applyTaskEditPatch`,
/// the SAME helper Board Edit's commit uses (`AppDatabase.applyTaskTypeSwitch`)
/// — global (no fork) and retroactive on every board placing the task. Web
/// twin: `saveTaskEdit.typeSwitch.test.ts`.
@MainActor
final class ApplyTaskEditPatchTypeSwitchTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let now = "2026-10-08T12:00:00.000Z"
    private let start = "2026-10-05T00:00:00.000Z", end = "2099-12-31T23:59:59.999Z"
    private let occurred = "2026-10-06T09:00:00.000Z"

    private func plain(_ id: String, type: TaskType = .normal, isCompleted: Bool = false) -> Task {
        var t = K.task(id, maxCount: nil, isCompleted: isCompleted, title: "Stretch")
        t.type = type
        t.action = nil
        t.unit = nil
        return t
    }

    private func patch(
        type: TaskType?, title: String = "Stretch", action: String = "", unit: String = "", goal: String = "",
        countKind: CountKind? = nil, compound: TaskEditPatch? = nil
    ) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: "", action: action, unit: unit, maxCountStr: goal,
            trigger: .bingo, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            compound: compound, countKind: countKind, type: type
        )
    }

    private func placeOn(_ db: AppDatabase, board id: String, taskId: String, completed: Int, sealedAt: String? = nil) throws {
        var board = K.board(id: id, startDate: start, endDate: end, timeframe: .weekly, sealedAt: sealedAt)
        board.completedTasks = completed
        try db.saveBoard(board)
        try db.saveBoardTask(K.placement(id: "bt-\(id)", boardId: id, taskId: taskId))
    }

    private func completion(_ db: AppDatabase, taskId: String) throws {
        try db.write { d in
            try TaskEvent(
                id: "e1", userId: K.userId, taskId: taskId, kind: .completion, delta: nil,
                occurredAt: occurred, boardId: nil, createdAt: occurred, updatedAt: occurred,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(d)
        }
    }

    private func seeded() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        return db
    }

    private func assertRefused(_ db: AppDatabase, _ id: String, _ p: EditTaskSheet.Patch, keeps type: TaskType,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: id, patch: p, now: now), file: file, line: line)
        let row = try XCTUnwrap(K.fetchTask(db, id), file: file, line: line)
        XCTAssertEqual(row.type, type, file: file, line: line)
        XCTAssertEqual(row.version, 1, file: file, line: line)
    }

    func test_simpleToCounting_setsFields_oldCompletionInert_cachesRecomputed_liveBoardRederived_sealedUntouched() throws {
        let db = try seeded()
        var t = plain("T", isCompleted: true)
        t.completedAt = occurred
        try db.saveTask(t)
        try completion(db, taskId: "T")
        try placeOn(db, board: "b-live", taskId: "T", completed: 1)
        try placeOn(db, board: "b-sealed", taskId: "T", completed: 1, sealedAt: "2026-10-07T12:00:00.000Z")

        try db.applyTaskEditPatch(
            taskId: "T",
            patch: patch(type: .counting, title: "Run 5 km", action: "Run", unit: "km", goal: "5", countKind: .discrete),
            now: now
        )

        let row = try XCTUnwrap(K.fetchTask(db, "T"))
        XCTAssertEqual(row.type, .counting)
        XCTAssertEqual(row.action, "Run")
        XCTAssertEqual(row.unit, "km")
        XCTAssertEqual(row.maxCount, 5)
        XCTAssertEqual(row.countKind, .discrete)
        XCTAssertFalse(row.isCompleted)
        XCTAssertEqual(row.currentCount, 0)
        XCTAssertNil(row.completedAt)
        XCTAssertEqual(row.version, 2)
        let event = try db.read { try TaskEvent.fetchOne($0, key: "e1") }
        XCTAssertEqual(event?.isDeleted, false)
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: "b-live") }?.completedTasks, 0)
        let sealed = try XCTUnwrap(try db.read { try Board.fetchOne($0, key: "b-sealed") })
        XCTAssertEqual(sealed.completedTasks, 1)
        XCTAssertEqual(sealed.version, 1)
        XCTAssertEqual(try db.read { try Task.fetchCount($0) }, 1, "global: no fork")
    }

    func test_countingToSimple_clearsCountingFields() throws {
        let db = try seeded()
        try db.saveTask(K.task("T", maxCount: 5, currentCount: 2, title: "Run 5 miles"))
        try K.addIncrement(db, taskId: "T", delta: 2, occurredAt: occurred)
        try placeOn(db, board: "b-live", taskId: "T", completed: 0)

        try db.applyTaskEditPatch(taskId: "T", patch: patch(type: .normal, title: "Run"), now: now)

        let row = try XCTUnwrap(K.fetchTask(db, "T"))
        XCTAssertEqual(row.type, .normal)
        XCTAssertEqual(row.title, "Run")
        XCTAssertNil(row.action)
        XCTAssertNil(row.unit)
        XCTAssertNil(row.maxCount)
        XCTAssertNil(row.currentCount)
        XCTAssertFalse(row.isCompleted)
        XCTAssertEqual(row.version, 2)
    }

    func test_simpleToCompound_keepsId_linksNewSubTasks() throws {
        let db = try seeded()
        try db.saveTask(plain("T"))
        try placeOn(db, board: "b-live", taskId: "T", completed: 0)
        var structure = TaskEditPatch(title: "Stretch")
        structure.operatorType = .and
        structure.children = [
            ChildPatch(id: "n1", childTaskId: nil, title: "Hamstrings", isCounting: false),
            ChildPatch(id: "n2", childTaskId: nil, title: "Calves", isCounting: false),
        ]

        try db.applyTaskEditPatch(taskId: "T", patch: patch(type: .compound, compound: structure), now: now)

        let row = try XCTUnwrap(K.fetchTask(db, "T"))
        XCTAssertEqual(row.type, .compound)
        XCTAssertEqual(row.operatorType, .and)
        XCTAssertFalse(row.isCompleted)
        let links = try db.read {
            try CompoundChild.filter(Column("compoundTaskId") == "T" && Column("isDeleted") == false).fetchAll($0)
        }
        XCTAssertEqual(links.count, 2)
    }

    func test_compoundNeverSwitchesOut() throws {
        let db = try seeded()
        var c = plain("C", type: .compound)
        c.operatorType = .and
        try db.saveTask(c)
        try assertRefused(db, "C", patch(type: .normal, title: "Plain"), keeps: .compound)
    }

    func test_linkedCounterNeverChangesType() throws {
        let db = try seeded()
        try db.saveTask(K.task("R", maxCount: 10))
        try db.saveTask(K.task("L", maxCount: 5, sharedCounterId: "R"))
        try assertRefused(db, "L", patch(type: .normal, title: "Run"), keeps: .counting)
    }

    func test_counterRootWithLiveCopiesNeverChangesType() throws {
        let db = try seeded()
        try db.saveTask(K.task("R", maxCount: 10))
        try db.saveTask(K.task("L", maxCount: 5, sharedCounterId: "R"))
        try assertRefused(db, "R", patch(type: .normal, title: "Run"), keeps: .counting)
    }

    func test_hubBornCounterWithZeroCopiesNeverChangesType() throws {
        let db = try seeded()
        var hub = K.task("H", maxCount: 10)
        hub.isCounter = true
        try db.saveTask(hub)
        try assertRefused(db, "H", patch(type: .normal, title: "Run"), keeps: .counting)
        var probe = hub
        probe.sharedCounterId = nil
        XCTAssertFalse(TaskTypeSwitch.showsPicker(task: probe, original: nil), "hub counter shows its type fixed")
    }

    func test_achievementNeverChangesType() throws {
        let db = try seeded()
        try db.saveTask(plain("A", type: .achievement))
        try assertRefused(db, "A", patch(type: .normal, title: "Plain"), keeps: .achievement)
    }

    func test_unchangedType_isAnOrdinaryEdit() throws {
        let db = try seeded()
        try db.saveTask(plain("T"))
        try db.applyTaskEditPatch(taskId: "T", patch: patch(type: .normal, title: "Stretch more"), now: now)
        let row = try XCTUnwrap(K.fetchTask(db, "T"))
        XCTAssertEqual(row.type, .normal)
        XCTAssertEqual(row.title, "Stretch more")
        XCTAssertEqual(row.version, 2)
    }
}
