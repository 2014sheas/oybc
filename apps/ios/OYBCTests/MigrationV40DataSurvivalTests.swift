import XCTest
import GRDB
@testable import OYBC

/// v39 → v40 data survival: v40 rebuilds `boards` without the
/// `centerTaskId REFERENCES tasks(id)` foreign key (plus adds the local-only
/// `sync_watermarks` table). Seeds a database migrated only to v39, migrates
/// it to v40 and checks nothing was lost or changed — and that the one
/// intended behaviour change (a dangling `centerTaskId` is accepted) holds,
/// with the v39 schema as the positive control.
final class MigrationV40DataSurvivalTests: XCTestCase {

    private let userId = "u1"
    private let start = "2026-07-01T00:00:00.000Z"
    private let boardIds = (0..<3).map { PullFixture.uuid(1, $0) }
    private var sealedId: String { boardIds[1] }
    private var centreBoardId: String { boardIds[2] }
    private var centreTaskId: String { PullFixture.uuid(2, 4) }

    /// A queue with production's FK pragma, migrated to `upTo` with the real migrator.
    private func makeQueue(upTo migration: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.makeTestInstance().migrator.migrate(queue, upTo: migration)
        return queue
    }

    private func boardRow(_ id: String, extra: [String: Any] = [:]) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": "active", "boardSize": 3,
            "timeframe": Timeframe.daily.rawValue, "startDate": start, "endDate": "2099-12-31T23:59:59.999Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 2, "linesCompleted": 0,
            "createdAt": start, "updatedAt": "2026-07-0\(boardIds.firstIndex(of: id)! + 2)T08:00:00.000Z",
            "version": 10 + boardIds.firstIndex(of: id)!, "isDeleted": false,
        ]
        for (k, v) in extra { dict[k] = v }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// Inserts a task with raw SQL naming only columns the v39 schema has —
    /// the seed runs against a database migrated to v39, so the current
    /// `Task` Codable (which carries columns added later, e.g. v41's
    /// `forkedFromTaskId`) cannot be used to write it.
    private func insertTask(_ id: String, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO tasks (id, userId, title, type, totalCompletions, totalInstances,
                               isCompleted, createdAt, updatedAt, version, isDeleted)
            VALUES (?, ?, 'T', 'normal', 0, 0, 0, ?, ?, 1, 0)
            """, arguments: [id, userId, start, start])
    }

    /// Seeds 3 boards × 9 placed tasks — board 1 SEALED (`sealedAt` +
    /// `sealedCompletedCells`), board 2 with a chosen `centerTaskId` whose task
    /// is present — plus a user and two task events.
    private func seed(_ db: Database) throws {
        try User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        ).save(db)
        for (b, boardId) in boardIds.enumerated() {
            var extra: [String: Any] = [:]
            if boardId == sealedId {
                extra = ["sealedAt": "2026-07-06T00:00:00.000Z", "sealedCompletedCells": "[0,4]", "endDate": "2026-07-05T23:59:59.999Z"]
            }
            if boardId == centreBoardId {
                extra = ["centerSquareType": CenterSquareType.chosen.rawValue, "centerTaskId": centreTaskId]
            }
            let taskIds = (0..<9).map { cell in b == 2 && cell == 4 ? centreTaskId : PullFixture.uuid(2, 100 + b * 9 + cell) }
            for taskId in taskIds { try insertTask(taskId, db) } // before the board: v39's centre FK is immediate
            try boardRow(boardId, extra: extra).save(db)
            for (cell, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: PullFixture.uuid(3, b * 9 + cell), boardId: boardId, taskId: taskId,
                    row: cell / 3, col: cell % 3, isCenter: b == 2 && cell == 4,
                    createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
                ).save(db)
            }
        }
        for n in 0..<2 {
            try TaskEvent(
                id: PullFixture.uuid(4, n), userId: userId, taskId: PullFixture.uuid(2, 100 + n), kind: .completion, delta: nil,
                occurredAt: "2026-07-02T12:00:00.000Z", boardId: nil, createdAt: start, updatedAt: start,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
    }

    private func tableCounts(_ db: Database) throws -> [String: Int] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%' AND name NOT IN ('grdb_migrations')
            """)
        var out: [String: Int] = [:]
        for t in tables { out[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(t)\"") ?? -1 }
        return out
    }

    private func boardSnapshot(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT id, sealedAt, sealedCompletedCells, centerTaskId, centerSquareType, version, updatedAt,
                   completedTasks, name, userId FROM boards ORDER BY id
            """).map { $0.description }
    }

    func test_v39ToV40_keepsEveryRowAndValue_andTheBoardIndexesAndCascade() throws {
        let queue = try makeQueue(upTo: "v39")
        try queue.write(seed)
        let (countsBefore, boardsBefore, btBefore) = try queue.read { db in
            (try tableCounts(db), try boardSnapshot(db),
             try Row.fetchAll(db, sql: "SELECT * FROM board_tasks ORDER BY id").map(\.description))
        }
        XCTAssertEqual(countsBefore["boards"], 3)
        XCTAssertEqual(countsBefore["board_tasks"], 27)
        XCTAssertTrue(try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(boards)").contains { ($0["from"] as String?) == "centerTaskId" }
        }, "precondition: v39 still has the centre FK")

        try AppDatabase.makeTestInstance().migrator.migrate(queue) // → v40

        try queue.read { db in
            let after = try tableCounts(db)
            for (table, count) in countsBefore {
                XCTAssertEqual(after[table], count, "row count changed for \(table)")
            }
            XCTAssertEqual(after["sync_watermarks"], 0)
            XCTAssertEqual(try boardSnapshot(db), boardsBefore, "a board value changed")
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM board_tasks ORDER BY id").map(\.description), btBefore)
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'boards' AND sql IS NOT NULL")
            XCTAssertEqual(Set(indexes), [
                "idx_boards_user_deleted", "idx_boards_user_timeframe_status",
                "idx_boards_user_timeframe_lines", "idx_boards_updated", "idx_boards_status",
            ])
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        // The typed models still decode the rebuilt rows.
        let sealed = try XCTUnwrap(try queue.read { try Board.fetchOne($0, key: self.sealedId) })
        XCTAssertEqual(sealed.sealedCompletedCells, [0, 4])
        XCTAssertEqual(try queue.read { try Board.fetchOne($0, key: self.centreBoardId) }?.centerTaskId, centreTaskId)

        // FKs ON: deleting a board still cascade-deletes its placements.
        try queue.write { try $0.execute(sql: "DELETE FROM boards WHERE id = ?", arguments: [self.boardIds[0]]) }
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM board_tasks WHERE boardId = ?", arguments: [self.boardIds[0]]) }, 0)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM board_tasks") }, 18)
    }

    func test_danglingCentreTask_rejectedUnderV39_acceptedUnderV40() throws {
        let dangling = try boardRow(boardIds[0], extra: [
            "centerSquareType": CenterSquareType.chosen.rawValue, "centerTaskId": PullFixture.uuid(2, 9999),
        ])
        let user = User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        )

        let v39 = try makeQueue(upTo: "v39")
        try v39.write { try user.save($0) }
        XCTAssertThrowsError(try v39.write { try dangling.insert($0) }, "positive control: v39's FK rejects it")

        let v40 = try makeQueue(upTo: "v40")
        try v40.write { try user.save($0) }
        XCTAssertNoThrow(try v40.write { try dangling.insert($0) })
        XCTAssertEqual(try v40.read { try Board.fetchOne($0, key: self.boardIds[0]) }?.centerTaskId, PullFixture.uuid(2, 9999))
    }

    func test_rebuildRefusesToRunWithForeignKeysOn() throws {
        let queue = try makeQueue(upTo: "v39")
        try queue.write(seed)
        // Outside the migrator FKs are ON — the rebuild must refuse, not
        // cascade-delete the placements.
        XCTAssertThrowsError(try queue.write { try AppDatabase.dropBoardsCenterTaskForeignKey($0) })
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM board_tasks") }, 27)
    }
}
