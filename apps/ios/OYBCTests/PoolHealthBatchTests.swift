import GRDB
import XCTest
@testable import OYBC

/// 2026-09 audit T2 — the pool-health "Short on N boards" warning used to
/// decide a repeating board's supply from its `poolIds` mirror through
/// `PoolMix.resolveMix`, which sees no board-kind sources and no ranges.
/// These cases run the REAL resolution the Pools surfaces now use
/// (`RecurringBoardTemplatesViewModel.resolveAchievableTaskIds` →
/// `AppDatabase.fetchTemplateSupplyResolution` → `computeRosterHealth`)
/// against a test database, on the two shapes the old read got wrong.
/// Web mirror: `apps/web/src/components/pools/__tests__/poolHealthBatch.test.ts`
/// (the "sources-native resolution (DB)" block).
final class PoolHealthBatchTests: XCTestCase {

    private let userId = "u1"
    private let now = "2026-09-01T00:00:00.000"

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

    private func insertTasks(_ db: AppDatabase, _ ids: [String]) throws {
        try db.write { grdb in
            for id in ids { try makeTask(id).insert(grdb) }
        }
    }

    /// An ACTIVE one-off source board with `taskIds` placed row-major.
    private func seedSourceBoard(_ db: AppDatabase, id: String, taskIds: [String]) throws {
        try insertTasks(db, taskIds)
        let board = try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "userId": userId, "name": "Source \(id)",
            "status": "active", "boardSize": 3, "timeframe": "custom",
            "startDate": now, "endDate": "2099-12-31T23:59:59.999",
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ] as [String: Any]))
        try db.write { grdb in
            try board.insert(grdb)
            for (i, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(taskId)", boardId: id, taskId: taskId,
                    row: i / 3, col: i % 3, isCenter: false,
                    createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
    }

    private func seedPool(_ db: AppDatabase, id: String, taskIds: [String]) throws -> Pool {
        try insertTasks(db, taskIds)
        let pool = Pool(
            id: id, userId: userId, name: "Pool \(id)", taskIds: taskIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
        return pool
    }

    /// A 3×3 FREE-center repeating board (8 fillable cells) whose legacy
    /// mirror is what the wizard's dual-write produces: `poolIds` lists
    /// pool-kind sources only.
    private func template(name: String = "Repeating", sources: [BoardSource]) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: "tpl", userId: userId, name: name,
            timeframe: .weekly, boardSize: 3, centerSquareType: .free,
            isRandomized: true, seedTaskIds: [],
            poolIds: sources.filter { $0.kind == .pool }.map { $0.sourceId },
            manualTaskIds: [], removedTaskIds: [],
            sources: sources,
            isActive: true, createdAt: now, updatedAt: now
        )
    }

    private func tasksById(_ db: AppDatabase) throws -> [String: OYBC.Task] {
        Dictionary(uniqueKeysWithValues: try db.fetchTasks(userId: userId).map { ($0.id, $0) })
    }

    /// Exactly what the Tasks-tab Pools segment computes.
    private func health(
        _ db: AppDatabase, pools: [Pool], templates: [RecurringBoardTemplate]
    ) throws -> [String: PoolHealth.Result] {
        let byId = try tasksById(db)
        let achievable = try RecurringBoardTemplatesViewModel.resolveAchievableTaskIds(
            templates: templates, tasksById: byId, database: db
        )
        return PoolHealth.computePoolHealthByPoolId(
            pools: pools, templates: templates,
            achievableTaskIdsByTemplateId: achievable, tasksById: byId
        )
    }

    func test_poolPlusBoardSource_poolAloneShort_butNotTheTemplate_isNotFlagged() throws {
        let db = try makeDb()
        let pool = try seedPool(db, id: "pool-1", taskIds: ["p1", "p2", "p3"])
        try seedSourceBoard(db, id: "board-1", taskIds: ["b1", "b2", "b3", "b4", "b5"])
        let tpl = template(sources: [
            BoardSource(sourceId: "pool-1", kind: .pool),
            BoardSource(sourceId: "board-1", kind: .board),
        ])

        // The OLD read (poolIds → resolveMix) saw the pool's 3 tasks alone:
        // short by 5, so the card said "Short on 1 board".
        let old = PoolMix.resolveMix(tpl, poolsById: ["pool-1": pool], tasksById: try tasksById(db))
        XCTAssertEqual(old.taskIds.count, 3)

        let result = try health(db, pools: [pool], templates: [tpl])
        XCTAssertEqual(result["pool-1"], PoolHealth.Result(taskCount: 3, consumers: []))
    }

    func test_poolSourceCappedBelowFloor_isFlagged_withRangeShortBy() throws {
        let db = try makeDb()
        let ids = (0..<10).map { "p\($0)" }
        let pool = try seedPool(db, id: "pool-1", taskIds: ids)
        let tpl = template(name: "Capped", sources: [BoardSource(sourceId: "pool-1", kind: .pool, max: 3)])

        // The OLD read ignored the range: all 10 ≥ the 8-cell floor.
        let old = PoolMix.resolveMix(tpl, poolsById: ["pool-1": pool], tasksById: try tasksById(db))
        XCTAssertEqual(old.taskIds.count, 10)

        let result = try health(db, pools: [pool], templates: [tpl])
        XCTAssertEqual(result["pool-1"], PoolHealth.Result(taskCount: 10, consumers: [
            PoolHealth.Consumer(
                templateId: "tpl", templateName: "Capped",
                timeframe: .weekly, boardSize: 3,
                shortBy: 5 // floor 8 − the 3 the range lets the spawn deal
            ),
        ]))
    }

    func test_boardOnlyRecord_withStalePoolIdsMirror_isNotAConsumerOfThePool() throws {
        let db = try makeDb()
        let pool = try seedPool(db, id: "pool-1", taskIds: ["p1"])
        try seedSourceBoard(db, id: "board-1", taskIds: ["b1", "b2"])
        // Short (2 < 8), but it no longer pulls pool-1 — only the mirror does.
        var tpl = template(sources: [BoardSource(sourceId: "board-1", kind: .board)])
        tpl.poolIds = ["pool-1"]

        let result = try health(db, pools: [pool], templates: [tpl])
        XCTAssertEqual(result["pool-1"]?.consumers, [])
    }
}
