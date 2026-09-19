import XCTest
import GRDB
@testable import OYBC

/// Seam tests for Board Sources §Member rules (B2) — the iOS write half in
/// `AppDatabase+DerivedCounters.swift`. Swift twin of
/// `apps/web/src/db/operations/__tests__/derivedCounters.test.ts`.
///
/// Covers:
///   1. **Mint** (RB2/RB3) — a rule-governed counting member is replaced in
///      the placement by a window-stamped derived counter whose row is
///      written + CREATE-enqueued, with the baseline RB2 computes from the
///      root's pre-window events.
///   2. **Idempotency** — a second identical run is a TRUE no-op: no write,
///      no `updatedAt`/`version` churn, no second sync row.
///   3. **Tombstone revive** — a re-run over a tombstoned row revives it with
///      `version + 1` and an UPDATE enqueue (so the revive outranks the
///      tombstone under LWW instead of self-reverting).
///   4. **Derived compound** (RB10) — a One-square compound becomes a derived
///      compound row plus `compound_children` links, one per child, with the
///      re-targeted part pointing at its own derived counter.
///   5. **Refresh** — `refreshDerivedBaselines` is NON-AUTHORED: it rewrites
///      `baseline` only (no version bump, no `updatedAt`, no enqueue), and
///      returns 0 when nothing moved.
///   6. **Persist gate** — `saveWizardBoard` mints on an ACTIVE save and NOT
///      on a draft save, and a replaced centre square keeps its cell (and the
///      board's stored `centerTaskId` follows it).
final class DerivedCountersTests: XCTestCase {

    // MARK: - Fixtures

    private let userId = "u1"
    private let boardId = "board-1"
    private let rootId = "root-1"
    /// Board start — the RB2 boundary in every vector below.
    private let windowStart = "2026-09-18T00:00:00.000Z"
    private let windowEnd = "2026-09-18T23:59:59.999Z"
    private let now = "2026-09-18T09:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
            ).save(db)
        }
        return database
    }

    private func makeCountingTask(
        id: String,
        maxCount: Int? = 10,
        currentCount: Int = 0,
        action: String? = "Read",
        unit: String? = "pages"
    ) -> Task {
        Task(
            id: id, userId: userId, title: "Read 10 pages", type: .counting,
            action: action, unit: unit, maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: currentCount,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func makeIncrementEvent(id: String, taskId: String, delta: Int, at occurredAt: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .increment, delta: delta,
            occurredAt: occurredAt, boardId: nil,
            createdAt: occurredAt, updatedAt: occurredAt, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func boardSupply(
        _ taskIds: [String],
        memberRules: [String: BoardSourceMemberRule],
        partOf: [String: String] = [:]
    ) -> BoardSources.ExpandedSupply {
        BoardSources.ExpandedSupply(
            source: BoardSource(
                sourceId: "source-board", kind: .board, min: 0, max: nil,
                excludedTaskIds: [], filter: .all, memberRules: memberRules
            ),
            supplyTaskIds: taskIds,
            partOf: partOf
        )
    }

    private var window: BoardSources.BoardWindow {
        BoardSources.BoardWindow(timeframe: .daily, startDate: windowStart, endDate: windowEnd)
    }

    /// Run the mint against one counting member governed by `target: 4`.
    @discardableResult
    private func mintOneCounter(
        _ database: AppDatabase,
        at mintTime: String,
        tasksById: [String: Task]
    ) throws -> (placementIds: [String], minted: BoardSources.DerivedRows) {
        try database.write { db in
            let events = try TaskEvent.fetchAll(db)
            return try AppDatabase.planAndMintDerivedRows(
                db: db,
                boardId: self.boardId,
                userId: self.userId,
                now: mintTime,
                selectedIds: [self.rootId],
                supplies: [self.boardSupply([self.rootId], memberRules: [self.rootId: BoardSourceMemberRule(target: 4)])],
                manualTaskIds: [],
                manualTaskVary: [:],
                window: self.window,
                mode: .oneOff,
                tasksById: tasksById,
                childrenByCompoundId: [:],
                sourceWindowByTaskId: [:],
                events: events
            )
        }
    }

    private func syncRows(_ database: AppDatabase, entityId: String) throws -> [SyncQueueItem] {
        try database.read { db in
            try SyncQueueItem.filter(Column("entityId") == entityId).fetchAll(db)
        }
    }

    // MARK: - 1. Mint

    func test_mint_replacesPlacementAndWritesRowWithWindowBaseline() throws {
        let database = try makeDb()
        // Lifetime 10: 7 logged before the window opened, 3 inside it.
        let root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 10)
        try database.write { db in
            try root.save(db)
            try self.makeIncrementEvent(id: "e-before", taskId: self.rootId, delta: 7,
                                        at: "2026-09-17T08:00:00.000Z").save(db)
            try self.makeIncrementEvent(id: "e-inside", taskId: self.rootId, delta: 3,
                                        at: "2026-09-18T08:00:00.000Z").save(db)
        }

        let result = try mintOneCounter(database, at: now, tasksById: [rootId: root])
        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)

        XCTAssertEqual(result.placementIds, [derivedId],
                       "the member is replaced IN PLACE by its derived counter")
        let stored = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertEqual(stored.sharedCounterId, rootId)
        XCTAssertEqual(stored.maxCount, 4, "the explicit member target wins")
        // RB2: only the PRE-window 7 counts; the in-window 3 belongs to this window.
        XCTAssertEqual(stored.baseline, 7)
        XCTAssertEqual(stored.currentCount, 10, "mirrors the root's LIFETIME count")
        XCTAssertFalse(stored.isCompleted, "displayed = 10 − 7 = 3, below the target 4")
        XCTAssertNil(stored.completedAt)
        XCTAssertEqual(stored.timeframe, .daily)
        XCTAssertEqual(stored.startDate, windowStart)
        XCTAssertEqual(stored.endDate, windowEnd)
        XCTAssertTrue(stored.createdInWizard)
        XCTAssertEqual(stored.version, 1)
        XCTAssertFalse(stored.isDeleted)

        let queued = try syncRows(database, entityId: derivedId)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.entityType, "tasks")
        XCTAssertEqual(queued.first?.operationType, .create)
    }

    func test_mint_bornCompleteWhenTheRootHasAlreadyPassedTheTarget() throws {
        let database = try makeDb()
        // Everything logged INSIDE the window: baseline 0, displayed 12 ≥ 4.
        let root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 12)
        try database.write { db in
            try root.save(db)
            try self.makeIncrementEvent(id: "e-inside", taskId: self.rootId, delta: 12,
                                        at: "2026-09-18T08:00:00.000Z").save(db)
        }

        try mintOneCounter(database, at: now, tasksById: [rootId: root])
        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        let stored = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertEqual(stored.baseline, 0)
        XCTAssertTrue(stored.isCompleted, "12 − 0 = 12 ≥ target 4 → born complete")
        XCTAssertEqual(stored.completedAt, now,
                       "the false → true transition has already happened at mint")
    }

    // MARK: - 2. Idempotency (RB3 — live row → skip)

    func test_mint_secondIdenticalRunIsATrueNoOp() throws {
        let database = try makeDb()
        let root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 12)
        try database.write { db in
            try root.save(db)
            try self.makeIncrementEvent(id: "e-before", taskId: self.rootId, delta: 7,
                                        at: "2026-09-17T08:00:00.000Z").save(db)
        }
        try mintOneCounter(database, at: now, tasksById: [rootId: root])
        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        let first = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })

        // A LATER `now` — a row that got rewritten would visibly move.
        let second = try mintOneCounter(database, at: "2026-09-18T18:00:00.000Z",
                                        tasksById: [rootId: root])
        XCTAssertEqual(second.placementIds, [derivedId],
                       "the placement id is still emitted on a skipped write")

        let after = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertEqual(after.version, first.version)
        XCTAssertEqual(after.updatedAt, first.updatedAt)
        XCTAssertEqual(try syncRows(database, entityId: derivedId).count, 1,
                       "a re-entry must not push a redundant row to Firestore")
    }

    // MARK: - 3. Tombstone revive

    func test_mint_revivesATombstonedRowWithAVersionBumpAndUpdateEnqueue() throws {
        let database = try makeDb()
        let root = makeCountingTask(id: rootId, maxCount: 10, currentCount: 12)
        try database.write { db in try root.save(db) }
        try mintOneCounter(database, at: now, tasksById: [rootId: root])
        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)

        let born = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        try database.write { db in
            // Mark the mint's CREATE as already pushed, so the revive's own
            // enqueue is observable rather than folded into the still-pending
            // CREATE by the D3 coalescer. That is also the realistic order: the
            // row was created, synced, then tombstoned (here or on a peer).
            for var item in try SyncQueueItem.filter(Column("entityId") == derivedId).fetchAll(db) {
                item.status = .completed
                try item.save(db)
            }
            var row = born
            row.isDeleted = true
            row.deletedAt = "2026-09-18T10:00:00.000Z"
            row.version = 5
            try row.save(db)
        }

        let reviveTime = "2026-09-18T18:00:00.000Z"
        try mintOneCounter(database, at: reviveTime, tasksById: [rootId: root])

        let revived = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertFalse(revived.isDeleted)
        XCTAssertNil(revived.deletedAt)
        XCTAssertEqual(revived.version, 6, "version + 1 over the tombstone, so the revive wins LWW")
        XCTAssertEqual(revived.updatedAt, reviveTime)
        XCTAssertEqual(revived.createdAt, born.createdAt, "the row's birth hasn't moved")

        let pending = try syncRows(database, entityId: derivedId).filter { $0.status == .pending }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.operationType, .update,
                       "an UPDATE, so the revive outranks the tombstone instead of losing to it")
    }

    // MARK: - 4. Derived compound (RB10)

    func test_mint_derivedCompoundWritesParentLinksAndItsDerivedPart() throws {
        let database = try makeDb()
        let compoundId = "compound-1"
        let countingChildId = "child-counting"
        let normalChildId = "child-normal"
        let compound = Task(
            id: compoundId, userId: userId, title: "Morning", description: "AM routine",
            type: .compound, operatorType: .and,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let countingChild = makeCountingTask(id: countingChildId, maxCount: 10, currentCount: 4)
        let normalChild = Task(
            id: normalChildId, userId: userId, title: "Stretch", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        let links = [
            CompoundChild(id: "link-0", compoundTaskId: compoundId, childTaskId: countingChildId,
                          childIndex: 0, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                          version: 1, isDeleted: false, deletedAt: nil),
            CompoundChild(id: "link-1", compoundTaskId: compoundId, childTaskId: normalChildId,
                          childIndex: 1, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                          version: 1, isDeleted: false, deletedAt: nil),
        ]
        try database.write { db in
            try compound.save(db)
            try countingChild.save(db)
            try normalChild.save(db)
            for link in links { try link.save(db) }
        }

        let tasksById = [
            compoundId: compound, countingChildId: countingChild, normalChildId: normalChild,
        ]
        let result = try database.write { db in
            try AppDatabase.planAndMintDerivedRows(
                db: db,
                boardId: self.boardId,
                userId: self.userId,
                now: self.now,
                selectedIds: [compoundId],
                supplies: [self.boardSupply(
                    [compoundId],
                    memberRules: [compoundId: BoardSourceMemberRule(
                        parts: [countingChildId: BoardSourcePartRule(target: 3)]
                    )]
                )],
                manualTaskIds: [],
                manualTaskVary: [:],
                window: self.window,
                mode: .oneOff,
                tasksById: tasksById,
                childrenByCompoundId: [compoundId: links],
                sourceWindowByTaskId: [:],
                events: []
            )
        }

        let derivedCompoundId = BoardSources.derivedCompoundId(boardId: boardId, compoundId: compoundId)
        let derivedPartId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: countingChildId)
        XCTAssertEqual(result.placementIds, [derivedCompoundId])

        let parent = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedCompoundId) })
        XCTAssertEqual(parent.type, .compound)
        XCTAssertEqual(parent.operatorType, .and)
        XCTAssertEqual(parent.title, "Morning")
        XCTAssertEqual(parent.description, "AM routine", "copied from the SOURCE compound row")
        XCTAssertEqual(parent.startDate, windowStart)
        XCTAssertTrue(parent.createdInWizard)

        let part = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedPartId) })
        XCTAssertEqual(part.maxCount, 3)
        XCTAssertEqual(part.sharedCounterId, countingChildId)

        let storedLinks = try database.read { db in
            try CompoundChild
                .filter(Column("compoundTaskId") == derivedCompoundId)
                .order(Column("childIndex"))
                .fetchAll(db)
        }
        XCTAssertEqual(storedLinks.map { $0.childTaskId }, [derivedPartId, normalChildId],
                       "the re-targeted part points at its derived counter; the other child is kept")
        XCTAssertEqual(storedLinks.map { $0.childIndex }, [0, 1])

        for entityId in [derivedCompoundId, derivedPartId] {
            XCTAssertEqual(try syncRows(database, entityId: entityId).count, 1, entityId)
        }
        for link in storedLinks {
            let queued = try syncRows(database, entityId: link.id)
            XCTAssertEqual(queued.count, 1)
            XCTAssertEqual(queued.first?.entityType, "compoundChildren")
            XCTAssertEqual(queued.first?.operationType, .create)
        }
    }

    // MARK: - 5. Refresh (non-authored)

    /// A window-stamped derived row whose stored `baseline` is stale.
    private func seedDerivedRow(
        _ database: AppDatabase,
        baseline: Int,
        startDate: String
    ) throws -> Task {
        let derived = Task(
            id: "derived-1", userId: userId, title: "Read 4 pages", type: .counting,
            action: "Read", unit: "pages", maxCount: 4,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, currentCount: 0,
            createdAt: now, updatedAt: now, version: 3, isDeleted: false,
            timeframe: .daily, startDate: startDate, endDate: windowEnd,
            sharedCounterId: rootId, baseline: baseline, createdInWizard: true
        )
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, currentCount: 0).save(db)
            try derived.save(db)
        }
        return derived
    }

    func test_refresh_rewritesTheBaselineWithoutAuthoringTheRow() throws {
        let database = try makeDb()
        let derived = try seedDerivedRow(database, baseline: 0, startDate: windowStart)
        try database.write { db in
            // 7 before the window, 5 inside it → baseline must become 7.
            try self.makeIncrementEvent(id: "e1", taskId: self.rootId, delta: 4,
                                        at: "2026-09-16T08:00:00.000Z").save(db)
            try self.makeIncrementEvent(id: "e2", taskId: self.rootId, delta: 3,
                                        at: "2026-09-17T08:00:00.000Z").save(db)
            try self.makeIncrementEvent(id: "e3", taskId: self.rootId, delta: 5,
                                        at: "2026-09-18T08:00:00.000Z").save(db)
        }

        let touched = try database.write { db in
            try AppDatabase.refreshDerivedBaselines(db: db, rootTaskId: self.rootId)
        }
        XCTAssertEqual(touched, 1)

        let after = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derived.id) })
        XCTAssertEqual(after.baseline, 7, "4 + 3 strictly before the window start")
        XCTAssertEqual(after.version, derived.version, "non-authored: no version bump")
        XCTAssertEqual(after.updatedAt, derived.updatedAt, "non-authored: updatedAt untouched")
        XCTAssertEqual(try syncRows(database, entityId: derived.id).count, 0,
                       "non-authored: nothing enqueued")
    }

    func test_refresh_returnsZeroWhenNothingMoved() throws {
        let database = try makeDb()
        let derived = try seedDerivedRow(database, baseline: 7, startDate: windowStart)
        try database.write { db in
            try self.makeIncrementEvent(id: "e1", taskId: self.rootId, delta: 7,
                                        at: "2026-09-17T08:00:00.000Z").save(db)
        }
        let touched = try database.write { db in
            try AppDatabase.refreshDerivedBaselines(db: db, rootTaskId: self.rootId)
        }
        XCTAssertEqual(touched, 0, "a correct baseline is not rewritten at all")
        let after = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derived.id) })
        XCTAssertEqual(after.baseline, 7)
    }

    func test_refresh_leavesAHandMadeLinkedCounterAlone() throws {
        let database = try makeDb()
        // Two of the three marks only (no `createdInWizard`) — the user's own
        // "start from zero" linked counter, which this pipeline never rewrites.
        let handMade = Task(
            id: "hand-made", userId: userId, title: "Read 4 pages", type: .counting,
            maxCount: 4, totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 2, isDeleted: false,
            timeframe: .daily, startDate: windowStart, endDate: windowEnd,
            sharedCounterId: rootId, baseline: 0, createdInWizard: false
        )
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, currentCount: 0).save(db)
            try handMade.save(db)
            try self.makeIncrementEvent(id: "e1", taskId: self.rootId, delta: 9,
                                        at: "2026-09-17T08:00:00.000Z").save(db)
        }
        let touched = try database.write { db in
            try AppDatabase.refreshDerivedBaselines(db: db, rootTaskId: self.rootId)
        }
        XCTAssertEqual(touched, 0)
        let after = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: "hand-made") })
        XCTAssertEqual(after.baseline, 0, "a hand-made linked counter keeps its own baseline")
    }

    // MARK: - 6. Persist gate (saveWizardBoard)

    private func makeBoard(id: String, status: BoardStatus, centerTaskId: String?) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Today", "status": status.rawValue,
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.chosen.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        if let centerTaskId { dict["centerTaskId"] = centerTaskId }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    /// Seeds a live WEEKLY source board placing `rootId`, and returns the
    /// `BoardSource` that pulls it with an explicit target of 4.
    private func seedSourceBoard(_ database: AppDatabase) throws -> BoardSource {
        let sourceBoardId = "source-board"
        let dict: [String: Any] = [
            "id": sourceBoardId, "userId": userId, "name": "This week",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.weekly.rawValue,
            "startDate": "2026-09-14T00:00:00.000Z", "endDate": "2026-09-20T23:59:59.999Z",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        let sourceBoard = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 10, currentCount: 0).save(db)
            try sourceBoard.save(db)
            try BoardTask(
                id: "source-bt", boardId: sourceBoardId, taskId: self.rootId,
                row: 0, col: 0, isCenter: false,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        return BoardSource(
            sourceId: sourceBoardId, kind: .board, min: 0, max: nil,
            excludedTaskIds: [], filter: .all,
            memberRules: [rootId: BoardSourceMemberRule(target: 4)]
        )
    }

    /// The centre placement of the board being saved (3×3 → cell (1,1)).
    private func makeCentrePlacement() -> BoardTask {
        BoardTask(
            id: "bt-centre", boardId: boardId, taskId: rootId,
            row: 1, col: 1, isCenter: true,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    func test_saveWizardBoard_draftSaveMintsNothing() throws {
        let database = try makeDb()
        let source = try seedSourceBoard(database)
        let board = try makeBoard(id: boardId, status: .draft, centerTaskId: rootId)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [source], manualTaskIds: [], now: now
        )

        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        XCTAssertNil(try database.read { try Task.fetchOne($0, key: derivedId) },
                     "a draft's window is still editable — nothing is minted for it")
        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId).fetchAll(db)
        }
        XCTAssertEqual(placements.map { $0.taskId }, [rootId],
                       "a draft places its ORIGINAL member id")
        XCTAssertEqual(try database.fetchBoard(id: boardId)?.centerTaskId, rootId)
    }

    func test_saveWizardBoard_activeSaveMintsAndTheCentreKeepsItsCell() throws {
        let database = try makeDb()
        let source = try seedSourceBoard(database)
        let board = try makeBoard(id: boardId, status: .active, centerTaskId: rootId)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [source], manualTaskIds: [], now: now
        )

        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        let derived = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertEqual(derived.maxCount, 4)
        XCTAssertEqual(derived.sharedCounterId, rootId)
        XCTAssertEqual(derived.startDate, windowStart)

        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(placements.first?.taskId, derivedId)
        XCTAssertEqual([placements.first?.row, placements.first?.col], [1, 1],
                       "the replaced centre keeps its cell")
        XCTAssertEqual(placements.first?.isCenter, true)
        XCTAssertEqual(try database.fetchBoard(id: boardId)?.centerTaskId, derivedId,
                       "the board's stored centre follows the replacement")
    }

    // MARK: - 7. Spawn (recurring path)

    /// Seeds a source board with the given placements and returns its id.
    private func seedSpawnSourceBoard(
        _ database: AppDatabase,
        id: String,
        timeframe: Timeframe,
        startDate: String,
        endDate: String,
        taskIds: [String]
    ) throws {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Source", "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try database.write { db in
            try board.save(db)
            for (index, taskId) in taskIds.enumerated() {
                try BoardTask(
                    id: "bt-\(id)-\(taskId)", boardId: id, taskId: taskId,
                    row: index / 3, col: index % 3, isCenter: false,
                    createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
        }
    }

    private func makeNormalTask(id: String) -> Task {
        Task(
            id: id, userId: userId, title: "Task \(id)", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    /// A 2×2 NONE template (4 fillable cells), deterministic order.
    private func seedTemplate(
        _ database: AppDatabase,
        sources: [BoardSource],
        manualTaskIds: [String]
    ) throws -> RecurringBoardTemplate {
        let template = RecurringBoardTemplate(
            id: "tpl-1", userId: userId, name: "Daily", timeframe: .daily,
            boardSize: 2, centerSquareType: .none, isRandomized: false,
            seedTaskIds: [], manualTaskIds: manualTaskIds, sources: sources,
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: now, updatedAt: now, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
        try database.write { db in
            for id in manualTaskIds where try Task.fetchOne(db, key: id) == nil {
                try self.makeNormalTask(id: id).save(db)
            }
            try template.save(db)
        }
        return template
    }

    private func spawn(
        _ database: AppDatabase,
        _ template: RecurringBoardTemplate,
        boardId spawnedId: String = "spawned-1"
    ) throws -> RecurringSpawnOutcome {
        try database.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: template,
                windowStart: windowStart,
                windowEnd: windowEnd,
                suggestedName: "Daily — Sep 18"
            ),
            boardId: spawnedId,
            now: now
        )
    }

    func test_spawn_boardSourceCountingMemberGetsAProRatedDerivedPlacement() throws {
        let database = try makeDb()
        // A WEEKLY source board carrying a goal of 35, pulled onto a DAILY
        // window: the auto target pro-rates 35 × (1 / 7) = 5.
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 35, currentCount: 9).save(db)
            try self.makeIncrementEvent(id: "e-before", taskId: self.rootId, delta: 9,
                                        at: "2026-09-16T08:00:00.000Z").save(db)
        }
        try seedSpawnSourceBoard(
            database, id: "src-weekly", timeframe: .weekly,
            startDate: "2026-09-14T00:00:00.000Z", endDate: "2026-09-20T23:59:59.999Z",
            taskIds: [rootId]
        )
        let template = try seedTemplate(
            database,
            sources: [BoardSource(sourceId: "src-weekly", kind: .board)],
            manualTaskIds: ["m1", "m2", "m3"]
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let derivedId = BoardSources.derivedTaskId(boardId: "spawned-1", rootTaskId: rootId)
        let derived = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        XCTAssertEqual(derived.maxCount, 5, "ceil(35 × 1 / 7) — the pro-rated auto target")
        XCTAssertEqual(derived.baseline, 9, "the root's lifetime count when this window opened")
        XCTAssertEqual(derived.sharedCounterId, rootId)
        XCTAssertEqual(derived.startDate, windowStart)
        XCTAssertEqual(derived.timeframe, .daily)

        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.taskId }
        }
        XCTAssertTrue(placed.contains(derivedId), "the derived counter is what lands on the board")
        XCTAssertFalse(placed.contains(rootId), "the source member itself is NOT placed")
    }

    func test_spawn_splitCompoundContributesItsPartsAsCandidates() throws {
        let database = try makeDb()
        let compoundId = "compound-1"
        try database.write { db in
            try Task(
                id: compoundId, userId: self.userId, title: "Morning", type: .compound,
                operatorType: .and, totalCompletions: 0, totalInstances: 0,
                createdAt: self.now, updatedAt: self.now, version: 1, isDeleted: false
            ).save(db)
            try self.makeNormalTask(id: "part-a").save(db)
            try self.makeNormalTask(id: "part-b").save(db)
            try CompoundChild(
                id: "cl-0", compoundTaskId: compoundId, childTaskId: "part-a", childIndex: 0,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
            try CompoundChild(
                id: "cl-1", compoundTaskId: compoundId, childTaskId: "part-b", childIndex: 1,
                createdAt: self.now, updatedAt: self.now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        try seedSpawnSourceBoard(
            database, id: "src-daily", timeframe: .daily,
            startDate: "2026-09-17T00:00:00.000Z", endDate: "2026-09-17T23:59:59.999Z",
            taskIds: [compoundId]
        )
        let template = try seedTemplate(
            database,
            sources: [BoardSource(
                sourceId: "src-daily", kind: .board, min: 0, max: nil,
                excludedTaskIds: [], filter: .all,
                memberRules: [compoundId: BoardSourceMemberRule(split: true)]
            )],
            manualTaskIds: ["m1", "m2"]
        )

        let outcome = try spawn(database, template)
        guard case .spawned = outcome else { return XCTFail("expected a spawn, got \(outcome)") }

        let placed = try database.read { db in
            try BoardTask.filter(Column("boardId") == "spawned-1" && Column("isDeleted") == false)
                .fetchAll(db)
                .map { $0.taskId }
        }
        XCTAssertEqual(Set(placed), ["part-a", "part-b", "m1", "m2"],
                       "Split up contributes the PARTS as selectable squares, never the compound")
        XCTAssertFalse(placed.contains(compoundId))
    }

    // MARK: - 7. GRDB v32 — the tasks(sharedCounterId) index

    func test_migrationV32_indexesTasksSharedCounterId() throws {
        // Every window-stamped derived read filters on `sharedCounterId`, and
        // the pull runs one per affected task inside its write transaction —
        // unindexed that is a full `tasks` scan per row. The web twin has
        // always been index-backed.
        let database = try makeDb()
        let indexes: [String] = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='tasks'"
            ).map { row in row["name"] }
        }
        XCTAssertTrue(indexes.contains("idx_tasks_shared_counter"),
                      "v32 must create idx_tasks_shared_counter; found \(indexes)")

        // And it really covers the column the reads use.
        let columns: [String] = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info('idx_tasks_shared_counter')")
                .map { row in row["name"] }
        }
        XCTAssertEqual(columns, ["sharedCounterId"])
    }
    // MARK: - 8. §Member rules (B3): the wizard's hand-added dice

    /// Seeds the counting task a hand-added member points at and returns the
    /// active board + its single (centre) placement.
    private func seedHandAddedCounter(_ database: AppDatabase) throws -> Board {
        try database.write { db in
            try self.makeCountingTask(id: self.rootId, maxCount: 10, currentCount: 0).save(db)
        }
        return try makeBoard(id: boardId, status: .active, centerTaskId: rootId)
    }

    /// B3 threading, the decisive half: with dice on the hand-added layer the
    /// active save mints a window-stamped derived counter whose `maxCount` is
    /// a ROLL inside `varyRange`, not the goal copied through. The assertion
    /// pins the range (the production rng is unseeded), and the control test
    /// below proves the mint only happens because the dice arrived.
    func test_saveWizardBoard_handAddedDice_mintARolledTargetInsideVaryRange() throws {
        let database = try makeDb()
        let board = try seedHandAddedCounter(database)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [rootId],
            manualTaskVary: [rootId: .lot], now: now
        )

        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        let derived = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: derivedId) })
        let range = BoardSources.varyRange(t: 10, level: .lot, goal: 10)
        let maxCount = try XCTUnwrap(derived.maxCount)
        XCTAssertTrue(
            range.contains(maxCount),
            "rolled target \(maxCount) must land inside \(range.lowerBound)…\(range.upperBound)"
        )
        XCTAssertEqual(derived.sharedCounterId, rootId)
        XCTAssertEqual(derived.startDate, windowStart)

        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.first?.taskId, derivedId)
    }

    /// Control: the SAME save without dice mints nothing and places the
    /// original member — so the test above is pinning the threading, not a
    /// mint that would have happened anyway.
    func test_saveWizardBoard_handAddedWithoutDice_mintsNothing() throws {
        let database = try makeDb()
        let board = try seedHandAddedCounter(database)

        try database.saveWizardBoard(
            board: board, boardTasks: [makeCentrePlacement()], pendingTasks: [],
            isUpdate: false, sources: [], manualTaskIds: [rootId],
            manualTaskVary: [:], now: now
        )

        let derivedId = BoardSources.derivedTaskId(boardId: boardId, rootTaskId: rootId)
        XCTAssertNil(try database.read { try Task.fetchOne($0, key: derivedId) })
        let placements = try database.read { db in
            try BoardTask.filter(Column("boardId") == self.boardId && Column("isDeleted") == false)
                .fetchAll(db)
        }
        XCTAssertEqual(placements.map { $0.taskId }, [rootId])
    }
}
