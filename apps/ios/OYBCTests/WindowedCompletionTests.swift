import XCTest
import GRDB
@testable import OYBC

/// DB-integration coverage for Windowed Completion PR B (iOS flip), the twin of
/// web's `taskEventWrites` / `taskEventMigration` / `taskEventPull` /
/// `spawnRollover` Vitest suites (docs/WINDOWED_COMPLETION.md §Testing matrix,
/// iOS row). Exercises the event write choke points, the lifetime cache stamp
/// formula, the migration backfill helper, the batched pull recompute, and the
/// spawned-board-empty-across-rollover regression — all against an in-memory
/// `AppDatabase.makeTestInstance()`.
@MainActor
final class WindowedCompletionTests: XCTestCase {

    private let userId = "u1"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(
        _ id: String, type: TaskType = .normal, title: String = "Task",
        maxCount: Int? = nil, isCompleted: Bool = false, completedAt: String? = nil,
        currentCount: Int? = nil, sharedCounterId: String? = nil, baseline: Int? = nil,
        version: Int = 1
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: title, description: nil, type: type,
            action: nil, unit: nil, maxCount: maxCount ?? (type == .counting ? 5 : nil),
            operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: completedAt ?? (isCompleted ? now : nil),
            currentCount: currentCount, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: version, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: sharedCounterId, baseline: baseline,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// A single-square active board whose window is June 2026.
    private func makeBoard(id: String, startDate: String = "2026-06-01T00:00:00.000",
                           endDate: String = "2026-06-30T23:59:59.999",
                           status: BoardStatus = .active, size: Int = 1) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board", "status": status.rawValue,
            "boardSize": size, "timeframe": Timeframe.monthly.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: 0, col: 0,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func makeEvent(_ id: String, taskId: String, kind: TaskEventKind,
                           delta: Int? = nil, occurredAt: String, isDeleted: Bool = false) -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: kind, delta: delta,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func liveEvents(_ db: AppDatabase, taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) }
    }

    private func fetchTask(_ db: AppDatabase, _ id: String) throws -> Task { try db.fetchTask(id: id)! }

    // MARK: - 1. Normal complete → event + cache stamp + windowed cascade

    func test_normalComplete_appendsEventStampsCacheAndCascades() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let t = makeTask("t1", type: .normal)
        try db.saveTask(t)
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1")
        try db.saveBoardTask(bt)

        let now = "2026-06-15T12:00:00.000"
        _ = try db.completeTaskOrchestrated(
            board: db.fetchBoard(id: "b1")!, taskId: "t1",
            intent: .setCompleted(true), boardTask: bt, now: now
        )

        let events = try liveEvents(db, taskId: "t1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .completion)
        XCTAssertEqual(events.first?.occurredAt, now)

        let after = try fetchTask(db, "t1")
        XCTAssertTrue(after.isCompleted, "lifetime cache stamped complete")
        XCTAssertEqual(after.completedAt, now)
        XCTAssertGreaterThan(after.version, 1, "authored stamp bumps Task.version")

        // Board cascade recomputed the 1x1 board to greenlog.
        let board = try db.fetchBoard(id: "b1")!
        XCTAssertEqual(board.completedTasks, 1)
    }

    // MARK: - 2. Window-scoped un-complete: pre-window preserved, in-window tombstoned

    func test_uncomplete_isWindowScoped_multiEvent() throws {
        let db = try makeDb(); try seedUser(db)
        let board = makeBoard(id: "b1")
        try db.saveBoard(board)
        try db.saveTask(makeTask("t1", type: .normal))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1")
        try db.saveBoardTask(bt)

        // A completion BEFORE the window (May) + one INSIDE the window (June).
        try db.write { db in
            try makeEvent("e-pre", taskId: "t1", kind: .completion, occurredAt: "2026-05-10T00:00:00.000").save(db)
            try makeEvent("e-in", taskId: "t1", kind: .completion, occurredAt: "2026-06-10T00:00:00.000").save(db)
        }

        // Un-complete in the June board context → tombstones only in-window.
        _ = try db.completeTaskOrchestrated(
            board: db.fetchBoard(id: "b1")!, taskId: "t1",
            intent: .setCompleted(false), boardTask: bt, now: "2026-06-15T00:00:00.000"
        )

        let live = try liveEvents(db, taskId: "t1")
        XCTAssertEqual(live.map(\.id), ["e-pre"], "pre-window completion preserved; in-window tombstoned")

        // Windowed read for the June board is now incomplete...
        let windowed = try db.windowedState(db_taskId: "t1", windowStart: board.startDate)
        XCTAssertFalse(windowed.isCompleted)

        // ...but the LIFETIME cache still reflects the surviving pre-window completion.
        XCTAssertTrue(try fetchTask(db, "t1").isCompleted, "lifetime cache honors the pre-window completion")
    }

    // MARK: - 3. Standalone counting increment → +1 event, windowed count

    func test_countingIncrement_appendsPositiveDeltaEvent() throws {
        let db = try makeDb(); try seedUser(db)
        let board = makeBoard(id: "b1")
        try db.saveBoard(board)
        try db.saveTask(makeTask("c1", type: .counting, maxCount: 3))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "c1")
        try db.saveBoardTask(bt)

        // Two increments to windowed target 1 then 2.
        _ = try db.completeTaskOrchestrated(board: db.fetchBoard(id: "b1")!, taskId: "c1",
            intent: .setWindowedCount(1), boardTask: bt, now: "2026-06-02T00:00:00.000")
        _ = try db.completeTaskOrchestrated(board: db.fetchBoard(id: "b1")!, taskId: "c1",
            intent: .setWindowedCount(2), boardTask: bt, now: "2026-06-03T00:00:00.000")

        let events = try liveEvents(db, taskId: "c1")
        XCTAssertEqual(events.filter { $0.kind == .increment }.count, 2)
        XCTAssertEqual(events.compactMap(\.delta).reduce(0, +), 2)

        let windowed = try db.windowedState(db_taskId: "c1", windowStart: board.startDate)
        XCTAssertEqual(windowed.count, 2)
        XCTAssertEqual(try fetchTask(db, "c1").currentCount, 2, "lifetime cache == lifetime sum")
    }

    // MARK: - 4. Context-split decrement: board-context gated negative delta

    func test_countingDecrement_boardContext_gatedNegativeDelta() throws {
        let db = try makeDb(); try seedUser(db)
        let board = makeBoard(id: "b1")
        try db.saveBoard(board)
        try db.saveTask(makeTask("c1", type: .counting, maxCount: 5))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "c1")
        try db.saveBoardTask(bt)

        // Windowed count → 2, then decrement to 1.
        _ = try db.completeTaskOrchestrated(board: db.fetchBoard(id: "b1")!, taskId: "c1",
            intent: .setWindowedCount(2), boardTask: bt, now: "2026-06-02T00:00:00.000")
        _ = try db.completeTaskOrchestrated(board: db.fetchBoard(id: "b1")!, taskId: "c1",
            intent: .setWindowedCount(1), boardTask: bt, now: "2026-06-03T00:00:00.000")

        var windowed = try db.windowedState(db_taskId: "c1", windowStart: board.startDate)
        XCTAssertEqual(windowed.count, 1)

        // Attempt to over-decrement past 0 → delta gated at -windowedCount; sum floors at 0.
        _ = try db.completeTaskOrchestrated(board: db.fetchBoard(id: "b1")!, taskId: "c1",
            intent: .setWindowedCount(-5), boardTask: bt, now: "2026-06-04T00:00:00.000")
        windowed = try db.windowedState(db_taskId: "c1", windowStart: board.startDate)
        XCTAssertEqual(windowed.count, 0, "window sum can't go negative from a local gesture")
    }

    // MARK: - 5. Cache stamp formula (deterministic recompute from events)

    func test_computeTaskCachesFromEvents_countingAndNormal() throws {
        let counting = makeTask("c1", type: .counting, maxCount: 5)
        let cEvents = [
            makeEvent("a", taskId: "c1", kind: .increment, delta: 3, occurredAt: "2026-06-01T00:00:00.000"),
            makeEvent("b", taskId: "c1", kind: .increment, delta: 2, occurredAt: "2026-06-05T00:00:00.000"),
            makeEvent("c", taskId: "c1", kind: .increment, delta: 1, occurredAt: "2026-05-01T00:00:00.000", isDeleted: true),
        ]
        let cCache = AppDatabase.computeTaskCachesFromEvents(task: counting, events: cEvents)
        XCTAssertEqual(cCache.currentCount, 5, "lifetime sum ignores the tombstoned +1")
        XCTAssertTrue(cCache.isCompleted)
        XCTAssertEqual(cCache.completedAt, "2026-06-05T00:00:00.000", "latest live increment occurredAt")

        let normal = makeTask("n1", type: .normal)
        let nEvents = [
            makeEvent("x", taskId: "n1", kind: .completion, occurredAt: "2026-06-01T00:00:00.000"),
            makeEvent("y", taskId: "n1", kind: .completion, occurredAt: "2026-06-09T00:00:00.000"),
        ]
        let nCache = AppDatabase.computeTaskCachesFromEvents(task: normal, events: nEvents)
        XCTAssertTrue(nCache.isCompleted)
        XCTAssertEqual(nCache.completedAt, "2026-06-09T00:00:00.000")
    }

    // MARK: - 6. Backfill helper: carve-out + determinism

    func test_buildBackfillTaskEvent_carveOutAndDeterminism() throws {
        // Normal completed → one completion event, occurredAt = completedAt.
        let normal = makeTask("n1", type: .normal, isCompleted: true, completedAt: "2026-06-01T00:00:00.000")
        let nEvent = buildBackfillTaskEvent(task: normal)
        XCTAssertEqual(nEvent?.kind, .completion)
        XCTAssertEqual(nEvent?.occurredAt, "2026-06-01T00:00:00.000")

        // Counting source with count → one increment, delta = currentCount.
        let counting = makeTask("c1", type: .counting, maxCount: 5, currentCount: 3)
        let cEvent = buildBackfillTaskEvent(task: counting)
        XCTAssertEqual(cEvent?.kind, .increment)
        XCTAssertEqual(cEvent?.delta, 3)

        // Derived counter (sharedCounterId set) → skipped (carve-out).
        let derived = makeTask("d1", type: .counting, maxCount: 5, currentCount: 3,
                               sharedCounterId: "c1", baseline: 0)
        XCTAssertNil(buildBackfillTaskEvent(task: derived))

        // Compound → skipped.
        let compound = makeTask("cmp1", type: .compound)
        XCTAssertNil(buildBackfillTaskEvent(task: compound))

        // Determinism: same task → same kind-qualified id, twice.
        XCTAssertEqual(buildBackfillTaskEvent(task: normal)?.id, buildBackfillTaskEvent(task: normal)?.id)
        XCTAssertNotEqual(nEvent?.id, cEvent?.id, "kind-qualified ids don't collide across types")
    }

    // MARK: - 7. Batched pull recompute + events-before-task skip

    func test_applyTaskEventsBatch_recomputesCachesAndCascades() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1", type: .normal))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))
        let sut = SyncService(database: db)

        // A completion event arrives via pull for a LOCAL task.
        let raw: [String: Any] = [
            "id": AppDatabase.generateUUID(), "userId": userId, "taskId": "t1",
            "kind": "completion", "occurredAt": "2026-06-10T00:00:00.000",
            "createdAt": "2026-06-10T00:00:00.000", "updatedAt": "2026-06-10T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        // An event for an UNKNOWN task (events-before-task) — upserts but is skipped.
        let orphan: [String: Any] = [
            "id": AppDatabase.generateUUID(), "userId": userId, "taskId": "missing",
            "kind": "completion", "occurredAt": "2026-06-10T00:00:00.000",
            "createdAt": "2026-06-10T00:00:00.000", "updatedAt": "2026-06-10T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let result = sut.applyTaskEventsBatch(userId: userId, rawDocs: [raw, orphan])
        XCTAssertEqual(result.pulled, 2, "both event rows upsert")

        // The local task's cache recomputed from the pulled event (NO version bump).
        let t = try fetchTask(db, "t1")
        XCTAssertTrue(t.isCompleted)
        XCTAssertEqual(t.version, 1, "pull recompute is a non-authored write")

        // Orphan event upserted but its (missing) task can't be recomputed — no crash.
        let orphanRows = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_events WHERE taskId = 'missing'") ?? 0 }
        XCTAssertEqual(orphanRows, 1)

        // Board cascade recomputed windowed → greenlog on the 1x1 board.
        XCTAssertEqual(try db.fetchBoard(id: "b1")!.completedTasks, 1)
    }

    // MARK: - 8. Derived-task pull leaves propagation-stamped cache + latch intact (C1)

    func test_derivedTaskPull_leavesCacheAndLatchIntact() throws {
        let db = try makeDb(); try seedUser(db)
        // A derived counter with a latched (complete) propagation-stamped cache.
        try db.saveTask(makeTask("d1", type: .counting, maxCount: 5, isCompleted: true,
                                 completedAt: "2026-06-01T00:00:00.000", currentCount: 5,
                                 sharedCounterId: "src", baseline: 0))
        let sut = SyncService(database: db)

        // A (nonsensical) event arrives for the derived task id — recompute must SKIP
        // it (isEventOwningTask == false) so the propagation cache + latch survive.
        let raw: [String: Any] = [
            "id": AppDatabase.generateUUID(), "userId": userId, "taskId": "d1",
            "kind": "increment", "delta": 1, "occurredAt": "2026-06-10T00:00:00.000",
            "createdAt": "2026-06-10T00:00:00.000", "updatedAt": "2026-06-10T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        _ = sut.applyTaskEventsBatch(userId: userId, rawDocs: [raw])

        let d = try fetchTask(db, "d1")
        XCTAssertTrue(d.isCompleted, "derived latch preserved")
        XCTAssertEqual(d.currentCount, 5, "propagation-stamped cache untouched")
    }

    // MARK: - 9. Spawned board starts empty across a window rollover (THE original bug)

    func test_spawnedBoardEmptyAcrossRollover() throws {
        let db = try makeDb(); try seedUser(db)
        // A task completed in JUNE (event in June window).
        try db.saveTask(makeTask("t1", type: .normal, isCompleted: true, completedAt: "2026-06-10T00:00:00.000"))
        try db.write { db in
            try makeEvent("e-june", taskId: "t1", kind: .completion, occurredAt: "2026-06-10T00:00:00.000").save(db)
        }

        // The SAME task is placed on a JULY board (later window) — the respawn case.
        let july = makeBoard(id: "b-july", startDate: "2026-07-01T00:00:00.000", endDate: "2026-07-31T23:59:59.999")

        // Windowed resolution for the July board → INCOMPLETE (no in-window event),
        // even though the lifetime cache is complete. This is the bleed fix.
        let windowed = try db.windowedState(db_taskId: "t1", windowStart: july.startDate)
        XCTAssertFalse(windowed.isCompleted, "June completion does not bleed into the July window")

        // Control: the June board still sees it complete.
        let june = makeBoard(id: "b-june")
        XCTAssertTrue(try db.windowedState(db_taskId: "t1", windowStart: june.startDate).isCompleted)
    }

    // MARK: - 10. Spawn-time derivation pass — stored stats == derivation output (WC PR D)

    func test_spawnRecurringBoard_storedStatsEqualDerivationOutput() throws {
        let db = try makeDb(); try seedUser(db)

        // 3×3 FREE center → 8 seed tasks. Each is lifetime-complete with a
        // completion event in JUNE — BEFORE the JULY spawn window.
        var seedIds: [String] = []
        try db.write { db in
            for i in 0..<8 {
                let id = "seed\(i)"
                try self.makeTask(id, type: .normal, isCompleted: true,
                                  completedAt: "2026-06-10T00:00:00.000").save(db)
                try self.makeEvent("e-\(id)", taskId: id, kind: .completion,
                                   occurredAt: "2026-06-10T00:00:00.000").save(db)
                seedIds.append(id)
            }
        }

        let now = AppDatabase.currentTimestamp()
        // P1 — spawn resolves via the pool mix, not seedTaskIds directly;
        // mint a backing Pool so the template is in the migrated shape.
        let pool = Pool(
            id: "pool-d", userId: userId, name: "Daily pool", taskIds: seedIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
        let template = RecurringBoardTemplate(
            id: "tpl-d", userId: userId, name: "Daily", timeframe: .monthly,
            boardSize: 3, centerSquareType: .free, isRandomized: false,
            seedTaskIds: seedIds, poolIds: [pool.id], manualTaskIds: [], removedTaskIds: [],
            isActive: true,
            createdAt: now, updatedAt: now, version: 1
        )
        try db.saveRecurringBoardTemplate(template)

        let boardId = AppDatabase.generateUUID()
        let outcome = try db.spawnRecurringBoard(
            PendingTemplateSpawn(
                template: template,
                windowStart: "2026-07-01T00:00:00.000",
                windowEnd: "2026-07-31T23:59:59.999",
                suggestedName: "Daily — Jul"
            ),
            boardId: boardId, now: now
        )
        guard case .spawned = outcome else { return XCTFail("expected .spawned, got \(outcome)") }

        // Read the persisted board + placements straight out of the DB — NO
        // cascade in between — and recompute. The invariant: the spawn path
        // itself wrote derivation output, so a fresh recomputation matches.
        try db.read { db in
            let board = try XCTUnwrap(try Board.fetchOne(db, key: boardId))
            let placements = try BoardTask.filter(Column("boardId") == boardId).fetchAll(db)
            let windowContext = try AppDatabase.buildWindowContext(db: db)
            let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }
            var taskById: [String: Task] = [:]
            for t in try Task.fetchAll(db) { taskById[t.id] = t }
            let allBoards = try Board.filter(Column("isDeleted") == false).fetchAll(db)

            let derived = DerivationPass.computeBoardStatsUpdate(
                board: board, boardTasksOnBoard: placements,
                childrenByCompound: childrenByCompound, taskById: taskById,
                allBoards: allBoards, windowContext: windowContext
            )
            XCTAssertEqual(board.completedTasks, derived.completedTasks)
            XCTAssertEqual(board.linesCompleted, derived.linesCompleted)
            XCTAssertEqual(board.completedLineIds ?? [], derived.completedLineIds)
            // Fresh window: only the FREE center auto-fills, no bled task squares.
            XCTAssertEqual(board.completedTasks, 1)
            XCTAssertEqual(board.linesCompleted, 0)
        }
    }

    /// Regression (issue #375): the task-driven cascade family must derive
    /// board stats over COLLISION-RESOLVED placement rows, exactly like the
    /// placement-driven family and the render path. Seeds a duplicate
    /// placement (two live rows at one cell — pre-PR-2 corruption / offline
    /// union shape) where the RESOLVER'S LOSER is a completed task, then
    /// fires the main board-tap completion path. Pre-fix, the raw-filter
    /// derivation counted the loser's completion too (completedTasks == 2);
    /// post-fix only the winner row and the newly completed square count.
    func test_completeTaskOrchestrated_derivesOverResolvedPlacements_issue375() throws {
        let db = try makeDb()
        try seedUser(db)

        let board = makeBoard(id: "b1", size: 2)
        try db.saveBoard(board)
        try db.saveTask(makeTask("t-win"))
        try db.saveTask(makeTask("t-lose"))
        try db.saveTask(makeTask("t-tap"))

        // Duplicate cell (0,0): identical version + updatedAt, so the winner
        // rule falls through to lowest id → "bt-a" (t-win, incomplete) wins;
        // "bt-b" (t-lose, completed in-window) is the loser the raw filter
        // would wrongly count.
        let fixed = "2026-06-01T00:00:00.000"
        func placement(_ id: String, taskId: String, row: Int, col: Int) -> BoardTask {
            BoardTask(
                id: id, boardId: "b1", taskId: taskId, row: row, col: col,
                isCenter: false, createdAt: fixed, updatedAt: fixed,
                lastSyncedAt: nil, version: 1
            )
        }
        try db.saveBoardTask(placement("bt-a", taskId: "t-win", row: 0, col: 0))
        try db.saveBoardTask(placement("bt-b", taskId: "t-lose", row: 0, col: 0))
        let tapRow = placement("bt-c", taskId: "t-tap", row: 1, col: 1)
        try db.saveBoardTask(tapRow)

        // The loser's task IS completed within the window — the bait.
        try db.write { database in
            try makeEvent("e-lose", taskId: "t-lose", kind: .completion,
                          occurredAt: "2026-06-05T00:00:00.000").save(database)
        }

        _ = try db.completeTaskOrchestrated(
            board: db.fetchBoard(id: "b1")!, taskId: "t-tap",
            intent: .setCompleted(true), boardTask: tapRow,
            now: "2026-06-15T12:00:00.000"
        )

        let after = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(
            after.completedTasks, 1,
            "cascade must count only the resolved winner rows — the duplicate loser's completed task (raw-filter derivation) would make this 2"
        )
    }
}

// Test-only convenience to resolve windowed state through the DB read path.
private extension AppDatabase {
    func windowedState(db_taskId taskId: String, windowStart: String?) throws -> TaskWindowState {
        try read { db in try Self.windowedStateForTest(db: db, taskId: taskId, windowStart: windowStart) }
    }
    static func windowedStateForTest(db: Database, taskId: String, windowStart: String?) throws -> TaskWindowState {
        try windowedState(db: db, taskId: taskId, windowStart: windowStart)
    }
}
