import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 (D1): `Board.reopenedAt` decode / encode and
/// the GRDB v35 column.
@MainActor
final class BoardReopenedAtTests: XCTestCase {

    private let ts = "2026-09-15T00:00:00.000Z"

    private func boardJSON(reopenedAt: String?) -> [String: Any] {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "B", "status": "active",
            "boardSize": 3, "timeframe": "daily", "startDate": "2026-09-15T00:00:00.000",
            "endDate": "2026-09-15T23:59:59.999",
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": false,
        ]
        if let reopenedAt { dict["reopenedAt"] = reopenedAt }
        return dict
    }

    private func decode(_ dict: [String: Any]) throws -> Board {
        try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func test_decode_presentReopenedAt() throws {
        let board = try decode(boardJSON(reopenedAt: "2026-09-18T08:00:00.000Z"))
        XCTAssertEqual(board.reopenedAt, "2026-09-18T08:00:00.000Z")
    }

    func test_decode_absentReopenedAt_isNil() throws {
        XCTAssertNil(try decode(boardJSON(reopenedAt: nil)).reopenedAt)
    }

    func test_encode_omitsNilAndRoundTripsValue() throws {
        let absent = try decode(boardJSON(reopenedAt: nil))
        let absentObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(absent)) as? [String: Any]
        )
        XCTAssertNil(absentObj["reopenedAt"])

        let present = try decode(boardJSON(reopenedAt: "2026-09-18T08:00:00.000Z"))
        let back = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(present))
        XCTAssertEqual(back.reopenedAt, "2026-09-18T08:00:00.000Z")
    }

    func test_v35_columnExists_andPersistsThroughGRDB() throws {
        let db = try AppDatabase.makeTestInstance()
        let columns = try db.read { try $0.columns(in: "boards").map(\.name) }
        XCTAssertTrue(columns.contains("reopenedAt"))

        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        try db.saveBoard(try decode(boardJSON(reopenedAt: "2026-09-18T08:00:00.000Z")))
        XCTAssertEqual(try db.fetchBoard(id: "b1")?.reopenedAt, "2026-09-18T08:00:00.000Z")
    }
}
