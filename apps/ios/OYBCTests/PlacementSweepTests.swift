import XCTest
import GRDB
@testable import OYBC

/// Applier tests for `AppDatabase.runPlacementSweepTx` (TASK_WINDOW_REWORK slice 4a).
final class PlacementSweepTests: XCTestCase {
    private let now = "2026-10-18T12:00:00.000Z"

    // MARK: - Fixtures

    private func makeUser() -> User {
        User(
            id: "u", email: "t@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: SweepFixture.ts, updatedAt: SweepFixture.ts,
            lastSyncedAt: nil, version: 1
        )
    }

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.saveUser(makeUser())
        return db
    }

    private func task(_ id: String, _ extra: [String: Any] = [:]) throws -> Task {
        try SweepFixture.decode(Task.self, defaults: [
            "userId": "u", "totalCompletions": 0, "totalInstances": 0, "createdAt": SweepFixture.ts, "updatedAt": SweepFixture.ts,
            "version": 1, "type": "counting", "title": "Read 5 pages", "action": "Read", "unit": "pages", "maxCount": 5,
            "isCompleted": false, "isDeleted": false, "id": id,
        ], mini: extra)
    }

    private func board(_ id: String, _ extra: [String: Any] = [:]) throws -> Board {
        try SweepFixture.decode(Board.self, defaults: [
            "id": id, "userId": "u", "name": id, "status": "active", "boardSize": 3, "timeframe": "weekly",
            "startDate": "2026-10-05T00:00:00", "endDate": "2026-10-11T23:59:59.999", "centerSquareType": "none",
            "isRandomized": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": SweepFixture.ts, "updatedAt": SweepFixture.ts, "version": 1, "isDeleted": false,
        ], mini: extra)
    }

    private func placement(_ id: String, board: String, task: String, row: Int = 0, col: Int = 0) throws -> BoardTask {
        try SweepFixture.decode(BoardTask.self, defaults: [
            "isCenter": false, "createdAt": SweepFixture.ts, "updatedAt": SweepFixture.ts, "version": 1, "isDeleted": false,
        ], mini: ["id": id, "boardId": board, "taskId": task, "row": row, "col": col])
    }

    /// root `r` (goal 10), derived `d` (window-stamped, goal 5, custom title) placed on board `B`.
    private func seedDerived(_ d: Database, boardExtra: [String: Any] = [:]) throws {
        try task("r", ["maxCount": 10, "title": "Read 10 pages"]).insert(d)
        try task("d", [
            "sharedCounterId": "r", "timeframe": "weekly", "startDate": "2026-10-05T00:00:00",
            "endDate": "2026-10-11T23:59:59.999", "createdInWizard": true, "baseline": 3, "title": "Weekly reading",
        ]).insert(d)
        try board("B", boardExtra).insert(d)
        try placement("B-d", board: "B", task: "d").insert(d)
    }

    private func queue(_ db: AppDatabase) throws -> [SyncQueueItem] { try db.read { try SyncQueueItem.fetchAll($0) } }

    private func sweep(_ db: AppDatabase) throws -> PlacementSweepSummary {
        try db.write { try AppDatabase.runPlacementSweepTx(db: $0, userId: "u", now: self.now) }
    }

    // MARK: - Tests

    func testEmptyWorkspaceWritesNothing() throws {
        let db = try makeDb()
        let before = try queue(db).count
        let s = try sweep(db)
        XCTAssertFalse(s.wroteAnything)
        XCTAssertEqual(try queue(db).count, before)
    }

    func testLiveRepointWritesPlacementAndEnqueues() throws {
        let db = try makeDb()
        try db.write { try self.seedDerived($0) }
        let before = try queue(db).count
        let s = try sweep(db)
        XCTAssertEqual(s.repointed, 1)
        let bt = try db.read { try BoardTask.fetchOne($0, key: "B-d") }!
        XCTAssertEqual(bt.taskId, "r")
        XCTAssertEqual(bt.targetOverride, 5)
        XCTAssertEqual(bt.targetKind, .discrete)
        XCTAssertEqual(bt.titleOverride, "Weekly reading")
        XCTAssertEqual(bt.version, 2)
        let added = try queue(db).dropFirst(before)
        XCTAssertTrue(added.contains { $0.entityType == "boardTasks" && $0.entityId == "B-d" && $0.operationType == .update })
    }

    func testSealedRepointKeepsSnapshot() throws {
        let db = try makeDb()
        try db.write {
            try self.seedDerived($0, boardExtra: [
                "sealedAt": "2026-10-12T00:00:00.000Z", "sealedCompletedCells": "[]", "status": "archived",
            ])
        }
        let s = try sweep(db)
        XCTAssertEqual(s.sealedRepointed, 1)
        let b = try db.read { try Board.fetchOne($0, key: "B") }!
        XCTAssertEqual(b.sealedCompletedCells ?? [], [])
        XCTAssertEqual(b.version, 1)
        XCTAssertEqual(try db.read { try BoardTask.fetchOne($0, key: "B-d") }!.taskId, "r")
    }

    func testRefusedBoardStripsWindowMarks() throws {
        let db = try makeDb()
        try db.write { d in
            try self.seedDerived(d)
            try self.placement("B-r", board: "B", task: "r", row: 0, col: 1).insert(d) // duplicate root
        }
        let before = try queue(db).count
        let s = try sweep(db)
        XCTAssertEqual(s.stripped, 1)
        XCTAssertEqual(s.repointed, 0)
        XCTAssertEqual(s.refused.first?.reason, .duplicateRoot)
        let t = try db.read { try Task.fetchOne($0, key: "d") }!
        XCTAssertNil(t.timeframe); XCTAssertNil(t.startDate); XCTAssertNil(t.endDate)
        XCTAssertEqual(t.baseline, 0)
        XCTAssertEqual(t.version, 2)
        XCTAssertTrue(try queue(db).dropFirst(before).contains { $0.entityType == "tasks" && $0.entityId == "d" })
        XCTAssertEqual(try db.read { try BoardTask.fetchOne($0, key: "B-d") }!.taskId, "d")
    }

    func testOrphanTombstonedAndLaterRunsAreQuiet() throws {
        let db = try makeDb()
        try db.write { d in
            try self.seedDerived(d)
            // An unplaced, unlinked marked row.
            try self.task("o", ["sharedCounterId": "r", "timeframe": "weekly", "startDate": "2026-10-05T00:00:00", "createdInWizard": true]).insert(d)
        }
        let first = try sweep(db)
        XCTAssertEqual(first.orphansTombstoned, 1)
        XCTAssertTrue(try db.read { try Task.fetchOne($0, key: "o") }!.isDeleted)
        // Second run: only the deferred orphan (the repointed row, now unplaced) retires.
        let second = try sweep(db)
        XCTAssertEqual(second.repointed + second.sealedRepointed + second.stripped + second.templatesRekeyed + second.poolsRekeyed + second.draftsRekeyed, 0)
        XCTAssertEqual(second.orphansTombstoned, 1)
        XCTAssertFalse(try sweep(db).wroteAnything)
    }

    // MARK: - Derived compounds (slice 4b)

    private func link(_ compound: String, _ child: String, _ index: Int) throws -> CompoundChild {
        try SweepFixture.decode(CompoundChild.self, defaults: [
            "createdAt": SweepFixture.ts, "updatedAt": SweepFixture.ts, "version": 1, "isDeleted": false,
        ], mini: ["id": "\(compound)-\(child)", "compoundTaskId": compound, "childTaskId": child, "childIndex": index])
    }

    /// Source compound S (counting child c1 goal 10 + normal c2) and its derived
    /// compound for board B (part P goal 5 + c2), placed on B. `derivedKids`
    /// overrides the derived compound's children (to force a mismatch).
    private func seedDerivedCompound(_ d: Database, derivedKids: [String]? = nil) throws -> (derived: String, part: String) {
        let dId = BoardSources.derivedCompoundId(boardId: "B", compoundId: "S")
        let pId = BoardSources.derivedTaskId(boardId: "B", rootTaskId: "c1")
        try task("c1", ["maxCount": 10, "title": "Read 10 pages"]).insert(d)
        try task("c2", ["type": "normal", "title": "Stretch"]).insert(d)
        try task("S", ["type": "compound", "operator": "AND", "title": "Morning"]).insert(d)
        try link("S", "c1", 0).insert(d)
        try link("S", "c2", 1).insert(d)
        let marks: [String: Any] = ["timeframe": "weekly", "startDate": "2026-10-05T00:00:00", "createdInWizard": true]
        try task(dId, marks.merging(["type": "compound", "operator": "AND", "title": "Morning"]) { _, n in n }).insert(d)
        try task(pId, marks.merging(["sharedCounterId": "c1", "maxCount": 5]) { _, n in n }).insert(d)
        for (i, kid) in (derivedKids ?? [pId, "c2"]).enumerated() { try link(dId, kid, i).insert(d) }
        try board("B").insert(d)
        try placement("B-D", board: "B", task: dId).insert(d)
        return (dId, pId)
    }

    func testDerivedCompoundRepointsToSourceWithChildTargets() throws {
        let db = try makeDb()
        var ids: (derived: String, part: String) = ("", "")
        try db.write { ids = try self.seedDerivedCompound($0) }
        let gridBefore = try db.read { try Board.fetchOne($0, key: "B") }!.completedTasks
        let s = try sweep(db)
        XCTAssertEqual(s.repointed, 1)
        XCTAssertTrue(s.refused.isEmpty)
        let bt = try db.read { try BoardTask.fetchOne($0, key: "B-D") }!
        XCTAssertEqual(bt.taskId, "S")
        XCTAssertEqual(bt.childTargets, [PlacementChildTarget(childId: "c1", target: 5)])
        XCTAssertNil(bt.targetOverride)
        XCTAssertNil(bt.titleOverride)
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: "B") }!.completedTasks, gridBefore)
        XCTAssertEqual(ids.derived, BoardSources.derivedCompoundId(boardId: "B", compoundId: "S"))
    }

    func testCompoundMismatchStripsTheCompound() throws {
        let db = try makeDb()
        var ids: (derived: String, part: String) = ("", "")
        try db.write { d in
            ids = try self.seedDerivedCompound(d, derivedKids: [])
            try self.link(ids.derived, ids.part, 0).insert(d) // c2 missing: mapped set differs
        }
        let s = try sweep(db)
        XCTAssertEqual(s.repointed, 0)
        XCTAssertEqual(s.stripped, 1)
        XCTAssertEqual(s.refused.first?.reason, .compoundMismatch)
        let t = try db.read { try Task.fetchOne($0, key: ids.derived) }!
        XCTAssertNil(t.timeframe); XCTAssertNil(t.startDate)
        XCTAssertEqual(try db.read { try BoardTask.fetchOne($0, key: "B-D") }!.taskId, ids.derived)
    }

    func testOrphanDerivedCompoundIsTombstonedWithItsLinksAndPartsRetireNext() throws {
        let db = try makeDb()
        var ids: (derived: String, part: String) = ("", "")
        try db.write { d in
            ids = try self.seedDerivedCompound(d)
            // Unplace it: the compound and its part are now unplaced; the compound has no live parent.
            try d.execute(sql: "DELETE FROM board_tasks WHERE id = 'B-D'")
        }
        let before = try queue(db).count
        let first = try sweep(db)
        XCTAssertEqual(first.orphansTombstoned, 1)
        XCTAssertTrue(try db.read { try Task.fetchOne($0, key: ids.derived) }!.isDeleted)
        let links = try db.read { try CompoundChild.filter(Column("compoundTaskId") == ids.derived).fetchAll($0) }
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.allSatisfy { $0.isDeleted })
        let added = try queue(db).dropFirst(before)
        XCTAssertTrue(added.contains { $0.entityType == "compoundChildren" && $0.operationType == .delete })
        XCTAssertTrue(added.contains { $0.entityType == "tasks" && $0.entityId == ids.derived && $0.operationType == .delete })
        // Second run retires the now-unlinked part; a third writes nothing.
        XCTAssertEqual(try sweep(db).orphansTombstoned, 1)
        XCTAssertTrue(try db.read { try Task.fetchOne($0, key: ids.part) }!.isDeleted)
        XCTAssertFalse(try sweep(db).wroteAnything)
    }

    func testTemplatePoolAndDraftRekeys() throws {
        let db = try makeDb()
        try db.write { d in
            try self.seedDerived(d)
            let tpl = RecurringBoardTemplate(
                id: "t1", userId: "u", name: "T", timeframe: .weekly, boardSize: 3, centerSquareType: .none,
                isRandomized: false, seedTaskIds: ["d", "x"], manualTaskIds: ["d"], removedTaskIds: ["d"],
                sources: [BoardSource(sourceId: "p1", kind: .pool, excludedTaskIds: ["d"], memberRules: ["d": BoardSourceMemberRule(target: 4)])],
                manualTaskVary: ["d": .little], isActive: true, createdAt: SweepFixture.ts, updatedAt: SweepFixture.ts
            )
            try tpl.insert(d)
            try Pool(id: "p1", userId: "u", name: "P", taskIds: ["d", "r"], memberVary: ["d": .lot],
                     createdAt: SweepFixture.ts, updatedAt: SweepFixture.ts).insert(d)
            var draft = try self.board("D", ["status": "draft"])
            draft.recurringDraftMix = RecurringDraftMixPayload(
                poolIds: [], manualTaskIds: [], removedTaskIds: [],
                sources: [BoardSource(sourceId: "p1", kind: .pool, excludedTaskIds: ["d"])],
                manualTaskVary: ["d": .little],
                placementParams: ["d": PlacementParamsDraft(targetOverride: 2, targetKind: .discrete, titleOverride: nil)]
            ).encoded()
            try draft.insert(d)
        }
        let s = try sweep(db)
        XCTAssertEqual(s.templatesRekeyed, 1)
        XCTAssertEqual(s.poolsRekeyed, 1)
        XCTAssertEqual(s.draftsRekeyed, 1)
        let tpl = try db.read { try RecurringBoardTemplate.fetchOne($0, key: "t1") }!
        XCTAssertEqual(tpl.seedTaskIds, ["r", "x"])
        XCTAssertEqual(tpl.manualTaskIds, ["r"])
        XCTAssertEqual(tpl.removedTaskIds, ["r"])
        XCTAssertEqual(tpl.manualTaskVary, ["r": .little])
        XCTAssertEqual(tpl.sources?.first?.excludedTaskIds, ["r"])
        XCTAssertEqual(tpl.sources?.first?.memberRules?["r"]?.target, 4)
        XCTAssertEqual(tpl.manualTaskTargets?["r"]?.target, 5)
        XCTAssertEqual(tpl.manualTaskTargets?["r"]?.kind, .discrete)
        XCTAssertEqual(tpl.version, 2)
        let pool = try db.read { try Pool.fetchOne($0, key: "p1") }!
        XCTAssertEqual(pool.taskIds, ["r"])
        XCTAssertEqual(pool.memberVary, ["r": .lot])
        let draft = try db.read { try Board.fetchOne($0, key: "D") }!
        let mix = RecurringDraftMixPayload.decoded(from: draft.recurringDraftMix)
        XCTAssertEqual(mix.sources?.first?.excludedTaskIds, ["r"])
        XCTAssertEqual(mix.manualTaskVary, ["r": .little])
        XCTAssertEqual(mix.placementParams["r"]?.targetOverride, 2)
        XCTAssertNil(mix.placementParams["d"])
        XCTAssertEqual(draft.version, 2)
        let again = try sweep(db)
        XCTAssertEqual(again.templatesRekeyed + again.poolsRekeyed + again.draftsRekeyed, 0)
    }

    func testMigrationV47RunsTheSweep() throws {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        let migrator = try AppDatabase.makeTestInstance().migrator
        try migrator.migrate(queue, upTo: "v46")
        try queue.write { d in
            try self.makeUser().insert(d)
            try self.seedDerived(d)
        }
        try migrator.migrate(queue) // → v47
        let bt = try queue.read { try BoardTask.fetchOne($0, key: "B-d") }!
        XCTAssertEqual(bt.taskId, "r")
        XCTAssertEqual(bt.targetOverride, 5)
    }
}
