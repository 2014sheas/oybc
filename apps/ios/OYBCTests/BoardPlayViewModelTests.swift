import XCTest
import GRDB
@testable import OYBC

/// Tests for `BoardPlayViewModel` (B2-I1) against an injected in-memory
/// `AppDatabase.makeTestInstance()`.
///
/// Covers:
///   1. `reload()` populates all seven published arrays from the DB.
///   2. `reload()` with a nil userId leaves the user-scoped arrays empty
///      (matching the pre-refactor `loadTaskData` behavior) while the
///      board-scoped + global fetches still populate.
///   3. `reloadBoardTasksAndTaskData()` refreshes placements + task data but
///      never fetches the board record (partial scope preserved).
///   4. `boardChanged(to:)` re-points the view model at a new board.
///   5. The `reloadToken` stale-result guard: after two rapid reloads the
///      newest one wins and the stale result does not clobber it.
///
/// Reloads dispatch onto a background queue and apply on the main queue, so
/// the tests are `@MainActor` and pump the run loop via `waitUntil` — full
/// async ordering isn't controllable in XCTest, so the stale-guard test
/// asserts the observable invariant (last-write-wins, stable) rather than the
/// private token value.
@MainActor
final class BoardPlayViewModelTests: XCTestCase {

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

    /// Build a Board via JSON (the same path production uses).
    private func makeBoard(id: String, userId: String = "u1") -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000",
            "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(_ id: String, userId: String = "u1") -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Task \(id)",
            description: nil,
            type: .normal,
            action: nil,
            unit: nil,
            maxCount: nil,
            operatorType: nil,
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
            createdInWizard: false
        )
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int, col: Int) -> BoardTask {
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

    private func makeCompoundChild(parent: String, child: String, idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(parent)-\(child)-\(idx)",
            compoundTaskId: parent,
            childTaskId: child,
            childIndex: idx,
            createdAt: "2026-06-21T00:00:00.000",
            updatedAt: "2026-06-21T00:00:00.000",
            version: 1,
            isDeleted: false
        )
    }

    private func makeTemplate(id: String = "tmpl-1", userId: String = "u1") -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: userId,
            name: "Weekly",
            timeframe: .weekly,
            boardSize: 3,
            centerSquareType: .free,
            centerSquareCustomName: nil,
            isRandomized: false,
            seedTaskIds: ["t1", "t2"],
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: "2026-06-21T00:00:00.000",
            updatedAt: "2026-06-21T00:00:00.000",
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    /// Seed: user u1, board b1 (2 placements), board b2 (1 placement),
    /// tasks t1/t2, one compound-child link (t1→t2), one template.
    private func seedWorkspace(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt-b1-1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-b1-2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt-b2-1", boardId: "b2", taskId: "t1", row: 0, col: 0))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "t1", child: "t2", idx: 0).insert(database)
            try makeTemplate().insert(database)
        }
    }

    /// Pump the main run loop until `predicate` holds or `timeout` elapses.
    /// Lets the `DispatchQueue.main.async` apply blocks run. Returns whether
    /// the predicate held.
    ///
    /// 30s, not 2s: a green run returns on the first poll after the async
    /// apply (~ms), so the generous budget costs nothing when healthy — but
    /// the 2s default flaked twice on loaded CI runners (issue #283,
    /// `test_handleAddTaskToCell_createsPlacement` on PRs #282/#285).
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 30,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - 1. reload populates everything

    func test_reload_populatesAllPublishedArrays() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { vm.board != nil }, "reload never applied")

        XCTAssertEqual(vm.board?.id, "b1")
        XCTAssertEqual(vm.boardTasks.count, 2, "b1 has 2 placements")
        XCTAssertEqual(vm.allTasks.count, 2)
        XCTAssertEqual(vm.allCompoundChildren.count, 1)
        XCTAssertEqual(vm.allBoardsInWorkspace.count, 2)
        XCTAssertEqual(vm.allTemplatesInWorkspace.count, 1)
        XCTAssertEqual(vm.allBoardTasksInWorkspace.count, 3, "3 placements across b1+b2")
    }

    // MARK: - 2. nil userId

    func test_reload_withNilUserId_leavesUserScopedArraysEmpty() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        // nil userId mirrors the view constructing the VM before its
        // @EnvironmentObject AuthService is available.
        let vm = BoardPlayViewModel(boardId: "b1", userId: nil, database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { vm.board != nil }, "board fetch is not user-scoped and should still apply")

        // Board + its placements + the global tables load regardless of userId.
        XCTAssertEqual(vm.board?.id, "b1")
        XCTAssertEqual(vm.boardTasks.count, 2)
        XCTAssertEqual(vm.allCompoundChildren.count, 1)
        XCTAssertEqual(vm.allBoardTasksInWorkspace.count, 3)
        // User-scoped fetches resolve to empty.
        XCTAssertTrue(vm.allTasks.isEmpty)
        XCTAssertTrue(vm.allBoardsInWorkspace.isEmpty)
        XCTAssertTrue(vm.allTemplatesInWorkspace.isEmpty)
    }

    // MARK: - 3. partial reload never touches board

    func test_reloadBoardTasksAndTaskData_doesNotFetchBoard() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reloadBoardTasksAndTaskData()

        XCTAssertTrue(waitUntil { !vm.boardTasks.isEmpty }, "partial reload never applied")

        XCTAssertNil(vm.board, "partial reload must not fetch the board record")
        XCTAssertEqual(vm.boardTasks.count, 2)
        XCTAssertEqual(vm.allTasks.count, 2)
    }

    // MARK: - 4. boardChanged

    func test_boardChanged_switchesBoardAndReloads() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && vm.boardTasks.count == 2 })

        vm.boardChanged(to: "b2")
        XCTAssertTrue(waitUntil { vm.board?.id == "b2" })

        XCTAssertEqual(vm.board?.id, "b2")
        XCTAssertEqual(vm.boardTasks.count, 1, "b2 has 1 placement")
    }

    // MARK: - 5. stale-result guard

    func test_staleGuard_newestReloadWins() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)

        // Two rapid reloads with no wait in between: reload() (token N, board b1)
        // then boardChanged(to: "b2") (token N+1, board b2). The token guard
        // must drop the older b1 result so the newest (b2) wins.
        vm.reload()
        vm.boardChanged(to: "b2")

        XCTAssertTrue(waitUntil { vm.board?.id == "b2" }, "newest reload result never applied")
        XCTAssertEqual(vm.board?.id, "b2")
        XCTAssertEqual(vm.boardTasks.count, 1)

        // Spin the run loop further so any late (stale) b1 apply would have a
        // chance to fire; the guard must have dropped it, so state stays b2.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(vm.board?.id, "b2", "a stale earlier reload clobbered the newer result")
        XCTAssertEqual(vm.boardTasks.count, 1)
    }

    // MARK: - B2-I2 interaction-write fixtures

    private func makeCountingTask(
        _ id: String,
        userId: String = "u1",
        maxCount: Int = 3,
        currentCount: Int? = nil,
        sharedCounterId: String? = nil,
        isCounter: Bool = false
    ) -> Task {
        var t = makeTask(id, userId: userId)
        t.type = .counting
        t.action = "Do"
        t.unit = "reps"
        t.maxCount = maxCount
        t.currentCount = currentCount
        t.sharedCounterId = sharedCounterId
        t.isCounter = isCounter
        return t
    }

    /// A 1×1 board with a non-FREE center (`.none`), so a single placed task
    /// is both the only square AND the whole board — the minimal fixture for
    /// driving a board to full GREENLOG with one write.
    private func makeOneCellBoard(id: String, userId: String = "u1") -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": BoardStatus.active.rawValue,
            "boardSize": 1,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue,
            "isRandomized": false,
            "totalTasks": 1,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000",
            "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeCompoundTask(_ id: String, userId: String = "u1") -> Task {
        var t = makeTask(id, userId: userId)
        t.type = .compound
        t.operatorType = .and
        return t
    }

    /// Reads a single Task straight from the DB (post-write committed state).
    /// Non-throwing so it flattens cleanly into `waitUntil` predicates.
    private func dbTask(_ db: AppDatabase, _ id: String) -> Task? {
        (try? db.fetchTasks(userId: "u1"))?.first { $0.id == id }
    }

    /// Loads the view model and blocks until its published arrays are populated,
    /// so the handlers (which read `taskMap` / `board` / `boardTasks`) have data.
    private func loadedVM(_ db: AppDatabase, boardId: String) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: boardId, userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == boardId && !vm.allTasks.isEmpty }
        return vm
    }

    // MARK: - 6. normal complete-toggle

    func test_handleNormalTap_completesTask_updatesBoardStats_writesSync() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")

        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "t1" })
        vm.handleNormalTap(boardTask: bt)

        // DB outcome (committed by the background write).
        XCTAssertTrue(waitUntil { self.dbTask(db, "t1")?.isCompleted == true },
                      "normal tap never persisted completion")
        let t1 = try XCTUnwrap(dbTask(db, "t1"))
        XCTAssertTrue(t1.isCompleted)
        XCTAssertNotNil(t1.completedAt)
        XCTAssertEqual(t1.version, 2, "version should bump on completion write")

        // Board stats recomputed by the cascade. b1 is 3×3 with a FREE center,
        // which counts as a completed square, so completing t1 yields 2
        // (t1 + free center).
        let b1 = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(b1.completedTasks, 2)

        // Sync rows: task update + boardTask bump + board cascade update.
        let sync = try db.fetchPendingSyncItems()
        XCTAssertTrue(sync.contains { $0.entityType == "tasks" && $0.entityId == "t1" })
        XCTAssertTrue(sync.contains { $0.entityType == "boardTasks" && $0.entityId == bt.id })
        XCTAssertTrue(sync.contains { $0.entityType == "boards" && $0.entityId == "b1" })

        // Published-array refresh: the reload tail re-fetched the completed task.
        XCTAssertTrue(waitUntil { vm.taskMap["t1"]?.isCompleted == true })
        XCTAssertFalse(vm.isProcessing, "isProcessing should reset after the write tail")
    }

    func test_handleNormalTap_secondTap_uncompletes() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")

        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "t1" })
        vm.handleNormalTap(boardTask: bt)
        XCTAssertTrue(waitUntil { vm.taskMap["t1"]?.isCompleted == true && !vm.isProcessing })

        vm.handleNormalTap(boardTask: bt)
        XCTAssertTrue(waitUntil { self.dbTask(db, "t1")?.isCompleted == false && !vm.isProcessing })
        let t1 = try XCTUnwrap(dbTask(db, "t1"))
        XCTAssertFalse(t1.isCompleted)
        XCTAssertNil(t1.completedAt)
    }

    // MARK: - 7. standalone counting increment / decrement

    func test_handleCountingTap_standalone_incrementsCount() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("c1", maxCount: 3, currentCount: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c1" })
        let task = try XCTUnwrap(vm.taskMap["c1"])

        vm.handleCountingTap(boardTask: bt, task: task)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c1")?.currentCount == 1 })
        let c1 = try XCTUnwrap(dbTask(db, "c1"))
        XCTAssertEqual(c1.currentCount, 1)
        XCTAssertFalse(c1.isCompleted, "1 of 3 is not complete")
    }

    func test_handleCountingTap_standalone_completesAtGoal_thenDecrementUncompletes() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("c1", maxCount: 2, currentCount: 1))
        // Windowed Completion — the windowed count derives from events, so seed a
        // backing +1 increment event in the board window (as the migration would
        // have backfilled) so the square starts at a windowed 1.
        try db.write { db in
            try TaskEvent(
                id: "seed-c1", userId: "u1", taskId: "c1", kind: .increment, delta: 1,
                occurredAt: "2026-06-25T00:00:00.000", boardId: nil,
                createdAt: "2026-06-25T00:00:00.000", updatedAt: "2026-06-25T00:00:00.000",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c1" })

        // Increment 1 -> 2 reaches goal => completed.
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]))
        XCTAssertTrue(waitUntil {
            self.dbTask(db, "c1")?.isCompleted == true
                && vm.taskMap["c1"]?.isCompleted == true
                && vm.taskMap["c1"]?.currentCount == 2
                && !vm.isProcessing
        }, "completion never landed in the published task map")
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c1")).currentCount, 2)

        // Decrement 2 -> 1 un-completes (standalone legacy path). This reads
        // vm.taskMap["c1"] below, so the wait above must guarantee the
        // PUBLISHED state — not just the DB + isProcessing — reflects the
        // increment, or the decrement could act on a stale currentCount.
        vm.handleCountingDecrement(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]))
        XCTAssertTrue(waitUntil { self.dbTask(db, "c1")?.currentCount == 1 && !vm.isProcessing })
        let c1 = try XCTUnwrap(dbTask(db, "c1"))
        XCTAssertEqual(c1.currentCount, 1)
        XCTAssertFalse(c1.isCompleted)
    }

    // MARK: - 8. shared-counter increment (source + linked fan-out)

    func test_sharedCounterIncrement_incrementsSource_andEmitsCreditToast() throws {
        let db = try makeDb()
        try seedUser(db)
        // Two active boards; source counter on b1, linked derived counter on b2.
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))
        try db.saveTask(makeCountingTask("c-src", maxCount: 5, currentCount: 0))
        try db.saveTask(makeCountingTask("c-lnk", maxCount: 5, currentCount: 0, sharedCounterId: "c-src"))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-lnk", boardId: "b2", taskId: "c-lnk", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        let task = try XCTUnwrap(vm.taskMap["c-src"])

        // Source task (has a linked task pointing at it) routes through the
        // shared-counter increment path.
        vm.handleCountingTap(boardTask: bt, task: task)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 1 },
                      "shared increment never bumped the source count")
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-src")).currentCount, 1)

        // b2 (holding the linked member, active, != current board) was credited,
        // so the view model publishes a one-shot credit-toast flash event.
        XCTAssertTrue(waitUntil { vm.flashEvent?.creditToast != nil },
                      "credit toast flash event never published for the OTHER board")
        let payload = try XCTUnwrap(vm.flashEvent?.creditToast)
        XCTAssertTrue(payload.message.contains("Board b2"))
        // R3: pinned copy contract — "+{N} {counterName} — also counted on
        // {board list}." `c-src` has action "Do" + unit "reps" (no title
        // override), so the pair-derived counter name is "Reps" — proves
        // this reads `formatCounterName` and NOT the stored title ("Task
        // c-src"), which is exactly what R3's `counterDisplayName` fix targets.
        XCTAssertEqual(payload.message, "+1 Reps — also counted on Board b2.")
        XCTAssertEqual(payload.sourceTaskId, "c-src")
        XCTAssertEqual(payload.amount, 1)
    }

    // MARK: - 8c. R3 board-play touchpoints — amount routing, default
    // persistence, and Undo (name-source fallback is exercised above by
    // `test_sharedCounterIncrement_incrementsSource_andEmitsCreditToast`'s
    // "Reps" assertion).

    /// A custom amount logged from board-play both (a) applies the exact
    /// amount to the source's count and (b) persists as the counter's new
    /// `defaultLogAmount` when `persistAsDefault: true` — mirrors R2 Detail's
    /// "amount just used becomes the new default" rule.
    func test_handleCountingTap_customAmount_persistsAsDefault_whenRequested() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // isCounter: true — a P5 zero-link promoted source, so this routes
        // through `runSharedCounterIncrement` (the ONLY path that persists a
        // default). A plain standalone counting task never touches
        // `defaultLogAmount` at all, which would make this test pass
        // vacuously regardless of correctness.
        try db.saveTask(makeCountingTask("c-src", maxCount: 100, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        let task = try XCTUnwrap(vm.taskMap["c-src"])

        vm.handleCountingTap(boardTask: bt, task: task, amount: 7, persistAsDefault: true)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 7 && !vm.isProcessing })
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-src")).defaultLogAmount, 7,
                       "explicit custom amount must persist as the counter's new default")
    }

    /// Global Constraints: "One-tap paths (+1 chip / plain tap / +default) do
    /// NOT change the default; only an explicit custom # amount does." A
    /// one-tap +1 (persistAsDefault: false, the default parameter value)
    /// must never overwrite an already-set default.
    func test_handleCountingTap_oneTapAmount_neverPersistsAsDefault() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // isCounter: true — see the sibling test above for why this must
        // route through the shared-counter engine to be a meaningful assertion.
        var task = makeCountingTask("c-src", maxCount: 100, currentCount: 0, isCounter: true)
        task.defaultLogAmount = 10
        try db.saveTask(task)
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        let loadedTask = try XCTUnwrap(vm.taskMap["c-src"])

        // A quick "+1" tap — persistAsDefault stays false (the parameter default).
        vm.handleCountingTap(boardTask: bt, task: loadedTask, amount: 1)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 1 && !vm.isProcessing })
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-src")).defaultLogAmount, 10,
                       "a one-tap +1 must never overwrite the counter's persisted default")
    }

    /// The decrement engine clamps at 0 — the credited toast's amount (and
    /// therefore what `Undo` will reverse) must reflect the CLAMPED
    /// `effectiveDelta`, not the raw requested amount (Global Constraints:
    /// "the toast's own displayed delta must match what Undo will reverse").
    func test_handleCountingDecrement_toastAmount_matchesClampedEffectiveDelta() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))
        try db.saveTask(makeCountingTask("c-src", maxCount: 20, currentCount: 3))
        try db.saveTask(makeCountingTask("c-lnk", maxCount: 20, currentCount: 3, sharedCounterId: "c-src"))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-lnk", boardId: "b2", taskId: "c-lnk", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        let task = try XCTUnwrap(vm.taskMap["c-src"])

        // Request 10 off a source that only has 3 — clamps to effectiveDelta 3.
        vm.handleCountingDecrement(boardTask: bt, task: task, amount: 10)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 0 && !vm.isProcessing })
        XCTAssertTrue(waitUntil { vm.flashEvent?.creditToast != nil },
                      "credit toast flash event never published for the OTHER board")
        let payload = try XCTUnwrap(vm.flashEvent?.creditToast)
        XCTAssertEqual(payload.amount, 3, "toast amount must be the CLAMPED delta, not the requested 10")
        XCTAssertTrue(payload.message.contains("−3"), "message must show the clamped amount")
    }

    /// `undoSharedCounterLog` (the credited toast's Undo pill) reverses the
    /// source's last log entry via `AppDatabase.undoLastCounterLog` and
    /// refreshes the published state.
    func test_undoSharedCounterLog_reversesLastEntry_andReloads() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // isCounter: true — `undoSharedCounterLog` is only ever wired to the
        // shared-counter credited toast's Undo pill, so exercise it against
        // the actual shared-counter engine's lifetime event (boardId nil),
        // not the standalone windowed path's board-scoped event.
        try db.saveTask(makeCountingTask("c-src", maxCount: 100, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        let task = try XCTUnwrap(vm.taskMap["c-src"])
        vm.handleCountingTap(boardTask: bt, task: task, amount: 10)
        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 10 && !vm.isProcessing })

        vm.undoSharedCounterLog(sourceTaskId: "c-src")

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 0 },
                      "Undo never reversed the +10 entry")
        XCTAssertTrue(waitUntil { vm.taskMap["c-src"]?.currentCount == 0 },
                      "Undo's reload never refreshed the published task map")
    }

    // MARK: - 8a. P5 zero-link `isCounter` tap-routing (review fix — no direct
    // test existed for the `|| task.isCounter == true` disjunct added to
    // `handleCountingTap` / `handleCountingDecrement`'s source detection).
    //
    // These mirror `test_arrivalDetection_promotedZeroLinkCounter_stillDetectsArrival`'s
    // fixture: a promoted STANDALONE counting task (`isCounter: true`, no
    // linked members at all) placed on a single board. Because
    // `allTasks.contains { $0.sharedCounterId == task.id }` is false here (no
    // sibling links to it), only the `isCounter` branch can route this task
    // through the shared-counter engine — so a passing test proves that
    // specific disjunct, not the membership branch already covered by
    // `test_sharedCounterIncrement_incrementsSource_andEmitsCreditToast`.
    //
    // Observable proof of routing: the shared-counter engine
    // (`incrementSharedCounter`/`decrementSharedCounter`) always calls
    // `insertIncrementEventRaw(..., boardId: nil, ...)` (lifetime event, no
    // board scope), whereas the legacy standalone path's `setWindowedCount`
    // intent calls `appendIncrementEvent(..., boardId: board.id, ...)` (window-
    // scoped). Asserting the persisted `TaskEvent.boardId == nil` therefore
    // distinguishes "went through the shared-counter engine" from "fell
    // through to the legacy windowed path" — exactly the branch under test.

    func test_handleCountingTap_zeroLinkIsCounter_routesThroughSharedCounterEngine() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // Zero-link: no other task's sharedCounterId points at "c-solo".
        try db.saveTask(makeCountingTask("c-solo", maxCount: 5, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-solo", boardId: "b1", taskId: "c-solo", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-solo" })
        let task = try XCTUnwrap(vm.taskMap["c-solo"])
        XCTAssertFalse(vm.allTasks.contains { $0.sharedCounterId == "c-solo" },
                        "fixture must have zero linked members — only isCounter can route this")

        vm.handleCountingTap(boardTask: bt, task: task)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-solo")?.currentCount == 1 && !vm.isProcessing },
                      "shared-counter increment never bumped the zero-link isCounter source")
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-solo")).currentCount, 1)

        let events = try db.fetchNonDeletedTaskEvents(userId: "u1").filter { $0.taskId == "c-solo" }
        XCTAssertEqual(events.count, 1, "exactly one lifetime increment event should have been appended")
        XCTAssertNil(events.first?.boardId,
                     "shared-counter engine appends a lifetime event (boardId nil); a non-nil boardId would mean this fell through to the legacy windowed path")
        XCTAssertEqual(events.first?.delta, 1)
    }

    func test_handleCountingDecrement_zeroLinkIsCounter_routesThroughSharedCounterEngine() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // Zero-link, seeded above 0 so the decrement has something to remove.
        try db.saveTask(makeCountingTask("c-solo", maxCount: 5, currentCount: 2, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-solo", boardId: "b1", taskId: "c-solo", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-solo" })
        let task = try XCTUnwrap(vm.taskMap["c-solo"])
        XCTAssertFalse(vm.allTasks.contains { $0.sharedCounterId == "c-solo" },
                        "fixture must have zero linked members — only isCounter can route this")

        vm.handleCountingDecrement(boardTask: bt, task: task)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-solo")?.currentCount == 1 && !vm.isProcessing },
                      "shared-counter decrement never dropped the zero-link isCounter source, or threw")
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-solo")).currentCount, 1)

        let events = try db.fetchNonDeletedTaskEvents(userId: "u1").filter { $0.taskId == "c-solo" }
        XCTAssertEqual(events.count, 1, "exactly one lifetime decrement event should have been appended")
        XCTAssertNil(events.first?.boardId,
                     "shared-counter engine appends a lifetime event (boardId nil); a non-nil boardId would mean this fell through to the legacy windowed path")
        XCTAssertEqual(events.first?.delta, -1)
    }

    // MARK: - 8b. GREENLOG flash gating on the completion transition (issue #272)

    /// Reachable bug this guards: tapping "+" on an overshoot counting square
    /// while the board is already fully GREENLOG must NOT re-fire the
    /// celebration. `runOrchestration` must derive the flash from the
    /// transition-gated `BPVCascadeBoardResult.didAutoComplete`, not the
    /// ungated `isGreenlogNow` (which stays `true` on every subsequent write
    /// once the board is complete, per the standing overshoot invariant —
    /// see `feedback_counter_overshoot_is_valid` — counting squares keep
    /// incrementing past `maxCount` without clamping).
    func test_handleCountingTap_overshootOnAlreadyGreenlogBoard_doesNotRefireGreenlogFlash() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeOneCellBoard(id: "b1"))
        try db.saveTask(makeCountingTask("c1", maxCount: 1, currentCount: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c1" })

        // First tap: 0 -> 1 reaches maxCount, completing the task AND the
        // only square on the board => a real not-complete -> complete
        // transition. This is the legitimate GREENLOG fire.
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]))
        XCTAssertTrue(waitUntil {
            self.dbTask(db, "c1")?.currentCount == 1
                && vm.taskMap["c1"]?.currentCount == 1
                && !vm.isProcessing
        }, "completion never landed in the published task map")
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).status, .completed,
                       "the single square completing should auto-complete the 1x1 board")
        XCTAssertEqual(vm.flashEvent?.risoNotification, "GREENLOG!",
                       "the real completion transition should fire the celebration")
        let firstFlashId = try XCTUnwrap(vm.flashEvent?.id)

        // Second tap: overshoot 1 -> 2. task.isCompleted stays true (already
        // true), board.status is already .completed (not .active), so
        // BPVCascadeBoardResult.didAutoComplete is false even though
        // isGreenlogNow recomputes to true again. The flash must NOT re-fire.
        // This reads vm.taskMap["c1"] below, so the wait above must guarantee
        // the PUBLISHED state reflects the first tap, not just DB + isProcessing.
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]))
        XCTAssertTrue(waitUntil { self.dbTask(db, "c1")?.currentCount == 2 && !vm.isProcessing },
                      "overshoot increment should still persist past maxCount (no clamp)")
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).status, .completed,
                       "board remains completed across the overshoot write")

        // No new flash event was published: emitFlash's guard requires a
        // non-nil risoNotification or creditToast, and the gated derivation
        // yields nil for this no-transition write, so the event stays the
        // *same* one-shot instance from the first tap (same id).
        XCTAssertEqual(vm.flashEvent?.id, firstFlashId,
                       "GREENLOG flash must not re-fire on a no-transition overshoot write")
    }

    // MARK: - 9. compound child toggle (fallback cascade path)

    func test_handleCompoundChildToggle_notPlaced_persistsChild_andCascades() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        // Compound parent placed on b1; its child is NOT placed on any board, so
        // the toggle takes the fallback cascade branch (the one that calls the
        // moved bpvRunCrossBoardCascade / bpvMakeSyncItem helpers).
        try db.saveTask(makeCompoundTask("cmp"))
        try db.saveTask(makeTask("child1"))
        try db.saveBoardTask(makeBoardTask(id: "bt-cmp", boardId: "b1", taskId: "cmp", row: 0, col: 0))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "cmp", child: "child1", idx: 0).insert(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        let child = try XCTUnwrap(vm.taskMap["child1"])
        XCTAssertNil(vm.boardTasks.first { $0.taskId == "child1" }, "child must not be placed on this board")

        vm.handleCompoundChildToggle(childTask: child)

        XCTAssertTrue(waitUntil { self.dbTask(db, "child1")?.isCompleted == true && !vm.isProcessing })
        let c = try XCTUnwrap(dbTask(db, "child1"))
        XCTAssertTrue(c.isCompleted)

        let sync = try db.fetchPendingSyncItems()
        XCTAssertTrue(sync.contains { $0.entityType == "tasks" && $0.entityId == "child1" })
        XCTAssertTrue(sync.contains { $0.entityType == "boards" && $0.entityId == "b1" },
                      "cascade should have re-saved the board holding the compound")
    }

    // MARK: - 10. cell add

    func test_handleAddTaskToCell_createsPlacement() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        // No placements yet — add t1 into an empty cell.

        let vm = loadedVM(db, boardId: "b1")
        vm.handleAddTaskToCell(taskId: "t1", row: 1, col: 2)

        XCTAssertTrue(waitUntil {
            (try? db.fetchBoardTasks(boardId: "b1"))?.contains {
                $0.taskId == "t1" && $0.row == 1 && $0.col == 2
            } == true
                && vm.boardTasks.contains { $0.taskId == "t1" && $0.row == 1 && $0.col == 2 }
                && !vm.isProcessing
        }, "placement was never created and published")
        XCTAssertTrue(vm.boardTasks.contains { $0.taskId == "t1" && $0.row == 1 && $0.col == 2 })
    }

    // MARK: - 11. B2-I3 edit-mode draft layer

    func test_seedEditDraft_populatesDraftFieldsFromBoard() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0), t2@(0,1); monthly, FREE center
        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)

        vm.seedEditDraft(from: board)

        XCTAssertEqual(vm.editName, "Board b1")
        XCTAssertEqual(vm.editTimeframe, .monthly)
        XCTAssertEqual(vm.editCenterType, .free)
        XCTAssertEqual(vm.editSubMode, .editTasks)
        // One squares-draft entry per live placement, seeded staged == original.
        XCTAssertEqual(vm.editSquaresDraft.count, 2)
        let d00 = try XCTUnwrap(vm.editSquaresDraft["0-0"])
        XCTAssertEqual(d00.originalTaskId, "t1")
        XCTAssertEqual(d00.stagedTaskId, "t1")
        XCTAssertTrue(vm.editTaskOverrides.isEmpty)
        XCTAssertNil(vm.editRearrangeCells)
        // No staged edits yet → dirty count is zero (Save pill stays disabled).
        XCTAssertEqual(vm.editSquaresEditCount, 0)
    }

    func test_editDraftMutation_bumpsEditSquaresEditCount() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editSquaresEditCount, 0, "fresh draft is clean")

        // Replace the task in cell (0,0): t1 → t2. Dirty count reflects it.
        vm.handleEditCellReplace(cellKey: "0-0", newTaskId: "t2")
        XCTAssertEqual(vm.editSquaresEditCount, 1)
        XCTAssertEqual(vm.editDraftBoardTasks.first { $0.row == 0 && $0.col == 0 }?.taskId, "t2",
                       "draft board tasks overlay the staged replacement")

        // A task-field override is a second, independent staged edit.
        vm.handleEditTaskOverride(
            taskId: "t2",
            patch: .init(title: "Renamed t2", type: .normal, action: "", unit: "", maxCount: nil)
        )
        XCTAssertEqual(vm.editSquaresEditCount, 2)
        XCTAssertEqual(vm.editDraftTaskMap["t2"]?.title, "Renamed t2",
                       "draft task map overlays the staged override")
    }

    func test_handleEditRemove_dropsCellFromDraft_andBumpsEditCount() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0), t2@(0,1)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editSquaresEditCount, 0, "fresh draft is clean")
        XCTAssertEqual(vm.editSquaresDraft.count, 2)

        // Stage a removal of the (0,1) cell (t2). No DB write yet.
        vm.handleEditRemove(cellKey: "0-1")

        XCTAssertNil(vm.editSquaresDraft["0-1"], "removed cell is dropped from the draft")
        XCTAssertEqual(vm.editSquaresEditCount, 1, "staged removal counts as one edit")
        // No DB mutation until Save.
        XCTAssertTrue(try db.fetchBoardTasks(boardId: "b1").contains { $0.id == "bt-b1-2" },
                      "removal must not touch the DB before Save")
    }

    func test_editDraftBoardTasks_reflectsStagedRemoval() throws {
        // Regression (review Critical): the Edit-tasks grid renders from
        // `editDraftBoardTasks`; a staged removal must drop the cell (compactMap),
        // and removing every cell must yield [] — NOT the full original board.
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0) bt-b1-1, t2@(0,1) bt-b1-2
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editDraftBoardTasks.count, 2, "seeded draft renders both placements")

        vm.handleEditRemove(cellKey: "0-1")
        XCTAssertFalse(vm.editDraftBoardTasks.contains { $0.id == "bt-b1-2" },
                       "removed cell must disappear from the rendered grid, not persist")
        XCTAssertTrue(vm.editDraftBoardTasks.contains { $0.id == "bt-b1-1" })

        // Remove the last remaining square → the grid must be empty, not the full board.
        vm.handleEditRemove(cellKey: "0-0")
        XCTAssertTrue(vm.editDraftBoardTasks.isEmpty,
                      "all-removed draft renders an empty grid (guard must not resurrect originals)")
        XCTAssertEqual(vm.editSquaresEditCount, 2, "both removals still count as edits (Save enabled)")
    }

    func test_handleEditSave_commitsStagedRemoval() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0) bt-b1-1, t2@(0,1) bt-b1-2
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditRemove(cellKey: "0-1")
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        XCTAssertTrue(vm.handleEditSave(weekStartDay: "monday"), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        // bt-b1-2 soft-deleted (tombstoned) — excluded from the live fetch;
        // the surviving placement (t1) is untouched.
        let remaining = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertFalse(remaining.contains { $0.id == "bt-b1-2" }, "removed placement deleted on Save")
        XCTAssertTrue(remaining.contains { $0.id == "bt-b1-1" }, "kept placement survives")
    }

    func test_seedEditDraft_reseedDiscardsPriorDraftEdits() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)

        vm.seedEditDraft(from: board)
        vm.handleEditCellReplace(cellKey: "0-0", newTaskId: "t2")
        vm.handleEditTaskOverride(
            taskId: "t2",
            patch: .init(title: "X", type: .normal, action: "", unit: "", maxCount: nil)
        )
        XCTAssertEqual(vm.editSquaresEditCount, 2)

        // Re-entering edit mode re-seeds from the live board, discarding drafts.
        vm.seedEditDraft(from: board)
        XCTAssertEqual(vm.editSquaresEditCount, 0)
        XCTAssertTrue(vm.editTaskOverrides.isEmpty)
        XCTAssertNil(vm.editRearrangeCells)
    }

    func test_handleEditSave_commitsRename_replacement_andPosition_thenEmitsSaved() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))     // 3×3, FREE center, monthly, "Board b1"
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        // t1 at (0,0); (0,1) empty so a position move to (0,1) is unambiguous.
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: board)

        // 1. Rename.
        vm.editName = "Renamed b1"
        // 2. Replace t1 → t2 in cell (0,0).
        vm.handleEditCellReplace(cellKey: "0-0", newTaskId: "t2")
        // 3. Position move: seed rearrange cells, then move bt1 (slot 0) into the
        //    empty slot 1 = (0,1) by swapping the two array entries.
        vm.seedRearrangeCells(for: board)
        var cells = try XCTUnwrap(vm.editRearrangeCells)
        cells.swapAt(0, 1)
        vm.handleRearrange(newCells: cells)

        XCTAssertEqual(vm.editSquaresEditCount, 2, "one replacement + one position move")

        let started = vm.handleEditSave(weekStartDay: "monday")
        XCTAssertTrue(started, "save should dispatch when validation passes")

        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        // Board renamed.
        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.name, "Renamed b1")
        // Placement repointed t1 → t2 AND moved to (0,1).
        let bt = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt.taskId, "t2", "cell replacement committed")
        XCTAssertEqual(bt.row, 0)
        XCTAssertEqual(bt.col, 1, "position move committed")
    }

    func test_handleEditSave_blankName_doesNotStart() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.editName = "   "   // whitespace-only ⇒ invalid

        XCTAssertFalse(vm.handleEditSave(weekStartDay: "monday"),
                       "a blank name must not dispatch a commit")
    }

    func test_handleEditArchive_setsBoardArchived_thenEmitsArchived() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let vm = loadedVM(db, boardId: "b1")

        vm.handleEditArchive()

        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .archived },
                      "handleEditArchive never emitted .archived")
        let b = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(b.status, .archived)
    }

    // MARK: - 12. Shared Counters P3 — passive-completion arrival detection

    /// An isolated `UserDefaults` suite so the arrival store never pollutes
    /// `.standard` and each test starts from a clean baseline.
    private func makeIsolatedStore() -> CounterArrivalStore {
        let suite = "arrival-test-\(UUID().uuidString)"
        return CounterArrivalStore(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Seed: user u1, b1 (holds the SOURCE counter c-src) + b2 (holds a linked
    /// derived counter c-lnk → c-src), so c-src is a shared-counter source whose
    /// square on b1 participates in arrival detection.
    private func seedSharedCounterBoard(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))
        try db.saveTask(makeCountingTask("c-src", maxCount: 5, currentCount: 0))
        try db.saveTask(makeCountingTask("c-lnk", maxCount: 5, currentCount: 0, sharedCounterId: "c-src"))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-lnk", boardId: "b2", taskId: "c-lnk", row: 0, col: 0))
    }

    /// Simulate a log made ELSEWHERE (Counter Detail / another board): bump the
    /// source counter's `currentCount` straight in the DB while the board is not
    /// being observed.
    private func bumpSourceCount(_ db: AppDatabase, to value: Int) throws {
        var src = try XCTUnwrap(dbTask(db, "c-src"))
        src.currentCount = value
        src.version += 1
        try db.saveTask(src)
    }

    func test_arrivalDetection_afterElsewhereLog_emitsArrivalEventWithPayload() throws {
        let db = try makeDb()
        try seedSharedCounterBoard(db)
        let store = makeIsolatedStore()
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db, arrivalStore: store)

        // First open: seeds the baseline (c-src displayed 0) — first view never arrives.
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty })
        XCTAssertNil(vm.arrivalEvent, "first view must not arrive")

        // A log lands elsewhere while the board is closed.
        try bumpSourceCount(db, to: 3)

        // Reopen → detect against the seeded baseline → c-src arrived (3 > 0).
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.arrivalEvent != nil },
                      "arrival never published after an elsewhere log")
        let ev = try XCTUnwrap(vm.arrivalEvent)
        XCTAssertEqual(ev.totalArrivedSquares, 1)
        XCTAssertTrue(ev.arrivedTaskIds.contains("c-src"))
        XCTAssertEqual(ev.singleTaskName, "Task c-src")
        XCTAssertEqual(ev.arrivedCounters.first?.counterId, "c-src")
    }

    func test_arrivalDetection_reSnapshotAfterShown_suppressesSecondEvent() throws {
        let db = try makeDb()
        try seedSharedCounterBoard(db)
        let store = makeIsolatedStore()
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db, arrivalStore: store)

        // Seed baseline, log elsewhere, reopen → arrival fires (id captured).
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty })
        try bumpSourceCount(db, to: 3)
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.arrivalEvent != nil })
        let firstId = try XCTUnwrap(vm.arrivalEvent?.id)

        // Reopen again with NO further change. The after-shown re-snapshot moved
        // the baseline up to 3, so the acknowledged arrival must NOT re-fire.
        vm.markArrivalDetectionPending()
        vm.reload()
        // Spin the run loop so the reopen's apply + detect pass runs, then assert
        // the one-shot event is still the same instance (no new emission).
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(vm.arrivalEvent?.id, firstId,
                       "re-snapshot after shown must suppress a second arrival event")
    }

    /// P5 — a promoted STANDALONE counting task (no linked members, flagged
    /// `isCounter: true` via `promoteTaskToCounter`) must still participate in
    /// arrival detection: `sharedCounterArrivalSquares()`'s `|| task.isCounter
    /// == true` branch treats it as its own source (mirrors web
    /// `useBoardPlayData.ts:176`), so an elsewhere-log (e.g. a +1 from Counter
    /// Detail) still shows the arrival banner even though nothing links to it.
    func test_arrivalDetection_promotedZeroLinkCounter_stillDetectsArrival() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("c-solo", maxCount: 5, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-solo", boardId: "b1", taskId: "c-solo", row: 0, col: 0))

        let store = makeIsolatedStore()
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db, arrivalStore: store)

        // First open: seeds the baseline (c-solo displayed 0) — first view never arrives.
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty })
        XCTAssertNil(vm.arrivalEvent, "first view must not arrive")

        // Logged elsewhere (Counter Detail's +1) — no other task links to it.
        var solo = try XCTUnwrap(dbTask(db, "c-solo"))
        solo.currentCount = 2
        solo.version += 1
        try db.saveTask(solo)

        // Reopen → detect against the seeded baseline → c-solo arrived (2 > 0)
        // even though `allTasks.contains { $0.sharedCounterId == "c-solo" }`
        // is false (zero linked members) — only the `isCounter` branch makes
        // this fire.
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.arrivalEvent != nil },
                      "a zero-link isCounter task must still register as a shared-counter source")
        let ev = try XCTUnwrap(vm.arrivalEvent)
        XCTAssertEqual(ev.totalArrivedSquares, 1)
        XCTAssertTrue(ev.arrivedTaskIds.contains("c-solo"))
        XCTAssertEqual(ev.arrivedCounters.first?.counterId, "c-solo")
    }

    func test_arrivalStore_roundTripsPerBoard() {
        let store = makeIsolatedStore()
        XCTAssertEqual(store.lastSeen(boardId: "b1"), [:], "absent board is a first view")
        store.save(boardId: "b1", snapshot: ["t1": 3, "t2": 7])
        store.save(boardId: "b2", snapshot: ["t3": 1])
        XCTAssertEqual(store.lastSeen(boardId: "b1"), ["t1": 3, "t2": 7])
        XCTAssertEqual(store.lastSeen(boardId: "b2"), ["t3": 1])
        // Overwrite replaces the prior snapshot.
        store.save(boardId: "b1", snapshot: ["t1": 9])
        XCTAssertEqual(store.lastSeen(boardId: "b1"), ["t1": 9])
    }

    // MARK: - 13. Windowed Completion — edit/rearrange preview reads windowed,
    // not lifetime (review finding, sub-slice 3 follow-up; d16ff21 iOS parity)

    /// The exact regression `windowedIsCompleted(for:)` fixes: `BoardEditPanel`'s
    /// static grid + `RearrangeGrid` used to read `task.isCompleted` (the
    /// lifetime cache) directly, so a task completed in a PRIOR window bled
    /// green into the edit/rearrange preview of a board on a FRESH window —
    /// even though the live play grid (which already routes through
    /// `windowedState(forTaskId:)`) correctly showed it incomplete.
    func test_windowedIsCompleted_lifetimeCompleteTaskOnFreshWindow_reportsWindowedGrey() throws {
        let db = try makeDb()
        try seedUser(db)

        // A task lifetime-completed back in June (event + cache both stamped).
        var task = makeTask("t1")
        task.isCompleted = true
        task.completedAt = "2026-06-10T00:00:00.000"
        try db.saveTask(task)
        try db.dbQueue.write { database in
            try TaskEvent(
                id: "evt-june", userId: "u1", taskId: "t1", kind: .completion, delta: nil,
                occurredAt: "2026-06-10T00:00:00.000", boardId: nil,
                createdAt: "2026-06-10T00:00:00.000", updatedAt: "2026-06-10T00:00:00.000",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).insert(database)
        }

        // ...placed on a board whose window starts in JULY — a fresh spawn/reuse
        // with no completion event of its own.
        let julyDict: [String: Any] = [
            "id": "b-july", "userId": "u1", "name": "July", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-07-01T00:00:00.000", "endDate": "2026-07-31T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-07-01T00:00:00.000", "updatedAt": "2026-07-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let julyData = try JSONSerialization.data(withJSONObject: julyDict)
        let julyBoard = try JSONDecoder().decode(Board.self, from: julyData)
        try db.saveBoard(julyBoard)
        try db.saveBoardTask(makeBoardTask(id: "bt-july-1", boardId: "b-july", taskId: "t1", row: 0, col: 0))

        let vm = BoardPlayViewModel(boardId: "b-july", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b-july" && vm.allTasks.contains { $0.id == "t1" } })

        let liveTask = try XCTUnwrap(vm.taskMap["t1"])

        // Sanity: the lifetime cache itself is (correctly) still complete —
        // library/Tasks-tab surfaces should keep showing this task green.
        XCTAssertTrue(liveTask.isCompleted, "lifetime cache stays complete")

        // The fix: the edit-preview data path must report windowed-grey for
        // this fresh board window, not the stale lifetime-complete state.
        XCTAssertFalse(
            vm.windowedIsCompleted(for: liveTask),
            "edit/rearrange preview must report windowed-grey, not lifetime-complete"
        )

        // Cross-check against the same mechanism the live play grid uses —
        // both surfaces must agree.
        XCTAssertEqual(
            vm.windowedIsCompleted(for: liveTask),
            vm.windowedState(forTaskId: "t1").isCompleted,
            "edit-preview read and live-grid read must resolve identically"
        )
    }

    /// Derived (shared-counter-linked) counting tasks are carved out of
    /// windowed evaluation — they stay on their propagation-stamped lifetime
    /// cache in both the live grid and the edit preview.
    func test_windowedIsCompleted_derivedCountingTask_staysOnLifetimeCache() throws {
        let db = try makeDb()
        try seedUser(db)

        var derived = makeTask("d1")
        derived.type = .counting
        derived.maxCount = 5
        derived.sharedCounterId = "src"
        derived.isCompleted = true
        try db.saveTask(derived)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoardTask(makeBoardTask(id: "bt-d1", boardId: "b1", taskId: "d1", row: 0, col: 0))

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && vm.allTasks.contains { $0.id == "d1" } })

        let liveTask = try XCTUnwrap(vm.taskMap["d1"])
        XCTAssertTrue(
            vm.windowedIsCompleted(for: liveTask),
            "derived counting tasks are carved out — the preview reads the lifetime cache, unchanged"
        )
    }

    // MARK: - Item 3 (Board-integrity PR-4): single-transaction Save atomicity

    /// Board-integrity PR-4 (Item 3, docs/BOARD_INTEGRITY.md): `handleEditSave`
    /// now composes all five Save sub-ops into ONE `database.write {}`
    /// transaction. This test forces a THROW inside the task-override step
    /// (step 3) via a poisoned `tasks` row seeded directly with raw SQL (an
    /// undecodable `type` value — the same technique
    /// `SyncPullApplyTests.test_cascadeFailure_rollsBackUpsert` uses), so
    /// `Task.fetchAll(db)` inside `runBoardCascadeForTask` throws. Every
    /// cascade helper in this codebase does a full-table `Task.fetchAll`, so
    /// the board here is seeded with ZERO existing placements — this makes
    /// step 1 (`updateBoardAndCascade`) take its `guard !taskIds.isEmpty else
    /// { return }` early-out (no cascade fetch there, so no throw), deferring
    /// the actual throw to step 3, the only step this scenario exercises.
    /// Before this fix, each step ran in its OWN transaction, so step 1's
    /// rename would already have committed by the time step 3 failed; the
    /// fix makes step 1's commit conditional on the WHOLE Save succeeding.
    func test_handleEditSave_subOpThrows_rollsBackEntireTransaction() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))   // FREE center, 3×3, NO placements

        // A real task to stage an override for.
        try db.saveTask(makeTask("t-real"))

        // A poisoned Task row — undecodable `type` — that ANY cascade's
        // `Task.fetchAll(db)` will choke on.
        let now = AppDatabase.currentTimestamp()
        try db.write { txn in
            try txn.execute(
                sql: "INSERT INTO tasks (id, userId, title, type, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["t-poison", "u1", "Poison", "not_a_real_type", now, now]
            )
        }

        let vm = loadedVM(db, boardId: "b1")
        let boardBefore = try XCTUnwrap(db.fetchBoard(id: "b1"))
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        // Stage: rename (step 1 — short-circuits at the empty-taskIds guard,
        // since b1 has no placements) + a task-field override for the REAL
        // task (step 3 — where the poisoned row's decode failure fires).
        vm.editName = "Renamed b1"
        vm.handleEditTaskOverride(
            taskId: "t-real",
            patch: .init(title: "Overridden", type: .normal, action: "", unit: "", maxCount: nil)
        )

        XCTAssertTrue(vm.handleEditSave(weekStartDay: "monday"), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil }, "handleEditSave never emitted an outcome")

        guard case .saveFailed = try XCTUnwrap(vm.editEvent?.outcome) else {
            XCTFail("expected .saveFailed, got \(String(describing: vm.editEvent?.outcome))")
            return
        }

        // The WHOLE transaction rolled back — the metadata rename that step 1
        // already applied inside the transaction did NOT stick.
        let boardAfter = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(boardAfter.name, boardBefore.name, "board must be UNCHANGED — the rename must not have stuck")
        XCTAssertEqual(boardAfter.version, boardBefore.version, "version must not have bumped either")

        // The task override was rolled back too.
        let taskAfter = try XCTUnwrap(db.fetchTask(id: "t-real"))
        XCTAssertEqual(taskAfter.title, "Task t-real", "override must not have persisted")
    }

    /// Happy-path atomicity companion (no injected failure): reuses the
    /// existing `test_handleEditSave_commitsRename_replacement_andPosition_
    /// thenEmitsSaved` composition (rename + replacement + position move) as
    /// the txn-boundary observation the spec calls for when a failure can't
    /// be forced into a specific step — that test already asserts every
    /// sub-op's write landed together after ONE `handleEditSave` call, which
    /// is only possible if they share one transaction (a per-step-transaction
    /// design could exhibit the exact same final state by all steps merely
    /// happening to succeed, so this is a companion, not a substitute, for
    /// the forced-failure test above).

    // MARK: - Item 4 (Board-integrity PR-4): atomic snapshot fetch

    /// Board-integrity PR-4 (Item 4, docs/BOARD_INTEGRITY.md): `reload()` now
    /// fetches `board` + the task-data payload from ONE `database.read {}`
    /// snapshot (`fetchSnapshot`) instead of two-plus separate reads. Every
    /// returned placement must belong to the SAME board record fetched
    /// alongside it in that one transaction — a shape/parity check that the
    /// combined fetch didn't change the loader's output contract.
    func test_reload_snapshotIsInternallyConsistent_boardAndPlacementsAgree() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { vm.board != nil })
        XCTAssertFalse(vm.boardTasks.isEmpty)
        for bt in vm.boardTasks {
            XCTAssertEqual(bt.boardId, vm.board?.id)
        }
    }

    /// The `board == nil` branch (no board exists for `boardId`) must not
    /// collapse the WHOLE snapshot to empty — only `fetchSnapshot`'s own
    /// thrown-error fallback does that. A legitimately-missing board must
    /// still apply the task-data half of the same read (matching the
    /// pre-fix behavior, where `fetchBoard` and `fetchTaskData` were
    /// independent calls and a missing board never blanked out task data).
    func test_reload_missingBoard_returnsNilBoardWithEmptyPayload_noCrash() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeTask("t1"))

        let vm = BoardPlayViewModel(boardId: "ghost-board", userId: "u1", database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { !vm.allTasks.isEmpty }, "task-data half of the snapshot should still apply")
        XCTAssertNil(vm.board, "no board exists for this id")
        XCTAssertTrue(vm.boardTasks.isEmpty)
    }

    // MARK: - Item 5 (Board-integrity PR-4): sync pull → live reload signal

    /// Board-integrity PR-4 (Item 5, docs/BOARD_INTEGRITY.md): the VM
    /// observes `.oybcSyncDidApplyChanges` (posted by `SyncService` after a
    /// pull applies ≥1 change) and reloads. iOS had no live-update mechanism
    /// for an already-open board-play screen before this.
    func test_syncNotification_triggersReload() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")

        // A change made "elsewhere" (simulating a pull applying it) without
        // going through the VM at all.
        try db.dbQueue.write { txn in
            try txn.execute(
                sql: "UPDATE boards SET name = ? WHERE id = ?",
                arguments: ["Renamed elsewhere", "b1"]
            )
        }
        XCTAssertEqual(vm.board?.name, "Board b1", "sanity: the VM hasn't seen the external change yet")

        NotificationCenter.default.post(name: .oybcSyncDidApplyChanges, object: nil)

        XCTAssertTrue(
            waitUntil { vm.board?.name == "Renamed elsewhere" },
            "the VM never reloaded in response to the notification"
        )
    }

    /// Skip-during-save guard: a notification arriving WHILE `handleEditSave`
    /// has its commit in flight must not trigger a second, competing reload
    /// — `editSaveInFlight` is the VM's own re-entry guard (reused here
    /// rather than adding a second flag), and `handleEditSave`'s own
    /// success/failure path already calls `reload()` once the commit
    /// settles. This test can't directly observe `editSaveInFlight` (private),
    /// so it pins the documented residual instead: posting the notification
    /// never crashes/misbehaves even under a concurrent Save, and the Save's
    /// own outcome still lands correctly.
    func test_syncNotification_duringEditSave_doesNotDisruptTheSave() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.editName = "Renamed via save"

        XCTAssertTrue(vm.handleEditSave(weekStartDay: "monday"))
        // Fire the notification immediately after dispatching the save —
        // `editSaveInFlight` is set synchronously before the detached task
        // starts, so this reliably lands while the guard is up.
        NotificationCenter.default.post(name: .oybcSyncDidApplyChanges, object: nil)

        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "the Save must still complete normally despite the concurrent notification")
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).name, "Renamed via save")
    }
}
