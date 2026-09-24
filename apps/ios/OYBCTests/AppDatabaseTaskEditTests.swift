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
/// prove the ids are NOT in the rendered message.
final class AppDatabaseTaskEditTests: XCTestCase {

    private let boardA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let boardB = "bbbbbbbb-0000-4000-8000-000000000002"
    private let boardC = "cccccccc-0000-4000-8000-000000000003"
    private let now = "2026-09-23T12:00:00.000"

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

    private func makeBoard(id: String, name: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": name, "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
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
            try makeBoard(id: boardB, name: "Bravo Weekly").insert(conn)
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
            XCTAssertTrue(names.contains("Bravo Weekly"), "\(names)")
            let message = AppDatabase.taskEditErrorMessage(error)
            XCTAssertTrue(message.hasPrefix("This reference would create a cycle: "), message)
            XCTAssertTrue(message.contains("Alpha Monthly"), message)
            XCTAssertTrue(message.contains("Bravo Weekly"), message)
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
        XCTAssertTrue(names.contains("Bravo Weekly"), "\(names)")
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
}
