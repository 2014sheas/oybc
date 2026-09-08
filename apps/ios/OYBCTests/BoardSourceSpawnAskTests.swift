import GRDB
import XCTest
@testable import OYBC

/// Board Sources P3 — the deleted-source spawn ask (docs/BOARD_SOURCES.md
/// §Boards as sources): a repeating board pulling from a DELETED or
/// ARCHIVED board skips its window with `.sourceBoardMissing` (the
/// Boards-tab prompt's trigger), while a LIVE source board spawns
/// normally and an EMPTY-but-live one contributes nothing without
/// blocking. Also covers `removeMissingBoardSources` (the ask's "Remove
/// that source" action). Web mirror: the `source_board_missing` cases in
/// `recurringBoardSpawnMix.test.ts`.
final class BoardSourceSpawnAskTests: XCTestCase {

    private let userId = "u1"
    private let now = "2026-09-04T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.write { grdb in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).insert(grdb)
        }
        return db
    }

    private func makeTask(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func seedBoard(
        _ db: AppDatabase,
        boardId: String,
        taskIds: [String],
        status: String = "active",
        isDeleted: Bool = false
    ) throws {
        let boardDict: [String: Any] = [
            "id": boardId, "userId": userId, "name": "Source \(boardId)",
            "status": status, "boardSize": 3, "timeframe": "daily",
            "startDate": now, "endDate": now,
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1,
            "isDeleted": isDeleted,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: boardDict)
        )
        try db.write { grdb in
            try board.insert(grdb)
            for (i, taskId) in taskIds.enumerated() {
                if try OYBC.Task.fetchOne(grdb, key: taskId) == nil {
                    try makeTask(taskId).insert(grdb)
                }
                try BoardTask(
                    id: "bt-\(boardId)-\(taskId)", boardId: boardId, taskId: taskId,
                    row: i / 3, col: i % 3, isCenter: false,
                    createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
    }

    /// 2×2 NONE template (4 fillable cells) pulling `sources`, with enough
    /// manual tasks to fill regardless — isolates the ask from
    /// pool-too-small skips.
    private func seedTemplate(
        _ db: AppDatabase,
        sources: [BoardSource],
        manualTaskIds: [String]
    ) throws -> RecurringBoardTemplate {
        let template = RecurringBoardTemplate(
            id: "tpl-ask", userId: userId, name: "Ask Board",
            timeframe: .daily, boardSize: 2, centerSquareType: .none,
            isRandomized: true, seedTaskIds: [],
            manualTaskIds: manualTaskIds, sources: sources,
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in
            for id in manualTaskIds {
                if try OYBC.Task.fetchOne(grdb, key: id) == nil {
                    try makeTask(id).insert(grdb)
                }
            }
            try template.insert(grdb)
        }
        return template
    }

    private func spawn(
        _ db: AppDatabase, _ template: RecurringBoardTemplate
    ) throws -> RecurringSpawnOutcome {
        try db.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: template,
                windowStart: now,
                windowEnd: "2026-09-04T23:59:59.999Z",
                suggestedName: "Ask Board — Sep 4"
            ),
            boardId: "spawned-1",
            now: now
        )
    }

    func test_deletedSourceBoard_skipsWithSourceBoardMissing() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-gone", taskIds: ["s1", "s2"], isDeleted: true)
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "b-gone", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )
        let outcome = try spawn(db, template)
        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("Expected a skip, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceBoardMissing)
    }

    func test_archivedSourceBoard_skipsWithSourceBoardMissing() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-arch", taskIds: ["s1"], status: "archived")
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "b-arch", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )
        let outcome = try spawn(db, template)
        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("Expected a skip, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceBoardMissing)
    }

    func test_missingSourceBoardRow_skipsWithSourceBoardMissing() throws {
        let db = try makeDb()
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "never-existed", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )
        let outcome = try spawn(db, template)
        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("Expected a skip, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceBoardMissing)
    }

    func test_liveSourceBoard_spawnsAndPullsItsSquares() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-live", taskIds: ["s1", "s2", "s3", "s4"])
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "b-live", kind: .board)],
            manualTaskIds: []
        )
        let outcome = try spawn(db, template)
        guard case .spawned(let boardId, _, _) = outcome else {
            return XCTFail("Expected a spawn, got \(outcome)")
        }
        let rows = try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb)
        }
        XCTAssertEqual(Set(rows.map { $0.taskId }), ["s1", "s2", "s3", "s4"])
    }

    func test_removeMissingBoardSources_dropsDeadEntryAndMirrors() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-gone", taskIds: ["s1"], isDeleted: true)
        var deadSource = BoardSource(sourceId: "b-gone", kind: .board)
        deadSource.excludedTaskIds = ["s1"]
        let poolSource = BoardSource(sourceId: "pool-1", kind: .pool)
        let template = try seedTemplate(
            db,
            sources: [poolSource, deadSource],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )

        let changed = try db.removeMissingBoardSources(templateId: template.id, now: now)
        XCTAssertTrue(changed)

        let updated = try XCTUnwrap(db.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertEqual(updated.sources?.map { $0.sourceId }, ["pool-1"])
        // The P1 dual-write mirrors follow the new shape.
        XCTAssertEqual(updated.poolIds, ["pool-1"])
        XCTAssertEqual(updated.removedTaskIds, [])
        XCTAssertEqual(updated.version, template.version + 1)

        // The spawn now proceeds (manual layer fills the 2×2).
        let outcome = try spawn(db, updated)
        guard case .spawned = outcome else {
            return XCTFail("Expected a spawn after removal, got \(outcome)")
        }
    }

    func test_removeMissingBoardSources_keepsLiveBoardSource() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-live", taskIds: ["s1"])
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "b-live", kind: .board)],
            manualTaskIds: ["m1"]
        )
        let changed = try db.removeMissingBoardSources(templateId: template.id, now: now)
        XCTAssertFalse(changed)
        let updated = try XCTUnwrap(db.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertEqual(updated.sources?.map { $0.sourceId }, ["b-live"])
        XCTAssertEqual(updated.version, template.version)
    }

    /// The empty-source rule (docs/BOARD_SOURCES.md §Boards as sources):
    /// a LIVE board whose entire supply is excluded contributes nothing
    /// and never blocks — the window fills from the manual layer. iOS
    /// mirror of the web spawn-mix test of the same name (review-caught
    /// coverage asymmetry).
    func test_liveBoardWithEverythingExcluded_contributesNothingNeverBlocks() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-live", taskIds: ["s1"])
        var emptySource = BoardSource(sourceId: "b-live", kind: .board)
        emptySource.excludedTaskIds = ["s1"]
        let template = try seedTemplate(
            db,
            sources: [emptySource],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )
        let outcome = try spawn(db, template)
        guard case .spawned(let boardId, _, _) = outcome else {
            return XCTFail("Expected a spawn, got \(outcome)")
        }
        let rows = try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb)
        }
        XCTAssertEqual(Set(rows.map { $0.taskId }), ["m1", "m2", "m3", "m4"])
        XCTAssertFalse(rows.contains { $0.taskId == "s1" })
    }
}
