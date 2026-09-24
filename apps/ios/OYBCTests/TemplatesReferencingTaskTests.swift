import GRDB
import XCTest
@testable import OYBC

/// 2026-09 audit T2 — Task Detail's "used in repeating boards" list used to
/// match `seedTaskIds`, a creation-time snapshot the template edit path
/// leaves stale. `AppDatabase.fetchTemplatesReferencingTask` now resolves
/// through `BoardSources.templateReferencesTask` over the spawn's own supply
/// resolvers. These cases run it against a test database.
/// Web mirror: `apps/web/src/db/operations/__tests__/recurringBoardTemplates.test.ts`
/// (the `fetchTemplatesReferencingTask` block).
final class TemplatesReferencingTaskTests: XCTestCase {

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

    private func makeTask(_ id: String, type: TaskType = .normal, isCompleted: Bool = false) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: "Task \(id)", description: nil, type: type,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func insert(_ db: AppDatabase, _ tasks: [OYBC.Task]) throws {
        try db.write { grdb in for t in tasks { try t.insert(grdb) } }
    }

    private func template(
        id: String = "tpl",
        seedTaskIds: [String] = [],
        manualTaskIds: [String] = [],
        sources: [BoardSource] = []
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id, userId: userId, name: "Repeating \(id)",
            timeframe: .weekly, boardSize: 3, centerSquareType: .free,
            isRandomized: true, seedTaskIds: seedTaskIds,
            poolIds: sources.filter { $0.kind == .pool }.map { $0.sourceId },
            manualTaskIds: manualTaskIds, removedTaskIds: [],
            sources: sources,
            isActive: true, createdAt: now, updatedAt: now
        )
    }

    private func referencing(_ db: AppDatabase, _ taskId: String) throws -> [String] {
        try db.fetchTemplatesReferencingTask(taskId).map { $0.id }
    }

    func test_editSwappingAForB_movesTheReference_theSeedSnapshotSaidTheOpposite() throws {
        let db = try makeDb()
        try insert(db, [makeTask("task-a"), makeTask("task-b")])
        // Created with A: the create path writes the snapshot AND the
        // hand-added layer …
        var tpl = template(seedTaskIds: ["task-a"], manualTaskIds: ["task-a"])
        try db.saveRecurringBoardTemplate(tpl)
        // … then edited to drop A and add B. The edit path never rewrites
        // `seedTaskIds` (`persistRecurringTemplate`'s edit branch).
        tpl.manualTaskIds = ["task-b"]
        tpl.version += 1
        try db.saveRecurringBoardTemplate(tpl)
        let stored = try XCTUnwrap(db.read { try RecurringBoardTemplate.fetchOne($0, key: "tpl") })
        XCTAssertEqual(stored.seedTaskIds, ["task-a"])

        XCTAssertEqual(try referencing(db, "task-a"), [])
        XCTAssertEqual(try referencing(db, "task-b"), ["tpl"])
    }

    func test_poolSource_referencesMembersMinusExcludes_whateverTheRange() throws {
        let db = try makeDb()
        try insert(db, [makeTask("p1"), makeTask("p2"), makeTask("p3")])
        try db.write { grdb in
            try Pool(
                id: "pool-1", userId: userId, name: "Pool", taskIds: ["p1", "p2", "p3"],
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                isDeleted: false, deletedAt: nil
            ).insert(grdb)
        }
        try db.saveRecurringBoardTemplate(template(sources: [
            BoardSource(sourceId: "pool-1", kind: .pool, max: 1, excludedTaskIds: ["p2"]),
        ]))

        XCTAssertEqual(try referencing(db, "p1"), ["tpl"])
        XCTAssertEqual(try referencing(db, "p3"), ["tpl"])
        XCTAssertEqual(try referencing(db, "p2"), [])
    }

    func test_boardSource_referencesLivePlacements_evenADoneOneTheTodoFilterWouldSkip() throws {
        let db = try makeDb()
        // A compound reads the lifetime isCompleted cache on a source board,
        // so this one is DONE there without any event plumbing.
        try insert(db, [makeTask("b-open"), makeTask("b-done", type: .compound, isCompleted: true)])
        let board = try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: [
            "id": "board-src", "userId": userId, "name": "Source",
            "status": "active", "boardSize": 3, "timeframe": "custom",
            "startDate": now, "endDate": "2099-12-31T23:59:59.999",
            "centerSquareType": "none", "isRandomized": true,
            "totalTasks": 2, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ] as [String: Any]))
        try db.write { grdb in
            try board.insert(grdb)
            for (i, taskId) in ["b-open", "b-done"].enumerated() {
                try BoardTask(
                    id: "bt-\(taskId)", boardId: "board-src", taskId: taskId,
                    row: 0, col: i, isCenter: false,
                    createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false
                ).insert(grdb)
            }
        }
        try db.saveRecurringBoardTemplate(template(sources: [
            BoardSource(sourceId: "board-src", kind: .board, filter: .todo),
        ]))
        // Precondition: the filter WOULD drop b-done from a spawn's supply.
        let info = try XCTUnwrap(db.fetchBoardSourceSupply(boardId: "board-src"))
        XCTAssertTrue(info.doneTaskIds.contains("b-done"))

        XCTAssertEqual(try referencing(db, "b-open"), ["tpl"])
        XCTAssertEqual(try referencing(db, "b-done"), ["tpl"])
    }

    func test_softDeletedTemplate_isNeverListed() throws {
        let db = try makeDb()
        try insert(db, [makeTask("task-a")])
        try db.saveRecurringBoardTemplate(template(manualTaskIds: ["task-a"]))
        XCTAssertEqual(try referencing(db, "task-a"), ["tpl"])
        try db.softDeleteRecurringBoardTemplate(id: "tpl")
        XCTAssertEqual(try referencing(db, "task-a"), [])
    }
}
