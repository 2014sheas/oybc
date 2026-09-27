import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 2 (T1) — `AppDatabase.saveBoardDetails` +
/// `assertBoardEditable` (D4/D11/D12). Twin of web `boardDetailsSave.test.ts`.
final class BoardDetailsSaveTests: XCTestCase {

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func dayISO(_ n: Int) -> String {
        let cal = Calendar.current
        return wizardLocalISOString(cal.startOfDay(for: cal.date(byAdding: .day, value: n, to: Date())!))
    }

    private func noonISO(_ n: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: n, to: Date())!
        return wizardLocalISOString(cal.date(bySettingHour: 12, minute: 0, second: 0, of: d)!)
    }

    private func makeBoard(
        id: String = "b1", timeframe: Timeframe = .indefinite, startDate: String,
        endDate: String? = nil, sealedAt: String? = nil, isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "Board", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": timeframe.rawValue, "startDate": startDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": isDeleted,
        ]
        if let endDate { dict["endDate"] = endDate }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(_ id: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil,
            requiredCount: nil, totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    private func boardQueueCount(_ db: AppDatabase, _ boardId: String) throws -> Int {
        try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM sync_queue WHERE entityType = 'boards' AND entityId = ?",
                             arguments: [boardId]) ?? 0
        }
    }

    func test_saveBoardDetails_writesNameAndOngoingStart_andEnqueues() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeBoard(startDate: dayISO(-5)))
        let queuedBefore = try boardQueueCount(db, "b1")

        var draft = BoardDetailsDraft(board: try XCTUnwrap(db.fetchBoard(id: "b1")))
        draft.name = "Renamed"
        draft.startDate = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        try db.saveBoardDetails(boardId: "b1", patch: try XCTUnwrap(draft.patch()))

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.name, "Renamed")
        XCTAssertEqual(saved.startDate, dayISO(-10), "an ongoing board's start-date edit is saved (B1)")
        XCTAssertNil(saved.endDate)
        XCTAssertEqual(saved.version, 2)
        XCTAssertGreaterThan(try boardQueueCount(db, "b1"), queuedBefore)
    }

    func test_ongoingStartEdit_keepsInWindowCompletionGreen() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeBoard(startDate: dayISO(-5)))
        try db.saveTask(makeTask("t1"))
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        try db.dbQueue.write { d in
            try TaskEvent(
                id: "e1", userId: "u1", taskId: "t1", kind: .completion, delta: nil,
                occurredAt: self.noonISO(-2), boardId: nil, createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(d)
        }

        // Move the start EARLIER — the completion stays inside the window.
        var draft = BoardDetailsDraft(board: try XCTUnwrap(db.fetchBoard(id: "b1")))
        draft.startDate = Calendar.current.date(byAdding: .day, value: -20, to: Date())!
        try db.saveBoardDetails(boardId: "b1", patch: try XCTUnwrap(draft.patch()))

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.startDate, dayISO(-20))
        XCTAssertEqual(saved.completedTasks, 1, "the in-window completion stays green after the start edit")
    }

    /// Migrated from `BoardPlayViewModelTests.
    /// test_handleEditSave_customDatesChanged_appliesNewWindow` (Board Edit
    /// redesign slice 2, T3 — dates no longer route through
    /// `handleEditSave`). Unlike the ongoing-start-only edit above, a picked
    /// CUSTOM date range DOES apply the new window — pinned as intentional.
    func test_customDatesChanged_appliesNewWindow_dropsOutOfWindowCompletion() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeBoard(timeframe: .custom, startDate: dayISO(-30), endDate: dayISO(-1)))
        try db.saveTask(makeTask("t1"))
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        // Completion inside the OLD window but before the NEW one the user
        // is about to pick.
        try db.dbQueue.write { d in
            try TaskEvent(
                id: "e1", userId: "u1", taskId: "t1", kind: .completion, delta: nil,
                occurredAt: self.noonISO(-20), boardId: nil, createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(d)
        }

        var draft = BoardDetailsDraft(board: try XCTUnwrap(db.fetchBoard(id: "b1")))
        draft.startDate = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        draft.endDate = Calendar.current.date(byAdding: .day, value: 25, to: Date())!
        try db.saveBoardDetails(boardId: "b1", patch: try XCTUnwrap(draft.patch()))

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertNotEqual(saved.startDate, dayISO(-30), "changing the custom dates DOES apply the new window — deliberate")
        XCTAssertEqual(saved.completedTasks, 0, "the old completion predates the newly-picked custom window")
    }

    func test_saveBoardDetails_sealedBoard_throws_noWrite_noQueueRow() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeBoard(startDate: dayISO(-5), sealedAt: "2026-09-01T00:00:00.000Z"))
        let queuedBefore = try boardQueueCount(db, "b1")

        XCTAssertThrowsError(try db.saveBoardDetails(
            boardId: "b1", patch: AppDatabase.UpdateActiveBoardPatch(name: "Nope"))
        ) { XCTAssertEqual($0 as? BoardEditError, .boardNotEditable) }

        let after = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(after.name, "Board")
        XCTAssertEqual(after.version, 1)
        XCTAssertEqual(try boardQueueCount(db, "b1"), queuedBefore)
    }

    func test_saveBoardDetails_deletedOrMissingBoard_throws() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeBoard(startDate: dayISO(-5), isDeleted: true))
        XCTAssertThrowsError(try db.saveBoardDetails(
            boardId: "b1", patch: AppDatabase.UpdateActiveBoardPatch(name: "Nope"))
        ) { XCTAssertEqual($0 as? BoardEditError, .boardNotEditable) }
        XCTAssertThrowsError(try db.saveBoardDetails(
            boardId: "missing", patch: AppDatabase.UpdateActiveBoardPatch(name: "Nope"))
        ) { XCTAssertEqual($0 as? BoardEditError, .boardNotEditable) }
    }
}
