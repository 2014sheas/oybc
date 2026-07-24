import XCTest
import GRDB
@testable import OYBC

/// Tests for the AppDatabase methods that ABSORBED the sync-enqueue write
/// transactions in B4 (previously authored inline in view/component/service
/// code). Each test asserts BOTH that the entity rows landed AND that the
/// matching `sync_queue` rows exist (entity type, operation, count) — the
/// core B4 invariant: every local write also enqueues sync, and that enqueue
/// now lives in the data layer.
///
/// Regression parity for the board-play VM path stays in
/// `BoardPlayViewModelTests` (unchanged behavior via the new methods); these
/// tests hit the data-layer methods directly against a fresh in-memory
/// `AppDatabase.makeTestInstance()`.
final class AppDatabaseSyncEnqueueTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id,
            email: "test@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
        try db.saveUser(user)
    }

    private func makeTask(
        _ id: String,
        userId: String = "u1",
        type: TaskType = .normal,
        maxCount: Int? = nil,
        isCounter: Bool = false
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Task \(id)",
            description: nil,
            type: type,
            action: nil,
            unit: nil,
            maxCount: maxCount,
            operatorType: type == .compound ? .and : nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            completedAt: nil,
            currentCount: nil,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: nil,
            baseline: nil,
            lastSyncedCount: nil,
            createdInWizard: false,
            isCounter: isCounter
        )
    }

    private func makeBoard(id: String, userId: String = "u1", status: BoardStatus = .active) -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": status.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int = 0, col: Int = 0) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id,
            boardId: boardId,
            taskId: taskId,
            row: row,
            col: col,
            isCenter: false,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
    }

    private func makeLink(id: String, parent: String, child: String, index: Int) -> CompoundChild {
        let now = AppDatabase.currentTimestamp()
        return CompoundChild(
            id: id,
            compoundTaskId: parent,
            childTaskId: child,
            childIndex: index,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    private func syncRows(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.fetchPendingSyncItems()
    }

    private func count(_ rows: [SyncQueueItem], type: String, op: SyncOperationType) -> Int {
        rows.filter { $0.entityType == type && $0.operationType == op }.count
    }

    // MARK: - createTaskAndEnqueue

    func test_createTaskAndEnqueue_writesTaskAndSyncRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.createTaskAndEnqueue(makeTask("t1"), now: now)

        XCTAssertNotNil(try db.fetchTask(id: "t1"))
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "t1" && $0.operationType == .create })
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
    }

    // MARK: - createTaskWithPairedChildrenAndEnqueue

    func test_createTaskWithPairedChildren_writesAllRowsAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let parent = makeTask("p1", type: .compound)
        let c1 = makeTask("c1")
        let c2 = makeTask("c2")
        let l1 = makeLink(id: "l1", parent: "p1", child: "c1", index: 0)
        let l2 = makeLink(id: "l2", parent: "p1", child: "c2", index: 1)

        try db.createTaskWithPairedChildrenAndEnqueue(
            task: parent, childTasks: [c1, c2], childLinks: [l1, l2], now: now
        )

        XCTAssertNotNil(try db.fetchTask(id: "p1"))
        XCTAssertNotNil(try db.fetchTask(id: "c1"))
        XCTAssertNotNil(try db.fetchTask(id: "c2"))
        let rows = try syncRows(db)
        // parent + 2 children = 3 task creates; 2 compoundChildren creates.
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 3)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 2)
    }

    // MARK: - createCompoundAndEnqueue

    func test_createCompoundAndEnqueue_newChildrenAndExistingRef() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // An existing-library child already in GRDB (referenced by id only).
        try db.saveTask(makeTask("existing"))

        let parent = makeTask("cp1", type: .compound)
        let newChild = makeTask("newc")
        let linkNew = makeLink(id: "ln", parent: "cp1", child: "newc", index: 0)
        let linkExisting = makeLink(id: "le", parent: "cp1", child: "existing", index: 1)

        try db.createCompoundAndEnqueue(
            parent: parent,
            newChildTasks: [newChild],
            childLinks: [linkNew, linkExisting],
            now: now
        )

        XCTAssertNotNil(try db.fetchTask(id: "cp1"))
        XCTAssertNotNil(try db.fetchTask(id: "newc"))
        let rows = try syncRows(db)
        // parent + newChild = 2 task creates (existing child is NOT re-created).
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 2)
        XCTAssertFalse(rows.contains { $0.entityType == "tasks" && $0.entityId == "existing" && $0.operationType == .create },
                       "existing-library child must not be re-created")
        // Both links enqueued.
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 2)
    }

    // MARK: - createCompoundAndEnqueue — P5 goal-less-counter child guard

    func test_createCompoundAndEnqueue_existingGoalLessCounterChild_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // An existing-library child that is a goal-less counter (COUNTING +
        // isCounter + no maxCount) — nothing evaluable to contribute.
        try db.saveTask(makeTask("goalless", type: .counting, maxCount: nil, isCounter: true))

        let parent = makeTask("cp2", type: .compound)
        let link = makeLink(id: "lg", parent: "cp2", child: "goalless", index: 0)

        XCTAssertThrowsError(
            try db.createCompoundAndEnqueue(parent: parent, newChildTasks: [], childLinks: [link], now: now)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                message.contains("goal-less counter tasks cannot be compound children"),
                "unexpected error message: \(message)"
            )
        }
        // Nothing should have been written — the guard runs before any write.
        XCTAssertNil(try db.fetchTask(id: "cp2"))
    }

    func test_createCompoundAndEnqueue_existingPromotedCounterChild_succeeds() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // A promoted counter (isCounter + maxCount) is unaffected by the guard.
        try db.saveTask(makeTask("promoted", type: .counting, maxCount: 50, isCounter: true))

        let parent = makeTask("cp3", type: .compound)
        let link = makeLink(id: "lp", parent: "cp3", child: "promoted", index: 0)

        try db.createCompoundAndEnqueue(parent: parent, newChildTasks: [], childLinks: [link], now: now)

        XCTAssertNotNil(try db.fetchTask(id: "cp3"))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 1)
    }

    func test_createTaskWithPairedChildren_existingGoalLessCounterChild_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.saveTask(makeTask("goalless2", type: .counting, maxCount: nil, isCounter: true))

        let parent = makeTask("p2", type: .compound)
        // Reference an existing goal-less counter with no paired new child task.
        let link = makeLink(id: "l3", parent: "p2", child: "goalless2", index: 0)

        XCTAssertThrowsError(
            try db.createTaskWithPairedChildrenAndEnqueue(task: parent, childTasks: [], childLinks: [link], now: now)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("goal-less counter tasks cannot be compound children"))
        }
        XCTAssertNil(try db.fetchTask(id: "p2"))
    }

    // MARK: - completeTaskOrchestrated

    func test_completeTaskOrchestrated_writesTaskBoardTaskBoardAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1")
        try db.saveBoardTask(bt)
        let now = AppDatabase.currentTimestamp()

        // Windowed Completion — the VM now passes a completion INTENT; the DB
        // layer appends a TaskEvent + stamps the lifetime cache.
        let board = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        let results = try db.completeTaskOrchestrated(
            board: board, taskId: "t1", intent: .setCompleted(true), boardTask: bt, now: now
        )

        // Task cache stamped complete; the authored stamp bumps version 1 → 2.
        let t1 = try XCTUnwrap(try db.fetchTask(id: "t1"))
        XCTAssertTrue(t1.isCompleted)
        XCTAssertEqual(t1.version, 2)
        // A completion TaskEvent was appended + enqueued.
        XCTAssertTrue(try syncRows(db).contains { $0.entityType == "taskEvents" && $0.operationType == .create })

        // BoardTask version bumped.
        let btAfter = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertEqual(btAfter.version, 2)

        // Board stats recomputed: t1 + FREE center = 2 completed on a 3×3.
        let b1 = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        XCTAssertEqual(b1.completedTasks, 2)

        // Returned cascade map carries the current board.
        XCTAssertNotNil(results["b1"])

        // Sync rows: task update + boardTask update + board update.
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "t1" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boardTasks" && $0.entityId == "bt1" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == "b1" && $0.operationType == .update })
    }

    func test_completeTaskOrchestrated_activatesDraftBoard() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "bd", status: .draft))
        try db.saveTask(makeTask("t1"))
        let bt = makeBoardTask(id: "btd", boardId: "bd", taskId: "t1")
        try db.saveBoardTask(bt)
        let now = AppDatabase.currentTimestamp()

        let board = try XCTUnwrap(try db.fetchBoard(id: "bd"))
        _ = try db.completeTaskOrchestrated(
            board: board, taskId: "t1", intent: .setCompleted(true), boardTask: bt, now: now
        )

        // Draft flipped to active (2/9 completed is not GREENLOG, so it stays active).
        let after = try XCTUnwrap(try db.fetchBoard(id: "bd"))
        XCTAssertEqual(after.status, .active)
    }

    // MARK: - toggleCompoundChildFallback

    func test_toggleCompoundChildFallback_writesChildAndCascade() throws {
        let db = try makeDb()
        try seedUser(db)
        // A compound parent placed on a board; the child is NOT placed.
        try db.saveBoard(makeBoard(id: "b1"))
        let parent = makeTask("cp", type: .compound)
        let child = makeTask("ch")
        try db.saveTask(parent)
        try db.saveTask(child)
        try db.write { db in try self.makeLink(id: "lk", parent: "cp", child: "ch", index: 0).save(db) }
        try db.saveBoardTask(makeBoardTask(id: "btp", boardId: "b1", taskId: "cp"))
        let now = AppDatabase.currentTimestamp()

        let board = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        let results = try db.toggleCompoundChildFallback(
            childTaskId: "ch", desiredCompleted: true,
            windowStart: board.startDate, boardId: "b1", now: now
        )

        let chAfter = try XCTUnwrap(try db.fetchTask(id: "ch"))
        XCTAssertTrue(chAfter.isCompleted)

        // The board carrying the parent compound is in the cascade set.
        XCTAssertNotNil(results["b1"])

        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "ch" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == "b1" && $0.operationType == .update })
    }

    // MARK: - saveWizardBoard

    func test_saveWizardBoard_freshCreate_writesBoardTasksPendingAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let board = makeBoard(id: "wb")
        let bt1 = makeBoardTask(id: "wbt1", boardId: "wb", taskId: "pending1", row: 0, col: 0)
        let pending = PendingTaskPayload(
            task: makeTask("pending1"),
            childTasks: [],
            childLinks: []
        )

        try db.saveWizardBoard(
            board: board, boardTasks: [bt1], pendingTasks: [pending], isUpdate: false, now: now
        )

        XCTAssertNotNil(try db.fetchBoard(id: "wb"))
        XCTAssertNotNil(try db.fetchTask(id: "pending1"))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 1)
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
    }

    func test_saveWizardBoard_update_deletesOldTasksEnqueuesDeletes() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Seed an existing board with one old placement (both referenced
        // tasks must exist to satisfy the board_tasks.taskId foreign key).
        try db.saveBoard(makeBoard(id: "wb2"))
        try db.saveTask(makeTask("tX"))
        try db.saveTask(makeTask("tY"))
        try db.saveBoardTask(makeBoardTask(id: "old-bt", boardId: "wb2", taskId: "tX"))

        var board = makeBoard(id: "wb2")
        board.version = 2
        let newBt = makeBoardTask(id: "new-bt", boardId: "wb2", taskId: "tY", row: 1, col: 1)

        try db.saveWizardBoard(
            board: board, boardTasks: [newBt], pendingTasks: [], isUpdate: true, now: now
        )

        // Old placement soft-deleted (tombstoned), new placement present and LIVE.
        let livePlacements = try db.read {
            try BoardTask
                .filter(Column("boardId") == "wb2" && Column("isDeleted") == false)
                .fetchAll($0)
        }
        XCTAssertEqual(livePlacements.map { $0.id }, ["new-bt"])
        let oldBt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "old-bt") })
        XCTAssertTrue(oldBt.isDeleted)
        XCTAssertNotNil(oldBt.deletedAt)
        XCTAssertEqual(oldBt.version, 2)

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .update), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 1)
    }

    // MARK: - saveWizardBoard: derivation pass (bingo-pipeline hardening item 2)
    //
    // Before the fix, stats were hand-init'd to 0 (or preserved from the prior
    // draft row) instead of derived from the just-written placements — a board
    // placing an already-in-window-complete task, or with a FREE center, would
    // store + sync wrong stats until the next app-open self-heal.

    func test_saveWizardBoard_freshCreate_derivesStatsFromWindowedCompleteTaskAndFreeCenter() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Pre-existing library task, already complete WITHIN the new board's
        // window (an in-window completion event — not just the lifetime cache,
        // which windowed derivation never trusts).
        try db.saveTask(makeTask("done1"))
        try db.write { txn in
            try TaskEvent(
                id: "ev1", userId: "u1", taskId: "done1", kind: .completion, delta: nil,
                occurredAt: "2026-06-15T00:00:00.000", boardId: nil,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }

        // `makeBoard` defaults `centerSquareType` to FREE (3×3, so the center
        // auto-fills) — this exercises both halves of the item-2 test note in
        // one board: an already-windowed-complete placed task AND a FREE
        // center both landing in the derived count.
        let board = makeBoard(id: "wb-derive")
        let bt = makeBoardTask(id: "wbt-derive", boardId: "wb-derive", taskId: "done1", row: 0, col: 0)

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [], isUpdate: false, now: now
        )

        let saved = try XCTUnwrap(try db.fetchBoard(id: "wb-derive"))
        XCTAssertEqual(
            saved.completedTasks, 2,
            "derivation output (placed complete task + FREE center auto-fill), not the hand-init 0"
        )
    }

    func test_saveWizardBoard_draftToActiveResume_derivesStatsAtActivation() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.saveTask(makeTask("done2"))
        try db.write { txn in
            try TaskEvent(
                id: "ev2", userId: "u1", taskId: "done2", kind: .completion, delta: nil,
                occurredAt: "2026-06-15T00:00:00.000", boardId: nil,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }

        // First save: a DRAFT with nothing placed yet — only the FREE center
        // auto-fill counts.
        var draft = makeBoard(id: "wb-resume", status: .draft)
        try db.saveWizardBoard(board: draft, boardTasks: [], pendingTasks: [], isUpdate: false, now: now)
        XCTAssertEqual(try db.fetchBoard(id: "wb-resume")?.completedTasks, 1)

        // Resume the draft and save it ACTIVE with the complete task now
        // placed — activation must derive from the just-written placements,
        // not preserve/hand-init a stale value.
        draft.status = .active
        draft.version = 2
        let bt = makeBoardTask(id: "wbt-resume", boardId: "wb-resume", taskId: "done2", row: 0, col: 0)
        try db.saveWizardBoard(board: draft, boardTasks: [bt], pendingTasks: [], isUpdate: true, now: now)

        let activated = try XCTUnwrap(try db.fetchBoard(id: "wb-resume"))
        XCTAssertEqual(
            activated.completedTasks, 2,
            "derived from the just-written placements at activation, not a hand-init/preserved value"
        )
        XCTAssertNotNil(activated.activatedAt, "activation instant stamped")
    }

    // MARK: - spawnRecurringBoard

    private func seedSpawnTasks(_ db: AppDatabase, count n: Int) throws -> [String] {
        var ids: [String] = []
        for i in 0..<n {
            let id = "seed\(i)"
            try db.saveTask(makeTask(id))
            ids.append(id)
        }
        return ids
    }

    /// Builds a template already in the migrated shape (`poolIds: [pool]`,
    /// `manualTaskIds: []`, `removedTaskIds: []`) — mints and saves the
    /// backing `Pool` directly against `db` so `spawnRecurringBoard`'s
    /// `PoolMix.resolveMix` call resolves the same task ids `seedIds`
    /// used to resolve to pre-P1. A template with no `poolIds` would
    /// resolve to an EMPTY mix post-P1 (spawn never falls back to
    /// `seedTaskIds` — see `RecurringBoardTemplate`'s "seedTaskIds end
    /// state" doc), so every spawn-path test needs a real pool.
    private func makeTemplate(_ db: AppDatabase, id: String, seedIds: [String]) throws -> RecurringBoardTemplate {
        let now = AppDatabase.currentTimestamp()
        let pool = Pool(
            id: "\(id)-pool", userId: "u1", name: "\(id) pool", taskIds: seedIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
        return RecurringBoardTemplate(
            id: id,
            userId: "u1",
            name: "Weekly",
            timeframe: .monthly,
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: false,
            seedTaskIds: seedIds,
            poolIds: [pool.id],
            manualTaskIds: [],
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
    }

    func test_spawnRecurringBoard_writesBoardTasksTemplateAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        // 3×3 FREE center → 8 fillable cells.
        let seedIds = try seedSpawnTasks(db, count: 8)
        let template = try makeTemplate(db, id: "tpl", seedIds: seedIds)
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        let spawn = PendingTemplateSpawn(
            template: template,
            windowStart: "2026-07-01T00:00:00.000",
            windowEnd: "2026-07-31T23:59:59.999",
            suggestedName: "Weekly — Jul"
        )
        let boardId = AppDatabase.generateUUID()
        let outcome = try db.spawnRecurringBoard(spawn, boardId: boardId, now: now)

        guard case .spawned(let bid, let tid, _) = outcome else {
            return XCTFail("expected .spawned, got \(outcome)")
        }
        XCTAssertEqual(bid, boardId)
        XCTAssertEqual(tid, "tpl")

        XCTAssertNotNil(try db.fetchBoard(id: boardId))
        let placements = try db.read { try BoardTask.filter(Column("boardId") == boardId).fetchAll($0) }
        XCTAssertEqual(placements.count, 8)

        // Template's lastSpawnedWindowKey updated.
        let tplAfter = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl"))
        XCTAssertEqual(tplAfter.lastSpawnedWindowKey, "2026-07-01T00:00:00.000")

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 8)
        XCTAssertEqual(count(rows, type: "recurringBoardTemplates", op: .update), 1)
    }

    func test_spawnRecurringBoard_poolTooSmall_skipsNoWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        let seedIds = try seedSpawnTasks(db, count: 2) // < 8 required
        let template = try makeTemplate(db, id: "tpl2", seedIds: seedIds)
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        let spawn = PendingTemplateSpawn(
            template: template,
            windowStart: "2026-07-01T00:00:00.000",
            windowEnd: "2026-07-31T23:59:59.999",
            suggestedName: "Weekly — Jul"
        )
        let boardId = AppDatabase.generateUUID()
        let outcome = try db.spawnRecurringBoard(spawn, boardId: boardId, now: now)

        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("expected .skipped, got \(outcome)")
        }
        XCTAssertEqual(reason, .poolTooSmall)

        // No board written; no sync rows enqueued (txn rolled back).
        XCTAssertNil(try db.fetchBoard(id: boardId))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 0)
    }

    // MARK: - Tombstone guards on placement write paths (PR-1 review)

    /// A placement tombstoned by a concurrent cross-device delete must not be
    /// resurrected/mutated by a stale edit-session swap or rearrange — the
    /// write paths guard on `isDeleted` and silently no-op.
    func test_tombstonedPlacement_isImmuneToSwapAndRearrange() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "tg1"))
        try db.saveTask(makeTask("tA"))
        try db.saveTask(makeTask("tB"))
        try db.saveBoardTask(makeBoardTask(id: "bt-dead", boardId: "tg1", taskId: "tA"))

        // Tombstone it (the PR-1 soft-delete path).
        try db.removeBoardTaskFromBoard("bt-dead")
        let deadV = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") }).version

        // Swap must no-op: taskId unchanged, version unchanged, still tombstoned.
        try db.updateBoardTaskAndCascade(boardTaskId: "bt-dead", newTaskId: "tB")
        var bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") })
        XCTAssertTrue(bt.isDeleted)
        XCTAssertEqual(bt.taskId, "tA", "swap on a tombstone must not mutate it")
        XCTAssertEqual(bt.version, deadV, "swap on a tombstone must not bump version")

        // Rearrange must skip it: position unchanged.
        try db.updateBoardTaskPositions(
            boardId: "tg1",
            moves: [AppDatabase.BoardTaskPositionMove(boardTaskId: "bt-dead", row: 2, col: 2)]
        )
        bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") })
        XCTAssertEqual(bt.row, 0)
        XCTAssertEqual(bt.col, 0)
        XCTAssertEqual(bt.version, deadV, "rearrange on a tombstone must not bump version")
    }
}
