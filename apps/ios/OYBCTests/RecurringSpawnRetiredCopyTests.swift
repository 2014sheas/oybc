import GRDB
import XCTest
@testable import OYBC

/// The owner's daily repeating board (2026-10-19): the retired slice-4a
/// placement sweep tombstoned its hand-added linked copy "Run 2 Miles" as an
/// orphan without re-keying the record, and every window then skipped with
/// `.hasDeletedTasks`. `healRetiredCounterCopies` repoints the copy at its
/// live root, and the spawn persists it. Web mirror:
/// `recurringBoardSpawnRetiredCopy.test.ts` + the shared
/// `healRetiredCounterCopies` suite.
final class RecurringSpawnRetiredCopyTests: XCTestCase {

    private let userId = "u1"
    private let now = "2026-10-19T00:00:00.000Z"
    private let root = "root-miles"
    private let copy = "copy-miles"
    private let fillers = (0..<8).map { "f\($0)" }

    private func task(_ id: String) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: id, type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func miles(_ id: String, goal: CountValue, linkedTo: String? = nil, deleted: Bool = false) -> OYBC.Task {
        var t = OYBC.Task(
            id: id, userId: userId, title: "Run \(goal) Miles", type: .counting, action: "Run", unit: "Miles",
            maxCount: goal, totalCompletions: 0, totalInstances: 0, currentCount: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: deleted, sharedCounterId: linkedTo
        )
        t.countKind = .continuous
        if deleted { t.deletedAt = "2026-10-18T11:50:36Z" }
        if linkedTo == nil { t.timeframeGoals = CounterTimeframeGoals(yearly: 365) }
        return t
    }

    private var tasksById: [String: OYBC.Task] {
        var out = [root: miles(root, goal: 3), copy: miles(copy, goal: 2, linkedTo: root, deleted: true)]
        for id in fillers { out[id] = task(id) }
        return out
    }

    private func template(manual: [String]? = nil, vary: [String: VaryLevel]? = nil,
                          targets: [String: ManualTaskTarget]? = nil) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: "tpl-daily", userId: userId, name: "Everyday exercise",
            timeframe: .daily, boardSize: 3, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [root] + fillers, poolIds: [], manualTaskIds: manual ?? ([copy] + fillers),
            removedTaskIds: [], sources: [], manualTaskVary: vary, manualTaskTargets: targets,
            lastSpawnedWindowKey: "2026-10-18T00:00:00.000", isActive: true,
            createdAt: now, updatedAt: now, version: 8
        )
    }

    // MARK: - Pure heal

    func testRepointsTheCopyAtItsRootMovesItsDiceAndCarriesItsGoal() {
        let healed = healRetiredCounterCopies(template(vary: [copy: .lot]), tasksById: tasksById)
        XCTAssertEqual(healed.manualTaskIds, [root] + fillers)
        XCTAssertEqual(healed.seedTaskIds, [root] + fillers)
        XCTAssertEqual(healed.manualTaskVary, [root: .lot])
        XCTAssertEqual(healed.manualTaskTargets, [root: ManualTaskTarget(target: 2, kind: .continuous)])
    }

    func testAnExistingRootDiceEntryStands() {
        let healed = healRetiredCounterCopies(template(vary: [copy: .lot, root: .little]), tasksById: tasksById)
        XCTAssertEqual(healed.manualTaskVary, [root: .little])
    }

    func testAFrozenTargetKeyedByTheCopyMovesToTheRoot() {
        let frozen = ManualTaskTarget(target: 4, kind: .continuous, title: "Long run")
        let healed = healRetiredCounterCopies(template(targets: [copy: frozen]), tasksById: tasksById)
        XCTAssertEqual(healed.manualTaskTargets, [root: frozen])
    }

    func testARootThePersonReAddedKeepsItsOwnGoalAndAppearsOnce() {
        let healed = healRetiredCounterCopies(template(manual: [copy, root] + fillers, targets: [:]), tasksById: tasksById)
        XCTAssertEqual(healed.manualTaskIds, [root] + fillers)
        XCTAssertEqual(healed.manualTaskTargets, [:])
    }

    func testLeavesAPersonDeletedTaskAndACopyOfADeletedRootForTheValidator() {
        var tasks = tasksById
        tasks["f0"]?.isDeleted = true
        let plain = template(manual: ["f0"] + fillers.dropFirst())
        XCTAssertEqual(healRetiredCounterCopies(plain, tasksById: tasks).manualTaskIds, plain.manualTaskIds)
        tasks[root]?.isDeleted = true
        let orphaned = template(vary: [copy: .lot])
        let untouched = healRetiredCounterCopies(orphaned, tasksById: tasks)
        XCTAssertEqual(untouched.manualTaskIds, orphaned.manualTaskIds)
        XCTAssertEqual(untouched.manualTaskVary, [copy: .lot])
        XCTAssertNil(untouched.manualTaskTargets)
    }

    // MARK: - Spawn

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.write { grdb in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).insert(grdb)
            for t in tasksById.values { try t.insert(grdb) }
        }
        return db
    }

    private func spawn(_ db: AppDatabase, _ t: RecurringBoardTemplate) throws -> RecurringSpawnOutcome {
        try db.write { try t.insert($0) }
        return try db.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: t, windowStart: "2026-10-19T00:00:00.000",
                windowEnd: "2026-10-19T23:59:59.999", suggestedName: "Everyday exercise"
            ),
            boardId: "spawned-1", now: now
        )
    }

    func testSpawnsWithTheRootAtTheCopysGoalAndPersistsTheRepoint() throws {
        let db = try makeDb()
        guard case .spawned(let boardId, _, _, _) = try spawn(db, template()) else {
            return XCTFail("the window must spawn")
        }
        let placed = try db.read { try BoardTask.filter(Column("boardId") == boardId).fetchAll($0) }
        XCTAssertFalse(placed.contains { $0.taskId == copy })
        let rootCell = try XCTUnwrap(placed.first { $0.taskId == root })
        XCTAssertEqual(rootCell.targetOverride, 2)
        XCTAssertEqual(rootCell.targetKind, .continuous)

        let stored = try XCTUnwrap(db.fetchRecurringBoardTemplate(id: "tpl-daily"))
        XCTAssertEqual(stored.manualTaskIds, [root] + fillers)
        XCTAssertEqual(stored.manualTaskTargets, [root: ManualTaskTarget(target: 2, kind: .continuous)])
        let queued = try db.read { try SyncQueueItem.filter(Column("entityId") == "tpl-daily").fetchAll($0) }
        XCTAssertFalse(queued.isEmpty)
    }

    func testATaskThePersonDeletedStillSkipsTheWindow() throws {
        let db = try makeDb()
        try db.write { grdb in
            var gone = try XCTUnwrap(OYBC.Task.fetchOne(grdb, key: "f0"))
            gone.isDeleted = true
            try gone.update(grdb)
        }
        guard case .skipped(_, let reason) = try spawn(db, template()) else {
            return XCTFail("a person-deleted task must still skip")
        }
        XCTAssertEqual(reason, .hasDeletedTasks)
    }
}
