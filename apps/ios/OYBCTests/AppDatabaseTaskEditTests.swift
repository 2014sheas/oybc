import XCTest
import GRDB
@testable import OYBC

/// Tests for `AppDatabase.applyTaskEditPatch` + `checkAchievementRetargetCycle`
/// (`AppDatabase+TaskEditing.swift`) — the one data-layer home for the edit
/// sheet save path that used to be copied into `TaskDetailView`,
/// `TaskDetailSheetView` and `TasksTabView`. Runs against a fresh in-memory
/// `AppDatabase.makeTestInstance()`.
///
/// Cycle fixture: achievement X (watching board A) sits on board B, so B → A.
/// Achievement T sits on board A. Re-targeting T at B closes A → B → A; at C
/// it doesn't. Board ids are UUID-shaped so the name-mapping assertion can
/// prove the ids are NOT in the rendered message. Board B is a daily core
/// board whose stored name is the frozen legacy "Today" (pre-#482), so the
/// cycle path must show its HEALED display name, "Mar 15, 2026".
final class AppDatabaseTaskEditTests: XCTestCase {

    private let boardA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let boardB = "bbbbbbbb-0000-4000-8000-000000000002"
    private let boardC = "cccccccc-0000-4000-8000-000000000003"
    private let now = "2026-09-23T12:00:00.000"
    /// `Board.displayName` of board B (core, daily, stored as "Today").
    private let healedB = "Mar 15, 2026"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let ts = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func makeBoard(
        id: String,
        name: String,
        timeframe: Timeframe = .monthly,
        startDate: String = "2026-06-01T00:00:00.000",
        endDate: String = "2026-06-30T23:59:59.999",
        isCore: Bool = false,
        centerSquareType: CenterSquareType = .free
    ) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": name, "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue, "isCore": isCore,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": centerSquareType.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(
        _ id: String,
        type: TaskType = .normal,
        referencedBoardId: String? = nil
    ) -> Task {
        Task(
            id: id, userId: "u1", title: "Task \(id)", type: type,
            referencedBoardId: referencedBoardId,
            achievementTrigger: type == .achievement ? .bingo : nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false,
            createdAt: "2026-06-01T00:00:00.000", updatedAt: "2026-06-01T00:00:00.000",
            version: 1, isDeleted: false
        )
    }

    private func placement(_ boardId: String, _ taskId: String) -> BoardTask {
        BoardTask(
            id: "bt-\(boardId)-\(taskId)", boardId: boardId, taskId: taskId,
            row: 0, col: 0, isCenter: false,
            createdAt: "2026-06-01T00:00:00.000", updatedAt: "2026-06-01T00:00:00.000",
            lastSyncedAt: nil, version: 1
        )
    }

    /// Seeds boards A/B/C, achievement X (watching A) on B, achievement T
    /// (watching C) on A.
    private func seedCycleFixture(_ db: AppDatabase) throws {
        try db.write { conn in
            try makeBoard(id: boardA, name: "Alpha Monthly").insert(conn)
            try makeBoard(
                id: boardB, name: "Today", timeframe: .daily,
                startDate: "2026-03-15T00:00:00.000", endDate: "2026-03-15T23:59:59.999",
                isCore: true
            ).insert(conn)
            try makeBoard(id: boardC, name: "Charlie Daily").insert(conn)
            try makeTask("x", type: .achievement, referencedBoardId: boardA).insert(conn)
            try makeTask("t", type: .achievement, referencedBoardId: boardC).insert(conn)
            try placement(boardB, "x").insert(conn)
            try placement(boardA, "t").insert(conn)
        }
    }

    private func patch(
        title: String = "Task t",
        description: String = "",
        refMode: EditTaskSheet.Patch.RefMode = .board,
        selectedBoardId: String = "",
        selectedTemplateId: String = "",
        requiredCountStr: String = "",
        trigger: AchievementTrigger = .bingo
    ) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: description,
            action: "", unit: "", maxCountStr: "",
            timeframe: nil, startDate: nil, endDate: nil, clearTimeboxed: false,
            trigger: trigger, requiredCountStr: requiredCountStr,
            refMode: refMode, selectedBoardId: selectedBoardId, selectedTemplateId: selectedTemplateId
        )
    }

    private func taskUpdateRows(_ db: AppDatabase, _ id: String) throws -> [SyncQueueItem] {
        try db.fetchPendingSyncItems().filter {
            $0.entityType == "tasks" && $0.entityId == id && $0.operationType == .update
        }
    }

    // MARK: - applyTaskEditPatch

    func test_apply_normalTask_appliesPatchBumpsVersionAndEnqueues() throws {
        let db = try makeDb()
        try db.write { try makeTask("n1").insert($0) }

        let saved = try db.applyTaskEditPatch(
            taskId: "n1",
            patch: patch(title: "  Renamed  ", description: "   "),
            now: now
        )

        XCTAssertEqual(saved.title, "Renamed")
        XCTAssertNil(saved.description)
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.updatedAt, now)
        let stored = try XCTUnwrap(try db.fetchTask(id: "n1"))
        XCTAssertEqual(stored.title, "Renamed")
        XCTAssertEqual(stored.version, 2)
        XCTAssertEqual(try taskUpdateRows(db, "n1").count, 1)
    }

    func test_apply_nonCyclingRetarget_savesNewReference() throws {
        let db = try makeDb()
        try seedCycleFixture(db)

        // C has no outgoing edges, so A → C closes no loop.
        let saved = try db.applyTaskEditPatch(
            taskId: "t",
            patch: patch(refMode: .board, selectedBoardId: boardC, trigger: .greenlog),
            now: now
        )

        XCTAssertEqual(saved.referencedBoardId, boardC)
        XCTAssertNil(saved.referencedTemplateId)
        XCTAssertNil(saved.requiredCount)
        XCTAssertEqual(saved.achievementTrigger, .greenlog)
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(try taskUpdateRows(db, "t").count, 1)
    }

    func test_apply_cyclingRetarget_throwsCycleWithBoardNames_andSavesNothing() throws {
        let db = try makeDb()
        try seedCycleFixture(db)

        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: "t",
            patch: patch(refMode: .board, selectedBoardId: boardB),
            now: now
        )) { error in
            guard case .cycle(let names)? = error as? AppDatabase.TaskEditError else {
                return XCTFail("expected .cycle, got \(error)")
            }
            XCTAssertTrue(names.contains("Alpha Monthly"), "\(names)")
            XCTAssertTrue(names.contains(self.healedB), "\(names)")
            XCTAssertFalse(names.contains("Today"), "raw frozen name leaked: \(names)")
            let message = AppDatabase.taskEditErrorMessage(error)
            XCTAssertTrue(message.hasPrefix("This reference would create a cycle: "), message)
            XCTAssertTrue(message.contains("Alpha Monthly"), message)
            XCTAssertTrue(message.contains(self.healedB), message)
            XCTAssertFalse(message.contains("Today"), message)
            XCTAssertFalse(message.contains(self.boardA), message)
            XCTAssertFalse(message.contains(self.boardB), message)
        }

        let stored = try XCTUnwrap(try db.fetchTask(id: "t"))
        XCTAssertEqual(stored.referencedBoardId, boardC)
        XCTAssertEqual(stored.version, 1)
        XCTAssertTrue(try taskUpdateRows(db, "t").isEmpty)
    }

    func test_apply_achievementValidation_rejectsBeforeCycleCheck() throws {
        let db = try makeDb()
        try seedCycleFixture(db)

        let cases: [(EditTaskSheet.Patch, String)] = [
            (patch(refMode: .board, selectedBoardId: ""), "Please select a specific board to watch."),
            (patch(refMode: .template, selectedTemplateId: ""), "Please select a recurring template to watch."),
            (patch(refMode: .template, selectedTemplateId: "tpl-1", requiredCountStr: "0"),
             "Required count must be a whole number greater than 0."),
        ]
        for (badPatch, expected) in cases {
            XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: "t", patch: badPatch, now: now)) { error in
                XCTAssertEqual(error as? AppDatabase.TaskEditError, .invalid(message: expected))
                XCTAssertEqual(AppDatabase.taskEditErrorMessage(error), expected)
            }
        }
        XCTAssertEqual(try XCTUnwrap(try db.fetchTask(id: "t")).version, 1)
    }

    func test_apply_missingTask_throwsTaskNotFound() throws {
        let db = try makeDb()
        XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: "nope", patch: patch(), now: now)) { error in
            XCTAssertEqual(error as? AppDatabase.TaskEditError, .taskNotFound)
        }
    }

    func test_apply_softDeletedTask_throwsTaskNotFound() throws {
        let db = try makeDb()
        var deleted = makeTask("d1")
        deleted.isDeleted = true
        deleted.deletedAt = "2026-06-02T00:00:00.000"
        try db.write { try deleted.insert($0) }

        XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: "d1", patch: patch(title: "Revived"), now: now)) { error in
            XCTAssertEqual(error as? AppDatabase.TaskEditError, .taskNotFound)
        }

        let stored = try XCTUnwrap(try db.fetchTask(id: "d1"))
        XCTAssertEqual(stored.version, 1)
        XCTAssertTrue(stored.isDeleted)
        XCTAssertEqual(stored.title, "Task d1")
        XCTAssertTrue(try db.fetchPendingSyncItems().filter { $0.entityId == "d1" }.isEmpty)
    }

    // MARK: - checkAchievementRetargetCycle

    func test_check_cyclingRetarget_returnsCycleWithNamesNotIds() throws {
        let db = try makeDb()
        try seedCycleFixture(db)

        let result = try db.checkAchievementRetargetCycle(
            taskId: "t",
            patch: patch(refMode: .board, selectedBoardId: boardB)
        )

        guard case .cycle(let names) = result else { return XCTFail("expected .cycle, got \(result)") }
        XCTAssertEqual(names.first, "Alpha Monthly")
        XCTAssertTrue(names.contains(healedB), "\(names)")
        XCTAssertFalse(names.contains("Today"), "raw frozen name leaked: \(names)")
        let joined = names.joined(separator: " → ")
        XCTAssertFalse(joined.contains(boardA), joined)
        XCTAssertFalse(joined.contains(boardB), joined)
    }

    func test_check_nonCyclingRetarget_returnsOk() throws {
        let db = try makeDb()
        try seedCycleFixture(db)

        let result = try db.checkAchievementRetargetCycle(
            taskId: "t",
            patch: patch(refMode: .board, selectedBoardId: boardC)
        )

        XCTAssertEqual(result, .ok)
    }

    func test_check_selfReference_returnsDegenerateCycleAsNames() throws {
        // T is placed on A; watching A itself is the degenerate [A, A] cycle.
        let db = try makeDb()
        try seedCycleFixture(db)

        let result = try db.checkAchievementRetargetCycle(
            taskId: "t",
            patch: patch(refMode: .board, selectedBoardId: boardA)
        )

        XCTAssertEqual(result, .cycle(pathNames: ["Alpha Monthly", "Alpha Monthly"]))
    }

    // MARK: - Compound structure (Task Detail save)

    /// P = AND of A, B (links index 0/1). Board X (active, no center, window
    /// from 2026-06-01) holds P at (0,0). A has an in-window completion event,
    /// so OR makes P green on X and AND does not.
    private func compoundFixture(
        _ db: AppDatabase
    ) throws -> (p: Task, a: Task, b: Task, x: Board) {
        var p = makeTask("p", type: .compound)
        p.title = "P"
        p.operatorType = .and
        let a = makeTask("a"), b = makeTask("b")
        let x = makeBoard(id: "board-x", name: "X", centerSquareType: .none)
        try db.write { conn in
            try p.insert(conn); try a.insert(conn); try b.insert(conn)
            try makeLink(id: "l-a", parent: "p", child: "a", index: 0).insert(conn)
            try makeLink(id: "l-b", parent: "p", child: "b", index: 1).insert(conn)
            try x.insert(conn)
            try placement(x.id, "p").insert(conn)
            try completionEvent("ev-a", taskId: "a", occurredAt: "2026-06-15T00:00:00.000").insert(conn)
        }
        return (p, a, b, x)
    }

    /// Copied from `AppDatabaseSyncEnqueueTests.makeLink`.
    private func makeLink(id: String, parent: String, child: String, index: Int) -> CompoundChild {
        CompoundChild(
            id: id, compoundTaskId: parent, childTaskId: child, childIndex: index,
            createdAt: "2026-06-01T00:00:00.000", updatedAt: "2026-06-01T00:00:00.000",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// Smallest completion-event row (after `TombstoneSealImmunityTests`).
    private func completionEvent(_ id: String, taskId: String, occurredAt: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: "u1", taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: occurredAt, updatedAt: occurredAt,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func structure(
        _ p: Task, operator op: OperatorType, threshold: Int? = nil, children: [ChildPatch]
    ) -> TaskEditPatch {
        var s = TaskEditPatch(from: p)
        s.operatorType = op
        s.threshold = threshold
        s.children = children
        return s
    }

    private func basicPatch(
        title: String, description: String = "", compound: TaskEditPatch?
    ) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: description, action: "", unit: "", maxCountStr: "",
            timeframe: nil, startDate: nil, endDate: nil, clearTimeboxed: false,
            trigger: .bingo, requiredCountStr: "", refMode: .board,
            selectedBoardId: "", selectedTemplateId: "", compound: compound
        )
    }

    private func liveLinks(_ db: AppDatabase, parent: String) throws -> [CompoundChild] {
        try db.read {
            try CompoundChild
                .filter(Column("compoundTaskId") == parent && Column("isDeleted") == false)
                .order(Column("childIndex"))
                .fetchAll($0)
        }
    }

    func test_editCompound_changeRule_reDerivesPlacedBoard() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        let kids = [ChildPatch(from: f.a), ChildPatch(from: f.b)]

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(f.p, operator: .or, children: kids)),
            now: now
        )
        let afterOr = try db.read { try Task.fetchOne($0, key: f.p.id) }
        XCTAssertEqual(afterOr?.operatorType, .or)
        XCTAssertEqual(afterOr?.version, 2, "one version bump per save")
        XCTAssertEqual(try taskUpdateRows(db, f.p.id).count, 1, "one parent enqueue per save")
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: f.x.id) }?.completedTasks, 1)

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(f.p, operator: .and, children: kids)),
            now: now
        )
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: f.x.id) }?.completedTasks, 0)
    }

    func test_editCompound_structureTitleWins_descriptionRidesAlong() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        var s = structure(f.p, operator: .and, children: [ChildPatch(from: f.a), ChildPatch(from: f.b)])
        s.title = "  Structure title  "

        let saved = try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "Basic title", description: "Why this matters", compound: s),
            now: now
        )
        XCTAssertEqual(saved.title, "Structure title")
        XCTAssertEqual(saved.description, "Why this matters")
        XCTAssertEqual(try db.read { try Task.fetchOne($0, key: f.p.id) }?.title, "Structure title")
    }

    func test_editCompound_renameChild_isGlobalAndEnqueued() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        var renamed = ChildPatch(from: f.a); renamed.title = "A renamed"

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(
                f.p, operator: .and, children: [renamed, ChildPatch(from: f.b)])),
            now: now
        )
        let a = try db.read { try Task.fetchOne($0, key: f.a.id) }
        XCTAssertEqual(a?.title, "A renamed")
        XCTAssertEqual(a?.version, 2)
        XCTAssertEqual(try taskUpdateRows(db, f.a.id).count, 1)
        XCTAssertTrue(try taskUpdateRows(db, f.b.id).isEmpty, "an unchanged child is not re-enqueued")
    }

    func test_editCompound_removeChild_unlinksOnly_childPlacementSurvives() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        let y = makeBoard(id: "board-y", name: "Y", centerSquareType: .none)
        try db.write { conn in
            try y.insert(conn)
            try placement(y.id, f.a.id).insert(conn)
        }
        let newC = ChildPatch(id: "draft-c", childTaskId: nil, title: "C", isCounting: false)

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(
                f.p, operator: .and, children: [ChildPatch(from: f.b), newC])),
            now: now
        )

        let oldLink = try db.read { try CompoundChild.fetchOne($0, key: "l-a") }
        XCTAssertEqual(oldLink?.isDeleted, true)
        let a = try db.read { try Task.fetchOne($0, key: f.a.id) }
        XCTAssertEqual(a?.isDeleted, false, "removing a sub-task unlinks it, never deletes the Task")
        let aOnY = try db.read { try BoardTask.fetchOne($0, key: "bt-\(y.id)-\(f.a.id)") }
        XCTAssertEqual(aOnY?.isDeleted, false)

        let live = try liveLinks(db, parent: f.p.id)
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live.first?.childTaskId, f.b.id)
        let c = try db.read {
            try Task.filter(Column("title") == "C" && Column("isDeleted") == false).fetchOne($0)
        }
        XCTAssertNotNil(c)
        XCTAssertEqual(live.last?.childTaskId, c?.id)

        let rows = try db.fetchPendingSyncItems()
        XCTAssertEqual(rows.filter { $0.entityType == "compoundChildren" && $0.operationType == .delete }.count, 1)
        XCTAssertEqual(rows.filter { $0.entityType == "compoundChildren" && $0.operationType == .create }.count, 1)
        XCTAssertEqual(rows.filter { $0.entityType == "tasks" && $0.operationType == .create }.count, 1)
    }

    func test_editCompound_refusesFewerThanTwo_writesNothing() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        let before = try db.read { (try Task.fetchOne($0, key: f.p.id), try SyncQueueItem.fetchCount($0)) }

        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "Renamed", compound: structure(
                f.p, operator: .or, children: [ChildPatch(from: f.a)])),
            now: now
        )) { err in
            XCTAssertEqual(err as? AppDatabase.TaskEditError, .invalid(message: "A compound task needs at least two sub-tasks."))
        }

        let after = try db.read { (try Task.fetchOne($0, key: f.p.id), try SyncQueueItem.fetchCount($0)) }
        XCTAssertEqual(before.0?.version, after.0?.version)
        XCTAssertEqual(after.0?.title, "P")
        XCTAssertEqual(after.0?.operatorType, .and)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(try liveLinks(db, parent: f.p.id).count, 2)
    }

    func test_editCompound_sealedBoardUntouched() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        var sealed = makeBoard(id: "board-s", name: "S", centerSquareType: .none)
        sealed.sealedAt = "2026-06-30T23:59:59.999"
        sealed.sealedCompletedCells = [4]
        try db.write { conn in
            try sealed.insert(conn)
            try placement(sealed.id, f.p.id).insert(conn)
        }

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(
                f.p, operator: .or, children: [ChildPatch(from: f.a), ChildPatch(from: f.b)])),
            now: now
        )

        let s = try db.read { try Board.fetchOne($0, key: sealed.id) }
        XCTAssertEqual(s?.sealedCompletedCells, [4])
        XCTAssertEqual(s?.version, 1)
        XCTAssertEqual(s?.completedTasks, 0)
        // Control: the live board X in the same save DID re-derive.
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: f.x.id) }?.completedTasks, 1)
    }

    func test_editCompound_thresholdStored_overCountRefused_clearedForAnd() throws {
        let db = try makeDb(); let f = try compoundFixture(db)
        let c = makeTask("c")
        try db.write { conn in
            try c.insert(conn)
            try makeLink(id: "l-c", parent: "p", child: "c", index: 2).insert(conn)
        }
        let kids = [ChildPatch(from: f.a), ChildPatch(from: f.b), ChildPatch(from: c)]

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(f.p, operator: .mOfN, threshold: 2, children: kids)),
            now: now
        )
        XCTAssertEqual(try db.read { try Task.fetchOne($0, key: f.p.id) }?.threshold, 2)

        // 5 of 3 is refused before any write (the clamp in `applied(to:)` is
        // a backstop behind validation, never reached here).
        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(f.p, operator: .mOfN, threshold: 5, children: kids)),
            now: now
        )) { err in
            XCTAssertEqual(err as? AppDatabase.TaskEditError, .invalid(message: "Choose how many sub-tasks must complete."))
        }
        XCTAssertEqual(try db.read { try Task.fetchOne($0, key: f.p.id) }?.threshold, 2)

        try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P", compound: structure(f.p, operator: .and, threshold: 2, children: kids)),
            now: now
        )
        let p = try db.read { try Task.fetchOne($0, key: f.p.id) }
        XCTAssertEqual(p?.operatorType, .and)
        XCTAssertNil(p?.threshold)
    }

    func test_applyTaskEditPatch_compoundWithoutStructure_editsBasicFieldsOnly() throws {
        let db = try makeDb(); let f = try compoundFixture(db)

        let saved = try db.applyTaskEditPatch(
            taskId: f.p.id,
            patch: basicPatch(title: "P2", description: "New notes", compound: nil),
            now: now
        )
        XCTAssertEqual(saved.title, "P2")
        XCTAssertEqual(saved.description, "New notes")
        XCTAssertEqual(saved.operatorType, .and)
        XCTAssertEqual(saved.version, 2)
        let live = try liveLinks(db, parent: f.p.id)
        XCTAssertEqual(live.map(\.childTaskId), [f.a.id, f.b.id])
        XCTAssertTrue(try db.fetchPendingSyncItems().filter { $0.entityType == "compoundChildren" }.isEmpty)
    }
}
