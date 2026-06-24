import XCTest
import GRDB
@testable import OYBC

/// Tests for indefinite (ongoing, no end date) boards on iOS:
///   1. The v18 boards-table rebuild leaves a schema that accepts a NULL
///      `endDate`, and the rebuilt table keeps its indexes.
///   2. `Board` Codable round-trips an absent endDate (nil) through GRDB.
///   3. `Board.isIndefinite` reflects the model invariant.
///
/// `AppDatabase.makeTestInstance()` runs every migration (v1…v18) on a fresh
/// in-memory database, so constructing one exercises the v18 rebuild path.
final class IndefiniteBoardTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        return try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ database: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id,
            email: "test@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
        try database.saveUser(user)
    }

    /// Build a Board via JSON (the same path production uses). Omit `endDate`
    /// to model an indefinite board.
    private func makeBoard(
        id: String,
        timeframe: Timeframe,
        endDate: String?
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": "u1",
            "name": "Ongoing",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": timeframe.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000",
            "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        if let endDate { dict["endDate"] = endDate }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - v18 schema / persistence

    func testIndefiniteBoardPersistsWithNullEndDate() throws {
        let db = try makeDatabase()
        try seedUser(db)

        let board = makeBoard(id: "indef-1", timeframe: .indefinite, endDate: nil)
        XCTAssertNil(board.endDate)
        XCTAssertTrue(board.isIndefinite)

        try db.saveBoard(board)

        let fetched = try XCTUnwrap(try db.fetchBoard(id: "indef-1"))
        XCTAssertNil(fetched.endDate, "endDate should round-trip as NULL after the v18 rebuild")
        XCTAssertEqual(fetched.timeframe, .indefinite)
        XCTAssertTrue(fetched.isIndefinite)
    }

    func testBoundedBoardStillRoundTripsEndDate() throws {
        let db = try makeDatabase()
        try seedUser(db)

        let board = makeBoard(
            id: "bounded-1",
            timeframe: .monthly,
            endDate: "2026-06-30T23:59:59.999"
        )
        XCTAssertFalse(board.isIndefinite)

        try db.saveBoard(board)

        let fetched = try XCTUnwrap(try db.fetchBoard(id: "bounded-1"))
        XCTAssertEqual(fetched.endDate, "2026-06-30T23:59:59.999")
        XCTAssertFalse(fetched.isIndefinite)
    }

    /// The rebuild recreates the boards table; confirm its indexes survived.
    func testRebuiltBoardsTableKeepsIndexes() throws {
        let db = try makeDatabase()
        let indexNames: [String] = try db.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='boards'"
            )
        }
        for expected in [
            "idx_boards_user_deleted",
            "idx_boards_user_timeframe_status",
            "idx_boards_user_timeframe_lines",
            "idx_boards_updated",
            "idx_boards_status",
        ] {
            XCTAssertTrue(indexNames.contains(expected), "missing index \(expected) after v18 rebuild")
        }
    }

    // MARK: - isIndefinite invariant

    func testIsIndefiniteByTimeframeEvenWithStrayEndDate() {
        let board = makeBoard(
            id: "stray",
            timeframe: .indefinite,
            endDate: "2026-06-30T23:59:59.999"
        )
        XCTAssertTrue(board.isIndefinite, "timeframe == .indefinite wins regardless of endDate")
    }

    func testNotIndefiniteForNormalBoard() {
        let board = makeBoard(id: "daily", timeframe: .daily, endDate: "2026-06-21T23:59:59.999")
        XCTAssertFalse(board.isIndefinite)
    }
}
