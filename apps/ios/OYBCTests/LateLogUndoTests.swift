import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 (T4) — `AppDatabase.undoLateLog` (D10, R2).
/// Twin of web's `lateLogUndo.test.ts`.
@MainActor
final class LateLogUndoTests: XCTestCase {

    private let userId = "u1"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(_ id: String, type: TaskType = .normal, maxCount: CountValue? = nil) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: type,
            action: type == .counting ? "Do" : nil, unit: type == .counting ? "reps" : nil,
            maxCount: maxCount, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makeBoard(
        id: String, startDate: String, endDate: String,
        sealedAt: String? = nil, sealedCompletedCells: [Int]? = nil,
        timeframe: Timeframe = .daily, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": BoardStatus.active.rawValue,
            "boardSize": size, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: 0, col: 0,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    private func events(_ db: AppDatabase, taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId).fetchAll($0) }
    }

    // MARK: - Undo tombstones only the newest late log

    func test_undoLateLog_tombstonesOnlyNewestLateLog_revertsDailyAndMonthly() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))

        let dailyStart = "2026-07-07T00:00:00.000Z"
        let dailyEnd = "2026-07-08T00:00:00.000Z"
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t1"))

        // M seals BEFORE the late log is made (07-10) — so the late log
        // (created 07-10T12:00) is still undoable per D10 (a later-sealing
        // board is what re-freezes it; see the dedicated test below).
        try db.saveBoard(makeBoard(id: "M", startDate: "2026-07-01T00:00:00.000Z", endDate: "2026-07-31T00:00:00.000Z",
                                    sealedAt: "2026-07-09T12:00:00.000Z", sealedCompletedCells: [],
                                    timeframe: .monthly))
        try db.saveBoardTask(makeBoardTask(id: "bt-m", boardId: "M", taskId: "t1"))

        try db.lateLogCompletion(boardId: "D", taskId: "t1", now: "2026-07-10T12:00:00.000Z")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])
        XCTAssertEqual(try fetchBoard(db, "M").sealedCompletedCells, [0])

        try db.undoLateLog(boardId: "D", taskId: "t1", now: "2026-07-10T13:00:00.000Z")

        let ev = try events(db, taskId: "t1")
        XCTAssertEqual(ev.count, 1)
        XCTAssertTrue(ev[0].isDeleted, "the late log is tombstoned, not hard-deleted")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [], "D reverts")
        XCTAssertEqual(try fetchBoard(db, "M").sealedCompletedCells, [], "M reverts too")
    }

    func test_undoLateLog_onlyTheNewestOfMultiple() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 100))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))

        try db.lateLogIncrement(boardId: "b1", taskId: "t1", delta: 3, now: "2026-07-10T12:00:00.000Z")
        try db.lateLogIncrement(boardId: "b1", taskId: "t1", delta: 4, now: "2026-07-10T13:00:00.000Z")
        XCTAssertEqual(try db.fetchTask(id: "t1")?.currentCount, 7)

        try db.undoLateLog(boardId: "b1", taskId: "t1", now: "2026-07-10T14:00:00.000Z")
        XCTAssertEqual(try db.fetchTask(id: "t1")?.currentCount, 3, "only the second (+4) log was reversed")

        let live = try events(db, taskId: "t1").filter { !$0.isDeleted }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].delta, 3)
    }

    /// D10: an in-window event that predates the seal stays immune — undo
    /// must never reach it.
    func test_undoLateLog_neverTouchesPreSealEvent() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: [0]))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        // A pre-seal in-window completion (the sealed record's own basis).
        try db.write {
            try TaskEvent(
                id: "e-pre", userId: self.userId, taskId: "t1", kind: .completion, delta: nil,
                occurredAt: "2026-07-07T12:00:00.000Z", boardId: nil, createdAt: "2026-07-07T12:00:00.000Z",
                updatedAt: "2026-07-07T12:00:00.000Z", lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save($0)
        }

        try db.undoLateLog(boardId: "b1", taskId: "t1", now: "2026-07-10T00:00:00.000Z")

        XCTAssertFalse(try events(db, taskId: "t1").first { $0.id == "e-pre" }!.isDeleted, "the pre-seal event stays immune — there was no late log to undo")
    }

    /// D10: a late log becomes immune again once a LATER containing board
    /// seals after it — history re-freezes.
    func test_lateLog_becomesImmuneAfterLaterContainingBoardSeals() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        let dailyStart = "2026-07-07T00:00:00.000Z"
        let dailyEnd = "2026-07-08T00:00:00.000Z"
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t1"))

        try db.lateLogCompletion(boardId: "D", taskId: "t1", now: "2026-07-10T00:00:00.000Z")

        // A MONTHLY containing the stamp seals AFTER the late log was made.
        try db.saveBoard(makeBoard(id: "M", startDate: "2026-07-01T00:00:00.000Z", endDate: "2026-07-31T00:00:00.000Z", timeframe: .monthly))
        try db.saveBoardTask(makeBoardTask(id: "bt-m", boardId: "M", taskId: "t1"))
        _ = try db.closeBoard(boardId: "M", now: "2026-08-05T00:00:00.000Z")

        // Undo on D must now be a no-op — the event is immune via M.
        try db.undoLateLog(boardId: "D", taskId: "t1", now: "2026-08-06T00:00:00.000Z")

        let ev = try events(db, taskId: "t1")
        XCTAssertEqual(ev.count, 1)
        XCTAssertFalse(ev[0].isDeleted, "re-frozen by M's later seal — undo must be a no-op")
    }

    // MARK: - R4 recovery: undo from the hub, then late-log the correct board

    func test_R4_recovery_undoWrongDayLog_thenLateLogCorrectBoard() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))

        // Tuesday's daily — closed, the INTENDED target.
        try db.saveBoard(makeBoard(id: "tue", startDate: "2026-07-07T00:00:00.000Z", endDate: "2026-07-08T00:00:00.000Z",
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-tue", boardId: "tue", taskId: "t1"))

        // Friday — the user mistakenly logged it from the hub/library at `now`.
        try db.write { db in
            try AppDatabase.appendCompletionEvent(db: db, taskId: "t1", boardId: nil, now: "2026-07-10T09:00:00.000Z")
        }
        XCTAssertEqual(try db.fetchTask(id: "t1")?.isCompleted, true)

        // Recovery step 1: undo the wrong-day log (library un-complete).
        try db.write { db in
            try AppDatabase.tombstoneLatestCompletion(db: db, taskId: "t1", now: "2026-07-10T09:05:00.000Z")
        }
        XCTAssertEqual(try db.fetchTask(id: "t1")?.isCompleted, false)

        // Recovery step 2: late-log it correctly on Tuesday's closed board.
        try db.lateLogCompletion(boardId: "tue", taskId: "t1", now: "2026-07-10T09:10:00.000Z")

        let live = try events(db, taskId: "t1").filter { !$0.isDeleted }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].occurredAt, "2026-07-08T00:00:00.000Z", "the surviving event is stamped at Tuesday's endDate")
        XCTAssertEqual(try fetchBoard(db, "tue").sealedCompletedCells, [0])
    }
}
