import XCTest
import GRDB
import FirebaseFirestore
@testable import OYBC

/// Board Edit redesign slice 4 (D2) — `SyncService+ClearableFields.swift`.
/// A Reopen clears `sealedAt` / `sealedCompletedCells` locally; these tests
/// pin that the push side stamps `FieldValue.delete()` for every absent
/// clearable field, and the pull side NULLs the local column when a winning
/// remote doc omits it — the same carve-out `endDate` / `completedAt` already
/// had, now centralized and extended to all four fields.
@MainActor
final class SyncClearableFieldsTests: XCTestCase {

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    // MARK: - Push: FieldValue.delete() for every absent clearable field

    func test_applyClearableBoardFieldDeletes_stampsDeleteForEveryAbsentField() {
        var cleaned: [String: Any] = ["id": "b1", "name": "Board"] // sealedAt etc. all absent
        SyncService.applyClearableBoardFieldDeletes(collection: "boards", cleaned: &cleaned)

        for field in clearableBoardFields {
            XCTAssertTrue(cleaned[field] is FieldValue, "\(field) must be stamped FieldValue.delete() when absent")
        }
        XCTAssertEqual(cleaned["name"] as? String, "Board", "present fields are untouched")
    }

    func test_applyClearableBoardFieldDeletes_leavesPresentFieldsAlone() {
        var cleaned: [String: Any] = ["id": "b1", "sealedAt": "2026-07-09T00:00:00.000Z"]
        SyncService.applyClearableBoardFieldDeletes(collection: "boards", cleaned: &cleaned)

        XCTAssertEqual(cleaned["sealedAt"] as? String, "2026-07-09T00:00:00.000Z", "a PRESENT clearable field must not be deleted")
        XCTAssertTrue(cleaned["endDate"] is FieldValue, "an absent one still gets the delete stamp")
    }

    func test_applyClearableBoardFieldDeletes_noOpForNonBoardsCollection() {
        var cleaned: [String: Any] = ["id": "t1"]
        SyncService.applyClearableBoardFieldDeletes(collection: "tasks", cleaned: &cleaned)
        for field in clearableBoardFields {
            XCTAssertNil(cleaned[field], "non-boards collections must never get the boards-only carve-out")
        }
    }

    // MARK: - Pull: NULL every clearable field absent from a winning remote doc

    private func makeSealedBoard(id: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "B", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.daily.rawValue,
            "startDate": "2026-07-01T00:00:00.000Z", "endDate": "2026-07-02T00:00:00.000Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-01T00:00:00.000Z",
            "completedAt": "2026-07-05T00:00:00.000Z",
            "version": 1, "isDeleted": false,
            "sealedAt": "2026-07-09T00:00:00.000Z", "sealedCompletedCells": "[0]",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func test_applyClearableBoardFieldNulls_clearsAbsentFieldsOnLocalRow() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeSealedBoard(id: "b1"))

        // A winning remote doc that omits ALL four clearable fields (mirrors
        // a Reopen's push, which deletes them) — every one must NULL locally.
        try db.write { conn in
            try SyncService.applyClearableBoardFieldNulls(db: conn, grdbTable: "boards", cleaned: ["id": "b1"])
        }

        let board = try db.fetchBoard(id: "b1")!
        XCTAssertNil(board.endDate)
        XCTAssertNil(board.completedAt)
        XCTAssertNil(board.sealedAt)
        XCTAssertNil(board.sealedCompletedCells)
    }

    func test_applyClearableBoardFieldNulls_leavesPresentFieldsAlone() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(makeSealedBoard(id: "b1"))

        // The remote doc carries a present sealedAt (a re-close after a
        // reopen) — this must survive, not be NULLed.
        try db.write { conn in
            try SyncService.applyClearableBoardFieldNulls(
                db: conn, grdbTable: "boards", cleaned: ["id": "b1", "sealedAt": "2026-07-20T00:00:00.000Z"]
            )
        }

        XCTAssertEqual(try db.fetchBoard(id: "b1")?.sealedAt, "2026-07-09T00:00:00.000Z", "raw SQL NULL-out only touches ABSENT fields")
    }

    func test_applyClearableBoardFieldNulls_noOpForNonBoardsTable() throws {
        let db = try AppDatabase.makeTestInstance()
        // Should not throw / touch anything for a non-boards table.
        try db.write { conn in
            try SyncService.applyClearableBoardFieldNulls(db: conn, grdbTable: "tasks", cleaned: ["id": "t1"])
        }
    }
}
