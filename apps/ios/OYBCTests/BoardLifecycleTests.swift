import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 (T4) — `AppDatabase+BoardLifecycle.swift`.
/// Close (D3) / Reopen (D6) + the achievement-watcher refresh (D8). Twin of
/// web's `boardLifecycle.test.ts`.
@MainActor
final class BoardLifecycleTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-02T00:00:00.000Z"
    private let inWindow = "2026-07-01T12:00:00.000Z"
    /// Past END + 1 day (next-window auto-close, so a plain `endDate < now`
    /// closing-out check is satisfied too).
    private let afterEnd = "2026-07-03T01:00:00.000Z"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(_ id: String, isCompleted: Bool = false) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: "N", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: isCompleted ? now : nil,
            currentCount: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makeBoard(
        id: String, startDate: String? = nil, endDate: String? = nil,
        status: BoardStatus = .active, sealedAt: String? = nil,
        sealedCompletedCells: [Int]? = nil, reopenedAt: String? = nil,
        timeframe: Timeframe = .daily, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": status.rawValue,
            "boardSize": size, "timeframe": timeframe.rawValue,
            "startDate": startDate ?? start, "endDate": endDate ?? end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let reopenedAt { dict["reopenedAt"] = reopenedAt }
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, cell: Int = 0, size: Int = 1) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: cell / size, col: cell % size,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func makeEvent(_ id: String, taskId: String, occurredAt: String, isDeleted: Bool = false) -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    // MARK: - Close (D3)

    func test_closeBoard_sealsAnEndedBoard_sameAsSealBoard() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        try db.write { try self.makeEvent("e1", taskId: "t1", occurredAt: self.inWindow).save($0) }

        let closed = try db.closeBoard(boardId: "b1", now: afterEnd)
        XCTAssertTrue(closed)
        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.sealedAt, afterEnd)
        XCTAssertEqual(board.sealedCompletedCells, [0])
    }

    func test_closeBoard_alreadyClosed_isNoOpNotError() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: []))
        XCTAssertFalse(try db.closeBoard(boardId: "b1", now: afterEnd))
    }

    func test_closeBoard_notEnded_throwsNotClosable() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", startDate: "2026-07-02T00:00:00.000Z", endDate: "2026-07-03T00:00:00.000Z"))
        XCTAssertThrowsError(try db.closeBoard(boardId: "b1", now: inWindow)) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notClosable)
        }
    }

    func test_closeBoard_indefinite_throwsNotClosable() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", endDate: nil, timeframe: .indefinite))
        XCTAssertThrowsError(try db.closeBoard(boardId: "b1", now: afterEnd)) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notClosable)
        }
    }

    func test_closeBoard_draft_throwsNotClosable() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", status: .draft))
        XCTAssertThrowsError(try db.closeBoard(boardId: "b1", now: afterEnd)) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notClosable)
        }
    }

    func test_closeBoard_deleted_throwsNotClosable() throws {
        let db = try makeDb(); try seedUser(db)
        var board = makeBoard(id: "b1")
        board.isDeleted = true
        try db.saveBoard(board)
        XCTAssertThrowsError(try db.closeBoard(boardId: "b1", now: afterEnd)) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notClosable)
        }
    }

    // MARK: - Reopen (D6)

    func test_reopenBoard_clearsSnapshotStampsReopenedAt_recomputesLiveStatus() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "b1", sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        // An in-window completion event exists — once reopened, the LIVE
        // re-derivation should paint it green (greenlog → COMPLETED, since
        // this is a 1x1 board).
        try db.write { try self.makeEvent("e1", taskId: "t1", occurredAt: self.inWindow).save($0) }

        let reopened = try db.reopenBoard(boardId: "b1", now: "2026-07-05T00:00:00.000Z")
        XCTAssertTrue(reopened)

        let board = try fetchBoard(db, "b1")
        XCTAssertNil(board.sealedAt)
        XCTAssertNil(board.sealedCompletedCells)
        XCTAssertEqual(board.reopenedAt, "2026-07-05T00:00:00.000Z")
        XCTAssertEqual(board.completedTasks, 1, "live re-derivation recomputed from the event union")
        XCTAssertEqual(board.status, .completed)
        XCTAssertGreaterThan(board.version, 1)

        let queued = try db.read {
            try SyncQueueItem.filter(Column("entityId") == "b1" && Column("entityType") == "boards").fetchCount($0)
        }
        XCTAssertGreaterThan(queued, 0, "Reopen must enqueue a sync item")
    }

    func test_reopenBoard_greenlogReversesToActiveWhenEventsDontMeetIt() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        // Sealed while COMPLETED, but no in-window events at all.
        try db.saveBoard(makeBoard(id: "b1", status: .completed, sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: [0]))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))

        _ = try db.reopenBoard(boardId: "b1", now: "2026-07-05T00:00:00.000Z")

        let board = try fetchBoard(db, "b1")
        XCTAssertEqual(board.status, .active)
        XCTAssertNil(board.completedAt)
        XCTAssertEqual(board.completedTasks, 0)
    }

    func test_reopenBoard_notSealed_throwsNotReopenable() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        XCTAssertThrowsError(try db.reopenBoard(boardId: "b1")) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notReopenable)
        }
    }

    func test_reopenBoard_deleted_throwsNotReopenable() throws {
        let db = try makeDb(); try seedUser(db)
        var board = makeBoard(id: "b1", sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: [])
        board.isDeleted = true
        try db.saveBoard(board)
        XCTAssertThrowsError(try db.reopenBoard(boardId: "b1")) {
            XCTAssertEqual($0 as? BoardLifecycleError, .notReopenable)
        }
    }

    func test_reopenBoard_spawnsNoTemplateOrRecurringRow() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: []))
        _ = try db.reopenBoard(boardId: "b1")
        let templates = try db.dbQueue.read { try RecurringBoardTemplate.fetchAll($0) }
        XCTAssertTrue(templates.isEmpty)
    }

    /// R5 / D1: once reopened, the board never auto-closes again, however
    /// far past its old deadline — pinned end-to-end (not just the pure
    /// predicate SealingTests already covers).
    func test_reopenedBoard_neverAutoClosesViaBackstop() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: []))
        _ = try db.reopenBoard(boardId: "b1", now: "2026-07-02T12:00:00.000Z")

        XCTAssertEqual(try db.runBackstopAutoSeal(userId: userId, now: "2027-01-01T00:00:00.000Z"), [])
        XCTAssertNil(try fetchBoard(db, "b1").sealedAt)
    }

    // MARK: - Achievement-watcher refresh (D8)

    private func makeWatcherTask(_ id: String, referencedBoardId: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: "W", description: nil, type: .achievement,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: referencedBoardId, referencedTemplateId: nil,
            achievementTrigger: .greenlog, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// Closing the watched board (making it greenlog) must repaint the
    /// achievement square placed on ANOTHER (live) board — D8's whole point.
    func test_closeBoard_refreshesSpecificBoardWatcher() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "watched"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "watched", taskId: "t1"))
        try db.write { try self.makeEvent("e1", taskId: "t1", occurredAt: self.inWindow).save($0) }

        try db.saveTask(makeWatcherTask("w1", referencedBoardId: "watched"))
        try db.saveBoard(makeBoard(id: "hostBoard", startDate: "2026-07-02T00:00:00.000Z", endDate: "2026-07-03T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "hostBoard", taskId: "w1"))

        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 0)

        _ = try db.closeBoard(boardId: "watched", now: afterEnd)

        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 1, "the watcher board must recompute once its watched board closes greenlog")
    }

    /// Reopening a watched board (undoing its greenlog) must un-paint the
    /// watcher square on the host board.
    func test_reopenBoard_refreshesWatcher_afterGreenlogReverts() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1"))
        try db.saveBoard(makeBoard(id: "watched", status: .completed, sealedAt: "2026-07-02T10:00:00.000Z", sealedCompletedCells: [0]))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "watched", taskId: "t1"))
        // No in-window events — reopening flips it back to ACTIVE (not greenlog).

        try db.saveTask(makeWatcherTask("w1", referencedBoardId: "watched"))
        try db.saveBoard(makeBoard(id: "hostBoard", startDate: "2026-07-02T00:00:00.000Z", endDate: "2026-07-03T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "hostBoard", taskId: "w1"))
        // Seed the host board as if it had already painted the watcher green.
        var host = try fetchBoard(db, "hostBoard")
        host.completedTasks = 1
        try db.saveBoard(host)

        _ = try db.reopenBoard(boardId: "watched", now: "2026-07-05T00:00:00.000Z")

        XCTAssertEqual(try fetchBoard(db, "hostBoard").completedTasks, 0, "un-greenlogging the watched board must un-paint the watcher square")
    }
}
