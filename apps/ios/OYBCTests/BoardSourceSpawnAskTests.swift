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
        isDeleted: Bool = false,
        spawnedFromTemplateId: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws {
        var boardDict: [String: Any] = [
            "id": boardId, "userId": userId, "name": "Source \(boardId)",
            "status": status, "boardSize": 3, "timeframe": "daily",
            "startDate": startDate ?? now, "endDate": endDate ?? now,
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1,
            "isDeleted": isDeleted,
        ]
        if let spawnedFromTemplateId {
            boardDict["spawnedFromTemplateId"] = spawnedFromTemplateId
        }
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
    // MARK: - Counter-family exclusivity (2026-09-08)

    private func makeCountingTask(
        _ id: String, maxCount: Int, sharedCounterId: String? = nil
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Count \(id)", description: nil, type: .counting,
            action: "Do", unit: "reps", maxCount: maxCount,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            sharedCounterId: sharedCounterId,
            baseline: sharedCounterId != nil ? 0 : nil
        )
    }

    /// The iOS spawn call site must feed `buildCounterFamilyMap` into the
    /// shared pick — a counting root + its derived version in one mix
    /// place exactly ONE square (the vectors pin the algorithm; this pins
    /// the WIRING).
    func test_spawn_placesAtMostOneMemberOfASharedCounterFamily() throws {
        let db = try makeDb()
        try db.write { grdb in
            try makeCountingTask("fam-root", maxCount: 50).insert(grdb)
            try makeCountingTask("fam-derived", maxCount: 20, sharedCounterId: "fam-root")
                .insert(grdb)
        }
        // 2×2 NONE = 4 cells; family pair + 3 fillers = 4 placeable things.
        let template = try seedTemplate(
            db,
            sources: [],
            manualTaskIds: ["fam-root", "fam-derived", "f1", "f2", "f3"]
        )
        let outcome = try spawn(db, template)
        guard case .spawned(let boardId, _, _) = outcome else {
            return XCTFail("Expected a spawn, got \(outcome)")
        }
        let placedIds = try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb)
        }.map { $0.taskId }
        XCTAssertEqual(placedIds.count, 4)
        let famPlaced = placedIds.filter { $0 == "fam-root" || $0 == "fam-derived" }
        XCTAssertEqual(famPlaced.count, 1, "one square per shared-counter family")
        for id in ["f1", "f2", "f3"] {
            XCTAssertTrue(placedIds.contains(id), "filler \(id) must fill the freed cell")
        }
    }

    private func makeAchievementTask(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Watch \(id)", description: nil, type: .achievement,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            referencedBoardId: "some-other-board",
            achievementTrigger: .bingo,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// Achievements are banned from source supply (owner decision
    /// 2026-09-10) — a watcher in a pool AND on a pulled board never
    /// reaches the spawned board. Eligible supply (2 pool normals + 2
    /// board normals) = exactly the 2×2 NONE cell count, so the deal is
    /// deterministic and proves the ban holds at BOTH supply resolvers
    /// (`BoardSources.poolSourceSupplyById` and `AppDatabase.resolveSupply`),
    /// not just in the pickers. Web twin: the achievements-banned spawn
    /// test in `recurringBoardSpawnMix.test.ts`.
    func test_spawn_excludesAchievementsFromPoolAndBoardSupply() throws {
        let db = try makeDb()
        try seedBoard(db, boardId: "b-src", taskIds: ["bn1", "bn2"])
        try db.write { grdb in
            for id in ["pn1", "pn2"] { try makeTask(id).insert(grdb) }
            try makeAchievementTask("watch-pool").insert(grdb)
            try makeAchievementTask("watch-board").insert(grdb)
            try BoardTask(
                id: "bt-b-src-watch-board", boardId: "b-src", taskId: "watch-board",
                row: 0, col: 2, isCenter: false,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false
            ).insert(grdb)
            try Pool(
                id: "pool-w", userId: userId, name: "Pool With Watcher",
                taskIds: ["pn1", "pn2", "watch-pool"],
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                isDeleted: false, deletedAt: nil
            ).insert(grdb)
        }
        let template = try seedTemplate(
            db,
            sources: [
                BoardSource(sourceId: "pool-w", kind: .pool),
                BoardSource(sourceId: "b-src", kind: .board),
            ],
            manualTaskIds: []
        )
        let outcome = try spawn(db, template)
        guard case .spawned(let boardId, _, _) = outcome else {
            return XCTFail("Expected a spawn, got \(outcome)")
        }
        let placed = Set(try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb)
        }.map { $0.taskId })
        XCTAssertEqual(placed, ["pn1", "pn2", "bn1", "bn2"])
        XCTAssertFalse(placed.contains("watch-pool"))
        XCTAssertFalse(placed.contains("watch-board"))
    }

    // MARK: - Series binding (loose-ends sweep 2026-09-09)

    /// A pull stored against an ARCHIVED old window hops to the series'
    /// live instance — the spawn pulls the NEW window's squares and never
    /// asks. Web twin: the series-binding spawn tests in
    /// `recurringBoardSpawnMix.test.ts`.
    func test_archivedSeriesInstance_hopsToLiveSibling() throws {
        let db = try makeDb()
        try seedBoard(
            db, boardId: "inst-old", taskIds: ["o1", "o2"],
            status: "archived", spawnedFromTemplateId: "series-1",
            startDate: "2026-08-28T00:00:00.000Z", endDate: "2026-08-28T23:59:59.999Z"
        )
        try seedBoard(
            db, boardId: "inst-live", taskIds: ["n1", "n2", "n3", "n4"],
            spawnedFromTemplateId: "series-1",
            startDate: now, endDate: "2026-09-04T23:59:59.999Z"
        )
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "inst-old", kind: .board)],
            manualTaskIds: []
        )
        let outcome = try spawn(db, template)
        guard case .spawned(let boardId, _, _) = outcome else {
            return XCTFail("Expected a spawn, got \(outcome)")
        }
        let placed = Set(try db.read { grdb in
            try BoardTask.filter(Column("boardId") == boardId).fetchAll(grdb)
        }.map { $0.taskId })
        XCTAssertEqual(placed, ["n1", "n2", "n3", "n4"])
    }

    /// A series with NO live instance still asks — the hop has nowhere
    /// to land.
    func test_seriesWithNoLiveInstance_stillAsks() throws {
        let db = try makeDb()
        try seedBoard(
            db, boardId: "inst-a", taskIds: ["o1"],
            status: "archived", spawnedFromTemplateId: "series-dead"
        )
        try seedBoard(
            db, boardId: "inst-b", taskIds: ["o1"],
            status: "archived", spawnedFromTemplateId: "series-dead",
            startDate: "2026-08-01T00:00:00.000Z"
        )
        let template = try seedTemplate(
            db,
            sources: [BoardSource(sourceId: "inst-a", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3", "m4"]
        )
        let outcome = try spawn(db, template)
        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("Expected a skip, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceBoardMissing)
    }

}
