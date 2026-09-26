import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) — the per-square
/// lock at the data layer: `BoardTask.isLocked` decode/encode + the v34
/// column, `setBoardTaskLocked` (version bump + sync enqueue + the sealed /
/// deleted / unchanged no-ops), and the `updateBoardTaskPositions` guard (a
/// move set that relocates a locked row is rejected whole — nothing partial).
final class BoardTaskLockTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000"
    private let end = "2026-07-01T23:59:59.999"
    private let sealed = "2026-07-02T07:00:00.000Z"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(_ id: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: "T \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil,
            requiredCount: nil, totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    private func makeBoard(id: String, sealedAt: String? = nil, isDeleted: Bool = false, size: Int = 3) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": BoardStatus.active.rawValue,
            "boardSize": size, "timeframe": Timeframe.daily.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": isDeleted,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int, col: Int, isLocked: Bool = false) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: row, col: col,
            isCenter: false, isLocked: isLocked, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1
        )
    }

    private func queuedUpdates(_ db: AppDatabase, entityId: String) throws -> Int {
        try db.dbQueue.read { database in
            try SyncQueueItem
                .filter(Column("entityType") == "boardTasks" && Column("entityId") == entityId)
                .fetchCount(database)
        }
    }

    /// Seeds user + one 3×3 board with two placements at (0,0) and (0,1).
    private func seedTwoCellBoard(_ db: AppDatabase, sealedAt: String? = nil, lockFirst: Bool = false) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", sealedAt: sealedAt))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0, isLocked: lockFirst))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))
    }

    // MARK: - Decode / encode / v34

    func test_decode_missingIsLockedKey_defaultsToFalse() throws {
        let json = """
        {"id":"bt","boardId":"b","taskId":"t","row":0,"col":0,"isCenter":false,
         "createdAt":"2026-07-01T00:00:00.000","updatedAt":"2026-07-01T00:00:00.000","version":1}
        """
        let bt = try JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        XCTAssertFalse(bt.isLocked, "pre-feature payload decodes as unlocked")
    }

    func test_decode_explicitIsLocked_roundTrips() throws {
        let bt = makeBoardTask(id: "bt", boardId: "b", taskId: "t", row: 0, col: 0, isLocked: true)
        let data = try JSONEncoder().encode(bt)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["isLocked"] as? Bool, true, "always encoded so peers receive the field")
        let back = try JSONDecoder().decode(BoardTask.self, from: data)
        XCTAssertTrue(back.isLocked)
    }

    func test_v34_columnExists_lockPersistsThroughGRDB() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db, lockFirst: true)
        let rows = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(rows.first { $0.id == "bt1" }?.isLocked, true)
        XCTAssertEqual(rows.first { $0.id == "bt2" }?.isLocked, false)
    }

    // MARK: - setBoardTaskLocked

    func test_setBoardTaskLocked_bumpsVersion_andEnqueuesSync() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db)

        try db.setBoardTaskLocked(boardTaskId: "bt1", locked: true)

        let row = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertTrue(row.isLocked)
        XCTAssertEqual(row.version, 2)
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt1"), 1)

        try db.setBoardTaskLocked(boardTaskId: "bt1", locked: false)
        let unlocked = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertFalse(unlocked.isLocked)
        XCTAssertEqual(unlocked.version, 3)
        // The sync queue keeps ONE pending row per entity (coalescing) — the
        // second write updates that row's payload rather than adding a second.
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt1"), 1)
        let payload = try db.dbQueue.read { database in
            try SyncQueueItem
                .filter(Column("entityType") == "boardTasks" && Column("entityId") == "bt1")
                .fetchOne(database)?.payload ?? ""
        }
        XCTAssertTrue(payload.contains("\"isLocked\":false"), "queued payload carries the latest lock state")
    }

    func test_setBoardTaskLocked_unchangedValue_isNoOp() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db)

        try db.setBoardTaskLocked(boardTaskId: "bt1", locked: false)

        let row = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertEqual(row.version, 1, "no write for an unchanged lock")
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt1"), 0)
    }

    func test_setBoardTaskLocked_sealedBoard_isNoOp() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db, sealedAt: sealed)

        try db.setBoardTaskLocked(boardTaskId: "bt1", locked: true)

        let row = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertFalse(row.isLocked, "a closed board's placements never mutate")
        XCTAssertEqual(row.version, 1)
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt1"), 0)
    }

    func test_setBoardTaskLocked_deletedRow_isNoOp() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db)
        try db.removeBoardTaskFromBoard("bt2")
        let before = try queuedUpdates(db, entityId: "bt2")

        try db.setBoardTaskLocked(boardTaskId: "bt2", locked: true)

        let row = try db.dbQueue.read { try BoardTask.fetchOne($0, key: "bt2") }
        XCTAssertEqual(row?.isLocked, false)
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt2"), before, "tombstoned row is not resurrected")
    }

    // MARK: - updateBoardTaskPositions guard

    func test_updateBoardTaskPositions_relocatingLockedRow_throws_nothingPartial() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db, lockFirst: true)

        // bt2 (unlocked) → (1,1) is fine on its own; bt1 (locked) → (2,2) is not.
        XCTAssertThrowsError(try db.updateBoardTaskPositions(
            boardId: "b1",
            moves: [
                AppDatabase.BoardTaskPositionMove(boardTaskId: "bt2", row: 1, col: 1),
                AppDatabase.BoardTaskPositionMove(boardTaskId: "bt1", row: 2, col: 2),
            ]
        )) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected invalidPlacement, got \(error)")
            }
        }

        // Nothing partial: the unlocked row did not move either.
        let bt2 = try XCTUnwrap(db.fetchBoardTask(id: "bt2"))
        XCTAssertEqual((bt2.row, bt2.col).0, 0)
        XCTAssertEqual(bt2.col, 1)
        XCTAssertEqual(bt2.version, 1)
        let bt1 = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertEqual(bt1.row, 0); XCTAssertEqual(bt1.col, 0)
        XCTAssertEqual(try queuedUpdates(db, entityId: "bt2"), 0)
    }

    func test_updateBoardTaskPositions_lockedRowAtSamePosition_isAccepted() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db, lockFirst: true)

        // A "move" that keeps the locked row where it is doesn't relocate it.
        try db.updateBoardTaskPositions(
            boardId: "b1",
            moves: [
                AppDatabase.BoardTaskPositionMove(boardTaskId: "bt1", row: 0, col: 0),
                AppDatabase.BoardTaskPositionMove(boardTaskId: "bt2", row: 2, col: 2),
            ]
        )
        let bt2 = try XCTUnwrap(db.fetchBoardTask(id: "bt2"))
        XCTAssertEqual(bt2.row, 2); XCTAssertEqual(bt2.col, 2)
    }

    func test_updateBoardTaskPositions_unlockedMove_isUnaffected() throws {
        let db = try makeDb()
        try seedTwoCellBoard(db)

        try db.updateBoardTaskPositions(
            boardId: "b1",
            moves: [AppDatabase.BoardTaskPositionMove(boardTaskId: "bt1", row: 2, col: 2)]
        )
        let bt1 = try XCTUnwrap(db.fetchBoardTask(id: "bt1"))
        XCTAssertEqual(bt1.row, 2); XCTAssertEqual(bt1.col, 2)
        XCTAssertEqual(bt1.version, 2)
    }
}
