import XCTest
import GRDB
@testable import OYBC

/// Board Edit slice 3 (D2) — `normalizeLegacyChosenCenter(db:boardId:keepLocked:)`,
/// the one-time AUTHORED conversion of a legacy CHOSEN board that the squares
/// Save runs inside its transaction: board → NONE + no `centerTaskId`, the
/// positional-center placement → `isLocked = keepLocked, isCenter = false`,
/// each with a version bump + one sync-queue row. Same case table as web
/// `db/operations/__tests__/legacyChosenCenter.test.ts`.
final class LegacyChosenCenterTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000"
    private let end = "2026-07-01T23:59:59.999"

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

    private func makeBoard(center: CenterSquareType, centerTaskId: String?, sealedAt: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": userId, "name": "B", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": center.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let centerTaskId { dict["centerTaskId"] = centerTaskId }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, taskId: String, row: Int, col: Int, isCenter: Bool) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: "b1", taskId: taskId, row: row, col: col,
            isCenter: isCenter, isLocked: false, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1
        )
    }

    /// 3×3 board with a center placement (1,1) and a corner placement (0,0).
    private func seed(_ db: AppDatabase, center: CenterSquareType, sealedAt: String? = nil) throws {
        try seedUser(db)
        try db.saveTask(makeTask("tc"))
        try db.saveTask(makeTask("t0"))
        try db.saveBoard(makeBoard(center: center, centerTaskId: center == .chosen ? "tc" : nil, sealedAt: sealedAt))
        try db.saveBoardTask(makeBoardTask(id: "btc", taskId: "tc", row: 1, col: 1, isCenter: center == .chosen))
        try db.saveBoardTask(makeBoardTask(id: "bt0", taskId: "t0", row: 0, col: 0, isCenter: false))
    }

    private func queueCount(_ db: AppDatabase) throws -> Int {
        try db.dbQueue.read { try SyncQueueItem.fetchCount($0) }
    }

    private func normalize(_ db: AppDatabase, keepLocked: Bool) throws {
        try db.dbQueue.write { database in
            try AppDatabase.normalizeLegacyChosenCenter(db: database, boardId: "b1", keepLocked: keepLocked)
        }
    }

    func test_chosen_convertsBoardAndCenterPlacement_withVersionBumps_andTwoQueueRows() throws {
        let db = try makeDb()
        try seed(db, center: .chosen)
        let before = try queueCount(db)

        try normalize(db, keepLocked: true)

        let board = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(board.centerSquareType, .none)
        XCTAssertNil(board.centerTaskId)
        XCTAssertEqual(board.version, 2)
        let center = try XCTUnwrap(db.fetchBoardTask(id: "btc"))
        XCTAssertTrue(center.isLocked)
        XCTAssertFalse(center.isCenter)
        XCTAssertEqual(center.version, 2)
        let corner = try XCTUnwrap(db.fetchBoardTask(id: "bt0"))
        XCTAssertEqual(corner.version, 1, "non-center placements are untouched")
        XCTAssertFalse(corner.isLocked)
        XCTAssertEqual(try queueCount(db) - before, 2)
        let entities = try db.dbQueue.read { database in
            try SyncQueueItem.fetchAll(database).map { "\($0.entityType):\($0.entityId)" }
        }
        XCTAssertTrue(entities.contains("boards:b1"))
        XCTAssertTrue(entities.contains("boardTasks:btc"))
    }

    func test_keepLockedFalse_leavesCenterUnlocked() throws {
        let db = try makeDb()
        try seed(db, center: .chosen)
        let before = try queueCount(db)

        try normalize(db, keepLocked: false)

        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).centerSquareType, .none)
        let center = try XCTUnwrap(db.fetchBoardTask(id: "btc"))
        XCTAssertFalse(center.isLocked)
        XCTAssertFalse(center.isCenter)
        XCTAssertEqual(center.version, 2)
        XCTAssertEqual(try queueCount(db) - before, 2)
    }

    func test_noOp_onNoneAndFree() throws {
        for type in [CenterSquareType.none, .free] {
            let db = try makeDb()
            try seed(db, center: type)
            let before = try queueCount(db)

            try normalize(db, keepLocked: true)

            let board = try XCTUnwrap(db.fetchBoard(id: "b1"))
            XCTAssertEqual(board.centerSquareType, type)
            XCTAssertEqual(board.version, 1, "\(type): board untouched")
            XCTAssertEqual(try XCTUnwrap(db.fetchBoardTask(id: "btc")).version, 1, "\(type): center untouched")
            XCTAssertEqual(try queueCount(db), before, "\(type): nothing enqueued")
        }
    }

    func test_sealed_throwsBoardNotEditable_andWritesNothing() throws {
        let db = try makeDb()
        try seed(db, center: .chosen, sealedAt: "2026-07-02T07:00:00.000Z")
        let before = try queueCount(db)

        XCTAssertThrowsError(try normalize(db, keepLocked: true)) { error in
            XCTAssertEqual(error as? BoardEditError, .boardNotEditable)
        }

        let board = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(board.centerSquareType, .chosen)
        XCTAssertEqual(board.centerTaskId, "tc")
        XCTAssertEqual(board.version, 1)
        let center = try XCTUnwrap(db.fetchBoardTask(id: "btc"))
        XCTAssertTrue(center.isCenter)
        XCTAssertFalse(center.isLocked)
        XCTAssertEqual(try queueCount(db), before)
    }

    func test_chosenWithoutCenterPlacement_convertsBoardOnly() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeTask("tc"))
        try db.saveTask(makeTask("t0"))
        try db.saveBoard(makeBoard(center: .chosen, centerTaskId: "tc"))
        try db.saveBoardTask(makeBoardTask(id: "bt0", taskId: "t0", row: 0, col: 0, isCenter: false))
        let before = try queueCount(db)

        try normalize(db, keepLocked: true)

        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).centerSquareType, .none)
        XCTAssertEqual(try XCTUnwrap(db.fetchBoardTask(id: "bt0")).version, 1)
        XCTAssertEqual(try queueCount(db) - before, 1)
    }

    // MARK: - addBoardTaskToBoard(db:...isLocked:)

    func test_dbThreadedAdd_placesLockedRow_insideCallerTransaction() throws {
        let db = try makeDb()
        try seed(db, center: .none)
        try db.saveTask(makeTask("tn"))

        let added = try db.dbQueue.write { database in
            try AppDatabase.addBoardTaskToBoard(
                db: database, boardId: "b1", taskId: "tn", position: (row: 2, col: 2), isLocked: true
            )
        }

        let row = try XCTUnwrap(db.fetchBoardTask(id: added.id))
        XCTAssertTrue(row.isLocked)
        XCTAssertFalse(row.isCenter)
        XCTAssertEqual(row.row, 2)
        XCTAssertEqual(row.col, 2)
    }

    func test_instanceAdd_stillDefaultsUnlocked() throws {
        let db = try makeDb()
        try seed(db, center: .none)
        try db.saveTask(makeTask("tn"))
        let added = try db.addBoardTaskToBoard("b1", taskId: "tn", position: (row: 2, col: 2))
        XCTAssertFalse(try XCTUnwrap(db.fetchBoardTask(id: added.id)).isLocked)
    }
}
