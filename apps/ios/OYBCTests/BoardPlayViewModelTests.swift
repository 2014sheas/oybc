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

    /// Build a Board via JSON (the same path production uses). `endDate: nil`
    /// makes an open-ended board (its window contains the real clock's now).
    private func makeBoard(
        id: String, userId: String = "u1", endDate: String? = "2026-06-30T23:59:59.999"
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
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
        if let endDate { dict["endDate"] = endDate }
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
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
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

    // MARK: - 0. board names are healed on the way to the UI

    /// Regression: `fetchSnapshot` used a raw `Board.fetchOne`, bypassing
    /// the healed `AppDatabase` fetchers, so the play-surface title and the
    /// cross-board "also appears on" list rendered the frozen literal
    /// "Today" for every legacy daily core board. Asserting the PUBLISHED
    /// state (not the helper) is the point — the helper was always correct;
    /// the view model never called it.
    func test_reload_healsAFrozenTodayNameOnThePlaySurface() throws {
        let db = try makeDb()
        try seedUser(db)
        let dict: [String: Any] = [
            "id": "core-1", "userId": "u1", "name": "Today",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.daily.rawValue,
            "startDate": "2026-03-15T00:00:00.000",
            "endDate": "2026-03-15T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false, "isCore": true,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-03-15T00:00:00.000",
            "updatedAt": "2026-03-15T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try db.write { grdb in try board.insert(grdb) }

        let vm = BoardPlayViewModel(boardId: "core-1", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board != nil }, "reload never applied")

        XCTAssertEqual(vm.board?.name, "Mar 15, 2026", "play-surface title still frozen")
        XCTAssertEqual(
            vm.allBoardsInWorkspace.first(where: { $0.id == "core-1" })?.name,
            "Mar 15, 2026",
            "cross-board name list still frozen"
        )
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
        maxCount: CountValue = 3,
        currentCount: CountValue? = nil,
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

    /// Counter kinds §5 — a standalone Continuous square remembers an explicit
    /// custom amount as its own `defaultLogAmount`; a chip amount never does.
    func test_handleCountingTap_standaloneContinuous_persistsOnlyACustomAmount() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        var c1 = makeCountingTask("c1", maxCount: 26.2, currentCount: 0)
        c1.countKind = .continuous
        try db.saveTask(c1)
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c1" })
        let task = try XCTUnwrap(vm.taskMap["c1"])

        vm.handleCountingTap(boardTask: bt, task: task, amount: 3.1, persistAsDefault: true)
        XCTAssertTrue(waitUntil { self.dbTask(db, "c1")?.defaultLogAmount == 3.1 && !vm.isProcessing })
        vm.handleCountingTap(boardTask: bt, task: task, amount: 6.6, persistAsDefault: false)
        XCTAssertTrue(waitUntil { abs((self.dbTask(db, "c1")?.currentCount ?? 0) - 9.7) < 0.001 && !vm.isProcessing })
        XCTAssertEqual(dbTask(db, "c1")?.defaultLogAmount, 3.1, "a chip amount never overwrites the default")
    }

    /// Sync safety — window 13.1 → setWindowedCount(16.2) must store delta 3.1,
    /// not 3.0999999999999996 (which the pull schema's `isValidCountDelta` drops).
    func test_setWindowedCount_storesAQuantizedDelta() throws {
        let db = try makeDb()
        try seedUser(db)
        let board = makeBoard(id: "b1")
        try db.saveBoard(board)
        var c1 = makeCountingTask("c1", maxCount: 26.2, currentCount: 13.1)
        c1.countKind = .continuous
        try db.saveTask(c1)
        let bt = makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0)
        try db.saveBoardTask(bt)
        try db.write { db in
            try TaskEvent(
                id: "seed-c1", userId: "u1", taskId: "c1", kind: .increment, delta: 13.1,
                occurredAt: "2026-06-25T00:00:00.000", boardId: nil,
                createdAt: "2026-06-25T00:00:00.000", updatedAt: "2026-06-25T00:00:00.000",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }

        _ = try db.completeTaskOrchestrated(
            board: board, taskId: "c1", intent: .setWindowedCount(16.2), boardTask: bt, now: "2026-06-26T00:00:00.000"
        )

        let added = try db.read { db in try TaskEvent.fetchAll(db) }.filter { $0.id != "seed-c1" }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.delta, 3.1)
        XCTAssertTrue(isQuantizedCount(try XCTUnwrap(added.first?.delta)))
    }

    /// The low-level insert quantizes every delta, so no caller can write noise.
    func test_insertIncrementEventRaw_quantizesTheDelta() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeCountingTask("c1", maxCount: 26.2))
        let wrote = try db.write { db in
            try AppDatabase.insertIncrementEventRaw(db: db, taskId: "c1", delta: 16.2 - 13.1, boardId: nil, now: "2026-06-26T00:00:00.000")
        }
        let wroteZero = try db.write { db in
            try AppDatabase.insertIncrementEventRaw(db: db, taskId: "c1", delta: 0.001, boardId: nil, now: "2026-06-26T00:00:00.000")
        }
        XCTAssertTrue(wrote)
        XCTAssertFalse(wroteZero, "a delta that quantizes to 0 writes nothing")
        XCTAssertEqual(try db.read { db in try TaskEvent.fetchAll(db) }.map(\.delta), [3.1])
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
        try db.saveBoard(makeBoard(id: "b2", endDate: nil)) // open window: still creditable
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
        try db.saveBoard(makeBoard(id: "b2", endDate: nil)) // open window: still creditable
        try db.saveTask(makeCountingTask("c-src", maxCount: 20, currentCount: 3))
        try db.saveTask(makeCountingTask("c-lnk", maxCount: 20, currentCount: 3, sharedCounterId: "c-src"))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-lnk", boardId: "b2", taskId: "c-lnk", row: 0, col: 0))
        // The event behind the lifetime cache of 3, inside b1's window: a
        // board-context decrement clamps to the board's WINDOW count
        // (final-review F6), so the fixture must carry the occurrence, not
        // just the cache.
        try db.write { database in
            try TaskEvent(
                id: "src-3", userId: "u1", taskId: "c-src", kind: .increment, delta: 3,
                occurredAt: "2026-06-25T00:00:00.000", boardId: nil,
                createdAt: "2026-06-25T00:00:00.000", updatedAt: "2026-06-25T00:00:00.000",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(database)
        }

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

    /// Undo gates taps like every other orchestration: until its reload lands,
    /// a +/− tap is rejected instead of computing from pre-undo windowed state.
    func test_undoSharedCounterLog_gatesTapsUntilItsReloadLands() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCountingTask("c-src", maxCount: 100, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-src" })
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c-src"]), amount: 10)
        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 10 && !vm.isProcessing })

        vm.snapshotDelay = 0.4 // widen the write-done / reload-pending window
        vm.undoSharedCounterLog(sourceTaskId: "c-src")
        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 0 }, "Undo write never landed")
        XCTAssertTrue(vm.isProcessing, "isProcessing must stay true after the write until the reload applies")
        XCTAssertEqual(vm.taskMap["c-src"]?.currentCount, 10, "published state is still pre-undo here")
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c-src"]), amount: 5)
        _ = waitUntil(timeout: 0.1) { false }
        XCTAssertEqual(dbTask(db, "c-src")?.currentCount, 0, "a tap before the reload lands must be rejected")

        XCTAssertTrue(waitUntil { vm.taskMap["c-src"]?.currentCount == 0 && !vm.isProcessing })
        vm.snapshotDelay = 0
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c-src"]), amount: 5)
        XCTAssertTrue(waitUntil { self.dbTask(db, "c-src")?.currentCount == 5 && !vm.isProcessing }, "tap after the reload must apply")
    }

    /// A superseded reload hands its completion to the winner: it fires exactly
    /// once, only after the final snapshot has applied.
    func test_reloadCompletion_supersededReload_firesOnceAfterWinnerApplies() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        var fired = 0
        var placementsAtFire = -1
        vm.reload { fired += 1; placementsAtFire = vm.boardTasks.count }
        vm.reloadBoardTasksAndTaskData() // supersedes the reload above
        XCTAssertTrue(waitUntil { fired > 0 }, "completion never ran")
        XCTAssertGreaterThan(placementsAtFire, 0, "completion ran before the winning snapshot applied")
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(fired, 1, "completion must run exactly once")
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
        // The event behind the lifetime cache of 2, inside b1's window — a
        // board-context decrement clamps to the WINDOW count (final-review F6).
        try db.write { database in
            try TaskEvent(
                id: "solo-seed", userId: "u1", taskId: "c-solo", kind: .increment, delta: 2,
                occurredAt: "2026-06-25T00:00:00.000", boardId: nil,
                createdAt: "2026-06-25T00:00:00.000", updatedAt: "2026-06-25T00:00:00.000",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c-solo" })
        let task = try XCTUnwrap(vm.taskMap["c-solo"])
        XCTAssertFalse(vm.allTasks.contains { $0.sharedCounterId == "c-solo" },
                        "fixture must have zero linked members — only isCounter can route this")

        vm.handleCountingDecrement(boardTask: bt, task: task)

        XCTAssertTrue(waitUntil { self.dbTask(db, "c-solo")?.currentCount == 1 && !vm.isProcessing },
                      "shared-counter decrement never dropped the zero-link isCounter source, or threw")
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c-solo")).currentCount, 1)

        let events = try db.fetchNonDeletedTaskEvents(userId: "u1").filter { $0.taskId == "c-solo" && $0.id != "solo-seed" }
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

    // `test_handleAddTaskToCell_createsPlacement` /
    // `test_handleAddTaskToCell_reentrantCallIsNoOp` removed (Board Edit
    // redesign slice 3, D17) — the play-mode "+" immediate write is
    // retired; every add now goes through the staged squares editor. See
    // `test_handleEditSave_addsPendingNewTask_andPlacement_inOneTransaction`
    // and the reentrancy coverage on `handleEditSave` itself.

    // MARK: - 11. Board Edit redesign slice 3 — squares-edit draft layer

    func test_seedEditDraft_populatesDraftFieldsFromBoard() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0), t2@(0,1); monthly, FREE center
        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)

        vm.seedEditDraft(from: board)

        XCTAssertEqual(vm.editCenterType, .free)
        // One squares-draft entry per live placement, seeded taskId == original.
        XCTAssertEqual(vm.editSquaresDraft.count, 2)
        let d00 = try XCTUnwrap(vm.editSquaresDraft["0-0"])
        XCTAssertEqual(d00.originalTaskId, "t1")
        XCTAssertEqual(d00.taskId, "t1")
        XCTAssertTrue(vm.editTaskOverrides.isEmpty)
        XCTAssertFalse(vm.editShuffled)
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
        vm.handleEditReplace(cellKey: "0-0", taskId: "t2")
        XCTAssertEqual(vm.editSquaresEditCount, 1)
        XCTAssertEqual(vm.editSquaresDraft["0-0"]?.taskId, "t2",
                       "draft overlays the staged replacement")

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

    func test_editSquaresEditCells_reflectsStagedRemoval() throws {
        // Regression (review Critical, ported to D20's derived grid): the
        // squares-edit grid is rebuilt fresh from the draft on every read —
        // a staged removal must render the cell empty (not the full
        // original board), and removing every cell must yield an
        // all-empty grid.
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0) bt-b1-1, t2@(0,1) bt-b1-2
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editSquaresEditCells.filter { !$0.isEmpty && !$0.isCenter }.count, 2,
                       "seeded draft renders both placements")

        vm.handleEditRemove(cellKey: "0-1")
        XCTAssertFalse(vm.editSquaresEditCells.contains { $0.id == "bt-b1-2" },
                       "removed cell must disappear from the rendered grid, not persist")
        XCTAssertTrue(vm.editSquaresEditCells.contains { $0.id == "bt-b1-1" })

        // Remove the last remaining square → the grid must be all-empty, not the full board.
        vm.handleEditRemove(cellKey: "0-0")
        XCTAssertTrue(vm.editSquaresEditCells.allSatisfy { $0.isEmpty || $0.isCenter },
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

        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
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
        vm.handleEditReplace(cellKey: "0-0", taskId: "t2")
        vm.handleEditTaskOverride(
            taskId: "t2",
            patch: .init(title: "X", type: .normal, action: "", unit: "", maxCount: nil)
        )
        XCTAssertEqual(vm.editSquaresEditCount, 2)

        // Re-entering edit mode re-seeds from the live board, discarding drafts.
        vm.seedEditDraft(from: board)
        XCTAssertEqual(vm.editSquaresEditCount, 0)
        XCTAssertTrue(vm.editTaskOverrides.isEmpty)
        XCTAssertFalse(vm.editShuffled)
    }

    /// Board Edit redesign slice 2 (T3) — name is no longer part of the
    /// squares-editor commit (it moved to `BoardDetailsSheetView`), so the
    /// metadata half of this atomicity check is now the center toggle, the
    /// ONE metadata field the squares panel still owns.
    func test_handleEditSave_commitsCenterToggle_replacement_andPosition_thenEmitsSaved() throws {
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

        // 1. Center toggle: FREE → NONE.
        vm.handleEditCenterTask()
        // 2. Replace t1 → t2 in cell (0,0).
        vm.handleEditReplace(cellKey: "0-0", taskId: "t2")
        // 3. Position move: move bt1 (slot 0) into the empty slot 1 = (0,1)
        //    by swapping the two array entries (D20 — cells are always
        //    derived fresh, no separate seed step).
        var cells = vm.editSquaresEditCells
        cells.swapAt(0, 1)
        vm.handleEditMove(newCells: cells)

        // Board Edit redesign slice 3 (D11): `editSquaresEditCount` is now
        // the FULL unified count — center change + replacement + move.
        XCTAssertEqual(vm.editSquaresEditCount, 3, "one center change + one replacement + one position move")

        let started = vm.handleEditSave()
        XCTAssertTrue(started, "save should dispatch")

        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        // Board's center toggled.
        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.centerSquareType, .none)
        // Placement repointed t1 → t2 AND moved to (0,1).
        let bt = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt.taskId, "t2", "cell replacement committed")
        XCTAssertEqual(bt.row, 0)
        XCTAssertEqual(bt.col, 1, "position move committed")
    }

    // MARK: - 11b. Board Edit redesign slice 3 — squares Save (D14/D15/D16/D2)

    /// D14 — a Normal/Counting/Achievement task staged via the picker's
    /// quick-add is inserted at Save with `createdInWizard: false` (a
    /// deliberate library task, unlike the wizard's hidden drafts).
    func test_handleEditSave_addsPendingNewTask_andPlacement_inOneTransaction() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0), t2@(0,1)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        let now = AppDatabase.currentTimestamp()
        let pendingTask = Task(
            id: "pending-1", userId: "u1", title: "Brand new task", type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now,
            version: 1, isDeleted: false, createdInWizard: true // Save must flip this to false
        )
        let payload = PendingTaskPayload(task: pendingTask, childTasks: [], childLinks: [])
        vm.handleEditAdd(cellKey: "2-2", taskId: "pending-1", pending: payload)
        XCTAssertEqual(vm.editSquaresEditCount, 1)
        XCTAssertNil(dbTask(db, "pending-1"), "nothing written until Save")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(dbTask(db, "pending-1"))
        XCTAssertFalse(saved.createdInWizard, "D14 — a deliberate library task")
        let placement = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.taskId == "pending-1" })
        XCTAssertEqual(placement.row, 2)
        XCTAssertEqual(placement.col, 2)
        let sync = try db.fetchPendingSyncItems()
        XCTAssertTrue(sync.contains { $0.entityType == "tasks" && $0.entityId == "pending-1" && $0.operationType == .create })
    }

    /// Counter kinds (D5) — a picker quick-add row linked to a continuous
    /// root is stored with the root's kind at Save (the VM-built row carries
    /// none of its own).
    func test_handleEditSave_pendingLinkedRow_carriesRootCountKind() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let now = AppDatabase.currentTimestamp()
        var root = Task(
            id: "root-amt", userId: "u1", title: "Run", type: .counting, action: "Run", unit: "km",
            maxCount: 26.2, totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now,
            version: 1, isDeleted: false
        )
        root.countKind = .continuous
        try db.saveTask(root)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        let linked = Task(
            id: "pending-linked", userId: "u1", title: "Run 5 km", type: .counting, action: "Run", unit: "km",
            maxCount: 5, totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now,
            version: 1, isDeleted: false, sharedCounterId: "root-amt", baseline: 0
        )
        XCTAssertNil(linked.countKind)
        vm.handleEditAdd(cellKey: "2-2", taskId: "pending-linked",
                         pending: PendingTaskPayload(task: linked, childTasks: [], childLinks: []))

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        XCTAssertEqual(dbTask(db, "pending-linked")?.countKind, .continuous)
        let created = try db.fetchPendingSyncItems().filter {
            $0.entityType == "tasks" && $0.entityId == "pending-linked" && $0.operationType == .create
        }
        let payload = try JSONDecoder().decode(Task.self, from: Data(try XCTUnwrap(created.first).payload.utf8))
        XCTAssertEqual(payload.countKind, .continuous, "the CREATE payload carries the kind too")
    }

    /// D15 — removals run BEFORE adds so a freed position is never mistaken
    /// for occupied.
    func test_handleEditSave_removeThenAddSamePosition() throws {
        let db = try makeDb()
        try seedWorkspace(db)   // b1: t1@(0,0) bt-b1-1, t2@(0,1)
        try db.saveTask(makeTask("t3"))
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditRemove(cellKey: "0-0")
        vm.handleEditAdd(cellKey: "0-0", taskId: "t3")
        XCTAssertEqual(vm.editSquaresEditCount, 2, "one removal + one add")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let placements = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertFalse(placements.contains { $0.id == "bt-b1-1" }, "original placement removed")
        XCTAssertTrue(placements.contains { $0.taskId == "t3" && $0.row == 0 && $0.col == 0 },
                      "the new placement lands at the freed position")
    }

    /// D16 — "Make it a free space" stages the center placement's removal
    /// AND the type toggle, but D11 counts it as ONE edit; the tombstone
    /// still lands on Save.
    func test_handleEditSave_centerFree_tombstonesCenterPlacement() throws {
        let db = try makeDb()
        try seedUser(db)
        var board = makeBoard(id: "b1")
        board.centerSquareType = .none
        try db.saveBoard(board)
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "btc", boardId: "b1", taskId: "t1", row: 1, col: 1))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.editCenterType, .none)

        vm.handleEditCenterFree()
        XCTAssertEqual(vm.editCenterType, .free)
        XCTAssertNil(vm.editSquaresDraft["1-1"], "center placement staged for removal")
        XCTAssertEqual(vm.editSquaresEditCount, 1, "the center toggle is ONE edit, not two (D11)")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.centerSquareType, .free)
        XCTAssertFalse(try db.fetchBoardTasks(boardId: "b1").contains { $0.id == "btc" },
                       "the center placement is tombstoned even though the count excluded it")
    }

    /// D10 — Shuffle persists the new positions; a locked square never moves.
    func test_handleEditSave_shuffle_persistsPositions_locksUnchanged() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        for i in 1...4 { try db.saveTask(makeTask("t\(i)")) }
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt3", boardId: "b1", taskId: "t3", row: 0, col: 2))
        try db.saveBoardTask(makeBoardTask(id: "bt4", boardId: "b1", taskId: "t4", row: 1, col: 0))
        try db.dbQueue.write { database in
            guard var row = try BoardTask.fetchOne(database, key: "bt4") else { return }
            row.isLocked = true
            try row.save(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertTrue(vm.canShuffle)
        vm.handleEditShuffle(rng: { 0.0 })
        XCTAssertTrue(vm.editShuffled)
        XCTAssertEqual(vm.editSquaresEditCount, 1, "shuffle is one edit")
        XCTAssertTrue(vm.editSquaresDraft.values.contains { $0.id == "bt4" },
                      "locked cell still present in the draft")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try db.fetchBoardTasks(boardId: "b1")
        let bt4 = try XCTUnwrap(saved.first { $0.id == "bt4" })
        XCTAssertEqual(bt4.row, 1)
        XCTAssertEqual(bt4.col, 0, "the locked square never moved")
        XCTAssertTrue(bt4.isLocked)
    }

    /// D14 — nothing is written until `handleEditSave` runs (the "cancel"
    /// path is simply never calling it).
    func test_cancelWithoutSaving_writesNothing() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        let now = AppDatabase.currentTimestamp()
        let pendingTask = Task(
            id: "pending-x", userId: "u1", title: "Not saved", type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now,
            version: 1, isDeleted: false
        )
        vm.handleEditAdd(
            cellKey: "2-2", taskId: "pending-x",
            pending: PendingTaskPayload(task: pendingTask, childTasks: [], childLinks: [])
        )
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        XCTAssertNil(dbTask(db, "pending-x"), "nothing is written until Save")
        XCTAssertTrue(try db.fetchBoardTasks(boardId: "b1").allSatisfy { $0.taskId != "pending-x" })
    }

    /// D2 — an unrelated edit on a still-CHOSEN-on-disk board still triggers
    /// the one-time normalization, even though the user never touched the
    /// center.
    func test_handleEditSave_legacyChosenPlusUnrelatedEdit_normalizesOnSave() throws {
        let db = try makeDb()
        try seedUser(db)
        var board = makeBoard(id: "b1")
        board.centerSquareType = .chosen
        try db.saveBoard(board)
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "btc", boardId: "b1", taskId: "t1", row: 1, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.handleEditToggleLock(cellKey: "0-0")   // an UNRELATED edit — not the center.
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.centerSquareType, .none, "normalized even though the user never touched the center")
        let center = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "btc" })
        XCTAssertTrue(center.isLocked, "the implicit legacy lock is preserved (keepLocked defaults true)")
        XCTAssertFalse(center.isCenter)
    }

    /// Board Edit's type switch: Simple/Counting → Compound is allowed (with
    /// the compound editor's rule + sub-tasks), but never OUT of Compound (a
    /// compound → Simple override would orphan its `compound_children`), and a
    /// switch into Compound with no compound patch is ignored (it would mint a
    /// zero-child compound). The title still commits in every case.
    func test_editCommit_allowsTypeOverrideIntoCompound_ignoresOutOfCompound() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeCompoundTask("tc"))
        try db.saveTask(makeTask("c1"))
        try db.saveTask(makeTask("c2"))
        try db.saveTask(makeTask("tn"))
        try db.saveTask(makeTask("tn2"))
        try db.saveBoardTask(makeBoardTask(id: "bt-c", boardId: "b1", taskId: "tc", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-n", boardId: "b1", taskId: "tn", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt-n2", boardId: "b1", taskId: "tn2", row: 0, col: 2))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "tc", child: "c1", idx: 0).insert(database)
            try makeCompoundChild(parent: "tc", child: "c2", idx: 1).insert(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: board)
        vm.handleEditTaskOverride(
            taskId: "tc",
            patch: .init(title: "Renamed compound", type: .normal, action: "", unit: "", maxCount: nil)
        )
        var toCompound = TaskEditPatch(title: "Renamed normal")
        toCompound.operatorType = .or
        toCompound.children = [
            ChildPatch(id: "n1", childTaskId: nil, title: "Sub A", isCounting: false),
            ChildPatch(id: "n2", childTaskId: nil, title: "Sub B", isCounting: false),
        ]
        vm.handleEditTaskOverride(
            taskId: "tn",
            patch: .init(title: "Renamed normal", type: .compound, action: "", unit: "", maxCount: nil,
                         compound: toCompound)
        )
        // No compound patch ⇒ the switch is ignored (title still commits).
        vm.handleEditTaskOverride(
            taskId: "tn2",
            patch: .init(title: "Renamed bare", type: .compound, action: "", unit: "", maxCount: nil)
        )

        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        let compound = try XCTUnwrap(dbTask(db, "tc"))
        XCTAssertEqual(compound.type, .compound, "a compound cannot be switched out of Compound")
        XCTAssertEqual(compound.title, "Renamed compound", "the title still commits")
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "tc").map(\.id), ["c1", "c2"],
                       "the compound's links stay intact")

        let converted = try XCTUnwrap(dbTask(db, "tn"))
        XCTAssertEqual(converted.type, .compound, "a Simple task can be switched into Compound")
        XCTAssertEqual(converted.title, "Renamed normal")
        XCTAssertEqual(converted.operatorType, .or)
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "tn").map(\.title), ["Sub A", "Sub B"])

        let bare = try XCTUnwrap(dbTask(db, "tn2"))
        XCTAssertEqual(bare.type, .normal, "a switch into Compound without a rule + sub-tasks is ignored")
        XCTAssertEqual(bare.title, "Renamed bare", "the title still commits")
    }

    // MARK: - I3 (Board Edit consolidation, D8 `keep`) — Board details Save
    // then squares Save, both from the same Edit session

    /// D8 `keep` — the Board details sheet opens OVER the Edit screen and
    /// commits independently (`saveBoardDetails` is its own atomic write);
    /// the squares draft is untouched and the user stays in Edit. Pins that
    /// a details save followed by a squares save persists BOTH: the details
    /// name/dates AND the staged square change, with `version` strictly
    /// increasing on each write. Mirrors web's
    /// `boardEditWindowPreservation.test.ts` W3 extension.
    func test_boardDetailsSave_thenSquaresSave_bothPersist() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))     // 3×3, FREE center, monthly, "Board b1"
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let board = try XCTUnwrap(vm.board)
        let versionBeforeDetails = board.version
        vm.seedEditDraft(from: board)

        // 0. A square replacement is staged BEFORE the Board details sheet
        //    opens — the D8 `keep` claim is that the details save (and the
        //    `reload()` it triggers) leaves this draft alone.
        vm.handleEditReplace(cellKey: "0-0", taskId: "t2")
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        // 1. "Board details" sheet save (D8 `keep` — independent of the
        //    squares draft, which is untouched by this write).
        let detailsExpectation = expectation(description: "saveBoardDetails")
        _Concurrency.Task {
            try await vm.saveBoardDetails(.init(
                name: "Renamed via Details",
                startDate: "2026-05-01T00:00:00.000",
                endDate: "2026-05-31T23:59:59.999"
            ))
            detailsExpectation.fulfill()
        }
        wait(for: [detailsExpectation], timeout: 5)

        let afterDetails = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(afterDetails.name, "Renamed via Details")
        XCTAssertEqual(afterDetails.startDate, "2026-05-01T00:00:00.000")
        XCTAssertGreaterThan(afterDetails.version, versionBeforeDetails, "details save bumps version")

        // Still in Edit with the draft intact (D8 `keep`): the replacement
        // staged before the details save is still pending.
        XCTAssertEqual(vm.editSquaresEditCount, 1, "the details save left the squares draft untouched")
        let bt0 = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt0.taskId, "t1", "the staged replacement is not written by the details save")

        // 2. Squares Save.
        XCTAssertTrue(vm.handleEditSave(), "squares save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        let final = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(final.name, "Renamed via Details", "the Details name survives the squares save")
        XCTAssertEqual(final.startDate, "2026-05-01T00:00:00.000", "the Details window survives the squares save")
        // Swapping one incomplete square for another leaves the derived stats
        // unchanged, so the board row itself is not re-bumped (sync-churn fix);
        // the committed placement below is the proof the squares save landed.
        XCTAssertEqual(final.version, afterDetails.version, "an unchanged-stats squares save does not re-bump the board")

        let bt = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt.taskId, "t2", "the staged square replacement committed")
    }

    // MARK: - P0: Board Edit must never rewrite an achievement's type

    private func makeAchievementTask(
        _ id: String,
        referencedBoardId: String? = nil,
        referencedTemplateId: String? = nil,
        trigger: AchievementTrigger = .bingo,
        requiredCount: Int? = nil
    ) -> Task {
        var t = makeTask(id)
        t.type = .achievement
        t.referencedBoardId = referencedBoardId
        t.referencedTemplateId = referencedTemplateId
        t.achievementTrigger = trigger
        t.requiredCount = requiredCount
        return t
    }

    /// P0 (docs/BOARD_EDIT_REDESIGN.md) — "Edit task…" on an achievement
    /// square, renamed and Done: the sheet hands back a patch carrying the
    /// type it was seeded with, and the commit must keep `.achievement` and
    /// every watcher field. Also covers a Simple/Counting segment flipped to
    /// Counting (goal + unit filled in): no counting fields may land on an
    /// achievement either.
    func test_editCommit_keepsAchievementTypeAndFields_boardMode() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b-ref"))
        try db.saveTask(makeAchievementTask("ta", referencedBoardId: "b-ref", trigger: .bingo))
        try db.saveTask(makeAchievementTask("tb", referencedBoardId: "b-ref", trigger: .greenlog))
        try db.saveBoardTask(makeBoardTask(id: "bt-a", boardId: "b1", taskId: "ta", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-b", boardId: "b1", taskId: "tb", row: 0, col: 1))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        // The Done patch built from the sheet's own seed, exactly as the
        // "Edit task…" sheet returns it when only the title is changed.
        let sheetSeed = SquareEditTaskSheet.initialType(for: try XCTUnwrap(vm.editDraftTaskMap["ta"]))
        vm.handleEditTaskOverride(
            taskId: "ta",
            patch: .init(title: "Renamed watcher", type: sheetSeed, action: "", unit: "", maxCount: nil)
        )
        vm.handleEditTaskOverride(
            taskId: "tb",
            patch: .init(title: "Flipped to counting", type: .counting, action: "Run", unit: "km", maxCount: 5)
        )
        XCTAssertEqual(vm.editDraftTaskMap["ta"]?.type, .achievement,
                       "the staged draft grid must not show the square as Simple")

        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "handleEditSave never emitted .saved")

        let a = try XCTUnwrap(dbTask(db, "ta"))
        XCTAssertEqual(a.type, .achievement, "Board Edit must not rewrite an achievement's type")
        XCTAssertEqual(a.title, "Renamed watcher", "the title still commits")
        XCTAssertEqual(a.referencedBoardId, "b-ref")
        XCTAssertEqual(a.achievementTrigger, .bingo)

        let b = try XCTUnwrap(dbTask(db, "tb"))
        XCTAssertEqual(b.type, .achievement, "an achievement cannot be switched to Counting")
        XCTAssertEqual(b.title, "Flipped to counting")
        XCTAssertEqual(b.referencedBoardId, "b-ref")
        XCTAssertEqual(b.achievementTrigger, .greenlog)
        XCTAssertNil(b.action, "no counting fields land on an achievement")
        XCTAssertNil(b.unit)
        XCTAssertNil(b.maxCount)
    }

    /// Same P0, template mode, through the slice-3 picker path: a
    /// not-yet-created achievement staged by Add, then "Edit task…" on it —
    /// the override merges into the pending payload at insert (step 1).
    func test_editCommit_keepsAchievementTypeAndFields_pendingTemplateMode() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t-lib")) // `loadedVM` waits for a non-empty library

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        let pending = makeAchievementTask(
            "pending-ach", referencedTemplateId: "tmpl-1", trigger: .greenlog, requiredCount: 3
        )
        vm.handleEditAdd(
            cellKey: "0-0", taskId: "pending-ach",
            pending: PendingTaskPayload(task: pending, childTasks: [], childLinks: [])
        )
        let sheetSeed = SquareEditTaskSheet.initialType(for: try XCTUnwrap(vm.editDraftTaskMap["pending-ach"]))
        vm.handleEditTaskOverride(
            taskId: "pending-ach",
            patch: .init(title: "Three greenlogs", type: sheetSeed, action: "", unit: "", maxCount: nil)
        )

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
        let saved = try XCTUnwrap(dbTask(db, "pending-ach"))
        XCTAssertEqual(saved.type, .achievement)
        XCTAssertEqual(saved.title, "Three greenlogs")
        XCTAssertEqual(saved.referencedTemplateId, "tmpl-1")
        XCTAssertEqual(saved.achievementTrigger, .greenlog)
        XCTAssertEqual(saved.requiredCount, 3)
    }

    /// The commit guard is symmetric: nothing becomes an achievement through
    /// Board Edit either (it would be a watcher with no trigger or target).
    func test_editCommit_ignoresTypeOverrideIntoAchievement() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        try db.saveBoardTask(makeBoardTask(id: "bt-n", boardId: "b1", taskId: "tn", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.handleEditTaskOverride(
            taskId: "tn",
            patch: .init(title: "Renamed", type: .achievement, action: "", unit: "", maxCount: nil)
        )
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
        let saved = try XCTUnwrap(dbTask(db, "tn"))
        XCTAssertEqual(saved.type, .normal)
        XCTAssertEqual(saved.title, "Renamed")
    }

    // `test_handleEditSave_blankName_doesNotStart` removed (Board Edit
    // redesign slice 2, T3) — name validation lives in
    // `BoardDetailsDraft.validationError` / `BoardDetailsSheetView` now;
    // `handleEditSave` no longer reads a name at all.

    // `test_handleEditArchive_setsBoardArchived_thenEmitsArchived` migrated to
    // `BoardPlayViewModelBoardActionsTests.test_archiveBoard_setsStatusArchived`
    // (Board Edit redesign slice 2, T2) — Archive is now the plain `async
    // throws` `archiveBoard()`; `handleEditArchive` + its one-shot `.archived`
    // event were removed from `+EditCommit.swift`.

    // MARK: - 12. Shared Counters P3 — passive-completion arrival detection

    /// An isolated `UserDefaults` suite so the arrival store never pollutes
    /// `.standard` and each test starts from a clean baseline.
    private func makeIsolatedStore() -> CounterArrivalStore {
        let suite = "arrival-test-\(UUID().uuidString)"
        return CounterArrivalStore(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Seed: user u1, b1 (holds the SOURCE counter c-src) + b2 (holds a linked
    /// derived counter c-lnk → c-src), so c-src is a shared-counter source whose
    /// square on b1 participates in arrival detection. Both boards are
    /// OPEN-ENDED: the elsewhere log is stamped at the real clock's now, and
    /// since the 2026-09-24 amendment an ENDED board's window no longer counts
    /// it (pinned separately by `test_arrivalDetection_endedBoard_…`).
    private func seedSharedCounterBoard(_ db: AppDatabase, boardEndDate: String? = nil) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", endDate: boardEndDate))
        try db.saveBoard(makeBoard(id: "b2", endDate: boardEndDate))
        try db.saveTask(makeCountingTask("c-src", maxCount: 5, currentCount: 0))
        try db.saveTask(makeCountingTask("c-lnk", maxCount: 5, currentCount: 0, sharedCounterId: "c-src"))
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "c-src", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-lnk", boardId: "b2", taskId: "c-lnk", row: 0, col: 0))
    }

    /// Simulate a log made ELSEWHERE (Counter Detail / another board) through
    /// the REAL production path — `incrementSharedCounter` appends the
    /// increment event AND stamps the caches. Issue #377 made arrival
    /// detection resolve SOURCE counts windowed (from events), so a raw
    /// `currentCount` write no longer models an elsewhere log.
    private func bumpSourceCount(_ db: AppDatabase, by delta: CountValue, taskId: String = "c-src") throws {
        _ = try db.incrementSharedCounter(sourceTaskId: taskId, by: delta)
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
        try bumpSourceCount(db, by: 3)

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

    /// 2026-09-24 amendment: a log made elsewhere TODAY is outside an ENDED
    /// board's `[startDate, endDate]` window, so it must not arrive there.
    func test_arrivalDetection_endedBoard_elsewhereLogTodayDoesNotArrive() throws {
        let db = try makeDb()
        try seedSharedCounterBoard(db, boardEndDate: "2026-06-30T23:59:59.999")
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db, arrivalStore: makeIsolatedStore())
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty })

        try bumpSourceCount(db, by: 3)
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.windowEventsByTaskId["c-src"]?.count == 1 }, "reload picked up the log")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(vm.arrivalEvent, "today's log is not this ended board's")
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
        try bumpSourceCount(db, by: 3)
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
        try db.saveBoard(makeBoard(id: "b1", endDate: nil)) // open: the log is stamped now
        try db.saveTask(makeCountingTask("c-solo", maxCount: 5, currentCount: 0, isCounter: true))
        try db.saveBoardTask(makeBoardTask(id: "bt-solo", boardId: "b1", taskId: "c-solo", row: 0, col: 0))

        let store = makeIsolatedStore()
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db, arrivalStore: store)

        // First open: seeds the baseline (c-solo displayed 0) — first view never arrives.
        vm.markArrivalDetectionPending()
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty })
        XCTAssertNil(vm.arrivalEvent, "first view must not arrive")

        // Logged elsewhere (Counter Detail's +2) through the real increment
        // path — appends the events windowed detection resolves from (#377).
        try bumpSourceCount(db, by: 2, taskId: "c-solo")

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

    /// Owner rule 2026-10-01: a linked (hub-linked) counting task resolves from
    /// the ROOT's increments inside the board's window — its propagation-stamped
    /// lifetime latch is no longer read on a board, in the live grid or the
    /// edit preview.
    func test_windowedIsCompleted_hubLinkedCountingTask_readsRootEventsInWindowNotLatch() throws {
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
        XCTAssertFalse(
            vm.windowedIsCompleted(for: liveTask),
            "no in-window root events — the stale latch must not paint the square done"
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
        try db.saveBoard(makeBoard(id: "b1"))   // FREE center, 3×3

        // A real task to stage an override for — PLACED, since an override for
        // a square no longer on the board is dropped at Save.
        try db.saveTask(makeTask("t-real"))
        try db.saveBoardTask(makeBoardTask(id: "bt-real", boardId: "b1", taskId: "t-real", row: 0, col: 0))

        // Load the VM BEFORE seeding the poison: Item 4 made reload() an
        // all-or-nothing snapshot read, so an undecodable row present at
        // load time nils the ENTIRE snapshot (by design — loud, not torn)
        // and the VM never loads. The poison must land after load, before
        // Save, so it fires inside Save's cascade — the path under test.
        let vm = loadedVM(db, boardId: "b1")
        let boardBefore = try XCTUnwrap(db.fetchBoard(id: "b1"))
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        // A poisoned Task row — undecodable `type` — that ANY cascade's
        // `Task.fetchAll(db)` will choke on.
        let now = AppDatabase.currentTimestamp()
        try db.write { txn in
            try txn.execute(
                sql: "INSERT INTO tasks (id, userId, title, type, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["t-poison", "u1", "Poison", "not_a_real_type", now, now]
            )
        }

        // Stage: center toggle (step 1 — short-circuits at the empty-taskIds
        // guard, since b1 has no placements) + a task-field override for the
        // REAL task (step 3 — where the poisoned row's decode failure fires).
        vm.editCenterType = .none
        vm.handleEditTaskOverride(
            taskId: "t-real",
            patch: .init(title: "Overridden", type: .normal, action: "", unit: "", maxCount: nil)
        )

        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil }, "handleEditSave never emitted an outcome")

        guard case .saveFailed = try XCTUnwrap(vm.editEvent?.outcome) else {
            XCTFail("expected .saveFailed, got \(String(describing: vm.editEvent?.outcome))")
            return
        }

        // The WHOLE transaction rolled back — the metadata patch step 1
        // already applied inside the transaction did NOT stick.
        let boardAfter = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(boardAfter.centerSquareType, boardBefore.centerSquareType,
                       "board must be UNCHANGED — the center toggle must not have stuck")
        XCTAssertEqual(boardAfter.version, boardBefore.version, "version must not have bumped either")

        // The task override was rolled back too.
        let taskAfter = try XCTUnwrap(db.fetchTask(id: "t-real"))
        XCTAssertEqual(taskAfter.title, "Task t-real", "override must not have persisted")
    }

    /// Board Edit slice 2 (D11 / bugfix B2): a board sealed between entering
    /// edit mode and Save must NOT report "Board saved" — the save throws
    /// `boardNotEditable` inside the transaction, rolling back EVERY sub-op
    /// (the staged global task override included), and the VM emits
    /// `.boardClosed`. Pre-fix the metadata guard silently no-oped, the task
    /// override still committed, and `.saved` fired.
    func test_handleEditSave_boardSealedMidSession_emitsBoardClosed_andRollsBack() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeCustomBoard(
            id: "b-seal", timeframe: .monthly, startDate: offsetDaysISO(-5),
            endDate: offsetDaysISO(25), boardSize: 1
        ))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-seal", taskId: "t1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b-seal")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.editCenterType = .free
        vm.handleEditTaskOverride(
            taskId: "t1",
            patch: .init(title: "Overridden", type: .normal, action: "", unit: "", maxCount: nil)
        )

        // Sealed elsewhere (backstop / sync pull) while the editor is open.
        var sealed = try XCTUnwrap(db.fetchBoard(id: "b-seal"))
        sealed.sealedAt = AppDatabase.currentTimestamp()
        try db.saveBoard(sealed)
        let before = try XCTUnwrap(db.fetchBoard(id: "b-seal"))

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil })
        XCTAssertEqual(vm.editEvent?.outcome, .boardClosed(BoardEditError.boardClosedMessage))

        let after = try XCTUnwrap(db.fetchBoard(id: "b-seal"))
        XCTAssertEqual(after.centerSquareType, before.centerSquareType)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(try XCTUnwrap(db.fetchTask(id: "t1")).title, "Task t1",
                       "the staged task override must roll back with the rest")
    }

    // `test_handleEditSave_ongoingStartEdit_isSaved` removed (Board Edit
    // redesign slice 2, T3) — dates no longer route through
    // `handleEditSave`/`editCustomStartDate` (retired). Equivalent coverage
    // now lives in `BoardDetailsSaveTests.
    // test_ongoingStartEdit_keepsInWindowCompletionGreen` via
    // `AppDatabase.saveBoardDetails` + `BoardDetailsDraft`.

    /// Happy-path atomicity companion (no injected failure): reuses the
    /// existing `test_handleEditSave_commitsCenterToggle_replacement_and
    /// Position_thenEmitsSaved` composition (center toggle + replacement +
    /// position move) as the txn-boundary observation the spec calls for
    /// when a failure can't be forced into a specific step — that test
    /// already asserts every sub-op's write landed together after ONE
    /// `handleEditSave` call, which is only possible if they share one
    /// transaction (a per-step-transaction
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
        vm.editCenterType = .none

        XCTAssertTrue(vm.handleEditSave())
        // Fire the notification immediately after dispatching the save —
        // `editSaveInFlight` is set synchronously before the detached task
        // starts, so this reliably lands while the guard is up.
        NotificationCenter.default.post(name: .oybcSyncDidApplyChanges, object: nil)

        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved },
                      "the Save must still complete normally despite the concurrent notification")
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "b1")).centerSquareType, .none)
    }

    // MARK: - 14. bugfix/edit-preserves-board-window
    //
    // `handleEditSave` used to recompute the board's `startDate`/`endDate` on
    // EVERY Save — indefinite boards re-anchored to `startOfDay(Date())`, core
    // (daily/weekly/monthly/yearly) boards re-snapped to
    // `computeTimeframeBoundaries(referenceDate: Date())` — even when the user
    // only renamed the board or replaced a cell. Under Windowed Completion, a
    // board's window lower bound is the completion-evaluation floor: silently
    // moving it forward wipes the windowed-complete state of every task whose
    // completion event predates the new start (`resolveTaskWindowState`'s
    // `occurred >= lower` gate in `OYBC/Helpers/TaskEvents.swift`).
    //
    // The fix: `startDate`/`endDate` in the `UpdateActiveBoardPatch` are `nil`
    // (⇒ "leave unchanged" at the DB layer, see
    // `AppDatabase.UpdateActiveBoardPatch`) UNLESS the user actually changed
    // the window — a timeframe conversion, or new CUSTOM dates. This section
    // pins that fix, sweeps it across the Save sub-op matrix (replace /
    // rearrange / remove composed together), and cross-checks that the other
    // "is this cell complete" surfaces (`kernelCellStates`, `BoardPreviewCells`,
    // `reDeriveActiveBoards` self-heal) all agree with the play grid after an
    // edit-save — no divergence introduced by editing.

    /// `n` calendar days from "now" (negative = past), snapped to local
    /// start-of-day and formatted exactly like `handleEditSave`'s own
    /// `wizardLocalISOString(cal.startOfDay(for:))` — so a would-be re-window
    /// (if the fix regressed) is directly comparable against this value.
    private func offsetDaysISO(_ n: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: n, to: Date())!
        return wizardLocalISOString(cal.startOfDay(for: date))
    }

    /// Same day offset as `offsetDaysISO`, but at local noon — used for
    /// `TaskEvent.occurredAt` so the instant is unambiguously inside (or
    /// outside) a given day's window regardless of timezone rounding.
    private func offsetDaysInstantISO(_ n: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: n, to: Date())!
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return wizardLocalISOString(noon)
    }

    /// A completion `TaskEvent` at `occurredAt`, saved directly (bypassing any
    /// cascade) — the exact shape `WindowedBingoCascadeTests.makeCompletionEvent`
    /// uses.
    private func makeCompletionEvent(_ id: String, taskId: String, occurredAt: String, userId: String = "u1") -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// A parameterized board fixture (the other builders in this file hardcode
    /// timeframe/dates) — lets these tests set an arbitrary timeframe +
    /// startDate/endDate/boardSize/center to exercise the re-window matrix.
    private func makeCustomBoard(
        id: String,
        userId: String = "u1",
        timeframe: Timeframe,
        startDate: String,
        endDate: String?,
        boardSize: Int = 3,
        centerSquareType: CenterSquareType = .none,
        name: String = "Board"
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": name, "status": BoardStatus.active.rawValue,
            "boardSize": boardSize, "timeframe": timeframe.rawValue,
            "startDate": startDate,
            "centerSquareType": centerSquareType.rawValue, "isRandomized": false,
            "totalTasks": boardSize * boardSize, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate,
            "version": 1, "isDeleted": false,
        ]
        if let endDate { dict["endDate"] = endDate }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: 14a. Pin the fix — metadata-only Save preserves the window

    func test_handleEditSave_metadataOnlyRename_indefiniteBoard_preservesStartDate_andWindowedCompletion() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        try db.saveBoard(makeCustomBoard(id: "b-indef", timeframe: .indefinite, startDate: start, endDate: nil, boardSize: 1))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-indef", taskId: "t1", row: 0, col: 0))
        try db.dbQueue.write { database in
            try self.makeCompletionEvent("evt1", taskId: "t1", occurredAt: self.offsetDaysInstantISO(-2)).insert(database)
        }

        let vm = loadedVM(db, boardId: "b-indef")
        let liveBoard = try XCTUnwrap(vm.board)
        XCTAssertEqual(liveBoard.timeframe, .indefinite)
        vm.seedEditDraft(from: liveBoard)

        // ONLY a center toggle is staged — no timeframe/date change (name is
        // no longer part of this commit path since Board Edit redesign
        // slice 2 T3; the equivalent "a metadata-only save on an ongoing
        // board preserves the window" case for a NAME edit now lives in
        // `BoardDetailsSaveTests`/`BoardDetailsDraftTests` via
        // `AppDatabase.saveBoardDetails`).
        vm.editCenterType = .free
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b-indef"))
        XCTAssertEqual(saved.centerSquareType, .free)
        XCTAssertEqual(saved.startDate, start,
                       "a metadata-only Save on an INDEFINITE board must not re-anchor startDate to today")
        XCTAssertEqual(saved.completedTasks, 1,
                       "the pre-existing in-window completion must survive the save")

        let vm2 = loadedVM(db, boardId: "b-indef")
        XCTAssertTrue(vm2.windowedState(forTaskId: "t1").isCompleted,
                      "windowed completion must survive a metadata-only save (the worst pre-fix case)")
    }

    func test_handleEditSave_metadataOnlyRename_coreBoard_preservesStartDate_andWindowedCompletion() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        let end = offsetDaysISO(25)
        try db.saveBoard(makeCustomBoard(id: "b-core", timeframe: .monthly, startDate: start, endDate: end, boardSize: 1))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-core", taskId: "t1", row: 0, col: 0))
        try db.dbQueue.write { database in
            try self.makeCompletionEvent("evt1", taskId: "t1", occurredAt: self.offsetDaysInstantISO(-2)).insert(database)
        }

        let vm = loadedVM(db, boardId: "b-core")
        let liveBoard = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: liveBoard)

        // Metadata-only Save: center type change, timeframe/dates untouched.
        vm.editCenterType = .free
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b-core"))
        XCTAssertEqual(saved.centerSquareType, .free)
        XCTAssertEqual(saved.startDate, start,
                       "a metadata-only Save on a CORE (monthly) board must not re-snap to today's window")
        XCTAssertEqual(saved.endDate, end, "endDate must also be preserved, not recomputed")
        XCTAssertEqual(saved.completedTasks, 1, "in-window completion must survive the save")
    }

    // `test_handleEditSave_timeframeChange_deliberatelyRewindows_
    // dropsOutOfWindowCompletion` removed (Board Edit redesign slice 2, T3)
    // — the calendar-timeframe re-window branch was deleted from
    // `handleEditSave` along with `editTimeframe`; a timeframe never
    // switches after creation any more except Custom ⇄ Ongoing, which is
    // `BoardDetailsDraft`'s domain (see `BoardDetailsDraftTests`), not the
    // squares editor's.

    // MARK: 14b. Edit × completion × bingo matrix

    func test_handleEditSave_composedEdit_preservesUntouchedCellsWindowedCompletion() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        let end = offsetDaysISO(25)
        try db.saveBoard(makeCustomBoard(id: "b1", timeframe: .monthly, startDate: start, endDate: end, boardSize: 3))
        for id in ["t1", "t2", "t2b", "t3", "t4", "t5"] {
            try db.saveTask(makeTask(id))
        }
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt3", boardId: "b1", taskId: "t3", row: 0, col: 2))
        try db.saveBoardTask(makeBoardTask(id: "bt4", boardId: "b1", taskId: "t4", row: 1, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt5", boardId: "b1", taskId: "t5", row: 1, col: 1))
        // (2,2) intentionally left empty — the rearrange target.

        let instant = offsetDaysInstantISO(-2)
        try db.dbQueue.write { database in
            for (evtId, taskId) in [("evt1", "t1"), ("evt4", "t4"), ("evt5", "t5")] {
                try self.makeCompletionEvent(evtId, taskId: taskId, occurredAt: instant).insert(database)
            }
        }
        // t2 and t3 stay windowed-incomplete.

        let vm = loadedVM(db, boardId: "b1")
        let liveBoard = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: liveBoard)

        // Board Edit redesign slice 2 (T3): the metadata half of this
        // atomicity check (name, pre-slice-2) is now the center toggle,
        // covered by its OWN dedicated test
        // (`test_handleEditSave_commitsCenterToggle_replacement_and
        // Position_thenEmitsSaved`) — this composition stays squares-only:
        // replace + remove + rearrange.
        vm.handleEditReplace(cellKey: "0-1", taskId: "t2b")             // replace t2 → t2b
        vm.handleEditRemove(cellKey: "1-0")                             // remove t4's cell
        var cells = vm.editSquaresEditCells                             // rearrange: move t5 (1,1) → (2,2)
        let idxOf: (Int, Int) -> Int = { r, c in r * 3 + c }
        cells.swapAt(idxOf(1, 1), idxOf(2, 2))
        vm.handleEditMove(newCells: cells)

        XCTAssertEqual(vm.editSquaresEditCount, 3, "one replace + one removal + one position move")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.startDate, start,
                       "a composed structural Save (replace+remove+rearrange, no timeframe change) must not re-window")

        let placements = try db.fetchBoardTasks(boardId: "b1")
        let bt1 = try XCTUnwrap(placements.first { $0.id == "bt1" })
        XCTAssertEqual(bt1.row, 0, "untouched cell keeps its position")
        XCTAssertEqual(bt1.col, 0, "untouched cell keeps its position")
        let bt2 = try XCTUnwrap(placements.first { $0.id == "bt2" })
        XCTAssertEqual(bt2.taskId, "t2b", "replaced cell now holds the new task")
        let bt3 = try XCTUnwrap(placements.first { $0.id == "bt3" })
        XCTAssertEqual(bt3.taskId, "t3", "untouched cell keeps its task")
        XCTAssertFalse(placements.contains { $0.id == "bt4" }, "removed cell's placement is gone")
        let bt5 = try XCTUnwrap(placements.first { $0.id == "bt5" })
        XCTAssertEqual(bt5.row, 2, "moved cell landed at its staged position")
        XCTAssertEqual(bt5.col, 2, "moved cell landed at its staged position")

        let vm2 = loadedVM(db, boardId: "b1")
        XCTAssertTrue(vm2.windowedState(forTaskId: "t1").isCompleted,
                      "untouched completed cell survives the composed edit")
        XCTAssertFalse(vm2.windowedState(forTaskId: "t3").isCompleted,
                       "untouched incomplete cell stays incomplete — no phantom bleed")
        XCTAssertTrue(vm2.windowedState(forTaskId: "t5").isCompleted,
                      "rearranged cell's windowed completion persists across the position move")
        XCTAssertEqual(saved.completedTasks, 2, "t1 + t5 complete; t2b/t3 incomplete; t4 removed")
    }

    func test_handleEditSave_rearrangeMovesCompletedCell_bingoLinesRecomputePositionally_completionPersists() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        let end = offsetDaysISO(25)
        try db.saveBoard(makeCustomBoard(id: "b1", timeframe: .monthly, startDate: start, endDate: end, boardSize: 3))
        for id in ["t1", "t2", "t3", "t6", "t7"] {
            try db.saveTask(makeTask(id))
        }
        // Pre-edit: row_0 = t1,t2,t3 all windowed-complete.
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt3", boardId: "b1", taskId: "t3", row: 0, col: 2))
        // Also completed, sitting on row_2 with (2,2) left empty for the move target.
        try db.saveBoardTask(makeBoardTask(id: "bt6", boardId: "b1", taskId: "t6", row: 2, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt7", boardId: "b1", taskId: "t7", row: 2, col: 1))

        let instant = offsetDaysInstantISO(-2)
        try db.dbQueue.write { database in
            for (evtId, taskId) in [("e1", "t1"), ("e2", "t2"), ("e3", "t3"), ("e6", "t6"), ("e7", "t7")] {
                try self.makeCompletionEvent(evtId, taskId: taskId, occurredAt: instant).insert(database)
            }
        }

        let vm = loadedVM(db, boardId: "b1")
        let liveBoard = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: liveBoard)
        var cells = vm.editSquaresEditCells
        let idxOf: (Int, Int) -> Int = { r, c in r * 3 + c }
        // Move t3 (0,2) → (2,2): breaks row_0, completes row_2.
        cells.swapAt(idxOf(0, 2), idxOf(2, 2))
        vm.handleEditMove(newCells: cells)

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        let lines = Set(saved.completedLineIds ?? [])
        XCTAssertFalse(lines.contains("row_0"), "row_0 broke — its third cell (t3) moved away")
        XCTAssertTrue(lines.contains("row_2"), "row_2 newly completes — t3 landed on its third cell")

        let bt3 = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt3" })
        XCTAssertEqual(bt3.row, 2, "the moved cell committed to its new position")
        XCTAssertEqual(bt3.col, 2, "the moved cell committed to its new position")

        let vm2 = loadedVM(db, boardId: "b1")
        XCTAssertTrue(vm2.windowedState(forTaskId: "t3").isCompleted,
                      "the moved cell's windowed completion persists through the rearrange")
    }

    func test_handleEditSave_removingCompletedCell_dropsOnlyThatPlacement() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        let end = offsetDaysISO(25)
        try db.saveBoard(makeCustomBoard(id: "bA", timeframe: .monthly, startDate: start, endDate: end, boardSize: 3))
        try db.saveBoard(makeCustomBoard(id: "bB", timeframe: .monthly, startDate: start, endDate: end, boardSize: 1))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        // t1 is placed on BOTH boards — shared-task semantics (CLAUDE.md
        // §Recurring Boards): completing it anywhere completes it everywhere,
        // but a per-board REMOVE must only tombstone that board's placement.
        try db.saveBoardTask(makeBoardTask(id: "btA1", boardId: "bA", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "btA2", boardId: "bA", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "btB1", boardId: "bB", taskId: "t1", row: 0, col: 0))

        let instant = offsetDaysInstantISO(-2)
        try db.dbQueue.write { database in
            for (evtId, taskId) in [("evtT1", "t1"), ("evtT2", "t2")] {
                try self.makeCompletionEvent(evtId, taskId: taskId, occurredAt: instant).insert(database)
            }
        }

        let vm = loadedVM(db, boardId: "bA")
        let liveBoard = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: liveBoard)
        vm.handleEditRemove(cellKey: "0-0")   // removes t1's placement on bA ONLY
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let placementsA = try db.fetchBoardTasks(boardId: "bA")
        XCTAssertFalse(placementsA.contains { $0.id == "btA1" }, "removed placement is gone")
        XCTAssertTrue(placementsA.contains { $0.id == "btA2" }, "sibling placement on the SAME board survives")

        let placementsB = try db.fetchBoardTasks(boardId: "bB")
        XCTAssertTrue(placementsB.contains { $0.id == "btB1" },
                      "removing t1's placement on bA must not cascade-delete its placement on bB")

        let t1Events = try db.dbQueue.read { database in
            try TaskEvent.filter(Column("taskId") == "t1" && Column("isDeleted") == false).fetchAll(database)
        }
        XCTAssertEqual(t1Events.count, 1, "removing a placement must not delete the task's completion event")

        let savedA = try XCTUnwrap(db.fetchBoard(id: "bA"))
        XCTAssertEqual(savedA.completedTasks, 1, "only t2 remains placed+complete on bA")

        let vmB = loadedVM(db, boardId: "bB")
        XCTAssertTrue(vmB.windowedState(forTaskId: "t1").isCompleted,
                      "t1 stays windowed-complete on bB — completion is global per Task, untouched by bA's removal")
    }

    // `test_handleEditSave_customDatesChanged_appliesNewWindow` migrated to
    // `BoardDetailsSaveTests.
    // test_customDatesChanged_appliesNewWindow_dropsOutOfWindowCompletion`
    // (Board Edit redesign slice 2, T3 — dates route through
    // `AppDatabase.saveBoardDetails` now, not `handleEditSave`).
    //
    // `test_handleEditSave_customDatesChanged_endBeforeStart_
    // rejectsSaveWithNoMutation` removed — the end-before-start guard now
    // lives in `BoardDetailsDraft.validationError`
    // (`BoardDetailsDraftTests.test_validation_customEndBeforeStart`), gating
    // `BoardDetailsSheetView`'s Save before `saveBoardDetails` is ever called.

    // MARK: 14c. Cross-interface sweep — kernel / preview / self-heal agree

    func test_handleEditSave_afterSave_kernelCellStates_boardPreview_andSelfHeal_allAgree() throws {
        let db = try makeDb()
        try seedUser(db)
        let start = offsetDaysISO(-5)
        let end = offsetDaysISO(25)
        try db.saveBoard(makeCustomBoard(id: "b1", timeframe: .monthly, startDate: start, endDate: end, boardSize: 3))
        for id in ["t1", "t2", "t3", "t4"] {
            try db.saveTask(makeTask(id))
        }
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt3", boardId: "b1", taskId: "t3", row: 0, col: 2))

        let instant = offsetDaysInstantISO(-2)
        try db.dbQueue.write { database in
            try self.makeCompletionEvent("evt1", taskId: "t1", occurredAt: instant).insert(database)
        }
        // t2, t3 stay windowed-incomplete; t4 is an unplaced replacement target.

        let vm = loadedVM(db, boardId: "b1")
        let liveBoard = try XCTUnwrap(vm.board)
        vm.seedEditDraft(from: liveBoard)
        vm.handleEditReplace(cellKey: "0-1", taskId: "t4")   // t2 → t4 @ (0,1)

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let vm2 = loadedVM(db, boardId: "b1")
        let placements = try db.fetchBoardTasks(boardId: "b1")
        let bt1 = try XCTUnwrap(placements.first { $0.id == "bt1" })
        let bt2 = try XCTUnwrap(placements.first { $0.id == "bt2" })
        let bt3 = try XCTUnwrap(placements.first { $0.id == "bt3" })

        // 1. kernelCellStates (the play grid's source of truth) agrees with
        //    the windowed read for every remaining cell.
        XCTAssertEqual(vm2.kernelCellStates[bt1.id]?.isCompleted, true)
        XCTAssertEqual(vm2.kernelCellStates[bt1.id]?.isCompleted, vm2.windowedState(forTaskId: "t1").isCompleted)
        XCTAssertEqual(vm2.kernelCellStates[bt2.id]?.isCompleted, false)
        XCTAssertEqual(vm2.kernelCellStates[bt2.id]?.isCompleted, vm2.windowedState(forTaskId: "t4").isCompleted)
        XCTAssertEqual(vm2.kernelCellStates[bt3.id]?.isCompleted, false)
        XCTAssertEqual(vm2.kernelCellStates[bt3.id]?.isCompleted, vm2.windowedState(forTaskId: "t3").isCompleted)

        // 2. BoardPreviewCells.build (the mini-preview surface) agrees with
        //    the same per-cell completion.
        let savedBoard = try XCTUnwrap(db.fetchBoard(id: "b1"))
        let workspace = BoardPreviewCells.fetchWorkspaceData(userId: "u1", database: db)
        let preview = BoardPreviewCells.build(
            board: savedBoard,
            boardTasks: placements,
            taskMap: workspace.taskMap,
            childrenByCompound: workspace.childrenByCompound,
            eventsByTaskId: workspace.eventsByTaskId,
            allBoardsInWorkspace: workspace.allBoardsInWorkspace
        )
        XCTAssertEqual(preview.cells[0], .task(completed: true), "(0,0)=t1")
        XCTAssertEqual(preview.cells[1], .task(completed: false), "(0,1)=t4")
        XCTAssertEqual(preview.cells[2], .task(completed: false), "(0,2)=t3")

        // 3. Self-heal (`reDeriveActiveBoards`, the app-open repair pass) is a
        //    no-op — the edit-save already left the board converged, so no
        //    further version bump / stat drift is introduced by editing.
        let versionBeforeHeal = savedBoard.version
        let changed = try db.reDeriveActiveBoards(userId: "u1")
        XCTAssertFalse(changed.contains("b1"),
                       "an edit-save must leave the board self-heal-converged, not needing a repair pass")
        let afterHeal = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(afterHeal.version, versionBeforeHeal,
                       "self-heal must not bump version on an already-converged board")
    }

    // MARK: - 15. Counter arrivals resolve SOURCE counts windowed (issue #377)

    /// The arrival baseline for a SOURCE counting square must match the grid
    /// cell — the board-WINDOWED count from events — never the lifetime
    /// `currentCount` cache. Lifetime says 12 here, but only 5 happened inside
    /// this board's window (which opens 2026-06-21). Mirrors the web pin in
    /// `buildArrivalSquares.test.ts` ("issue #377" case).
    func test_sharedCounterArrivalSquares_sourceResolvesWindowed_issue377() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))

        var source = makeTask("src")
        source.type = .counting
        source.maxCount = 10
        source.currentCount = 12
        source.isCounter = true
        try db.saveTask(source)
        try db.saveBoardTask(makeBoardTask(id: "bt-src", boardId: "b1", taskId: "src", row: 0, col: 0))

        let now = AppDatabase.currentTimestamp()
        try db.write { database in
            for (id, delta, at) in [("e-pre", 7, "2026-06-10T00:00:00.000"),
                                    ("e-in", 5, "2026-06-25T00:00:00.000")] {
                try TaskEvent(
                    id: id, userId: "u1", taskId: "src", kind: .increment,
                    delta: CountValue(delta), occurredAt: at, boardId: nil,
                    createdAt: now, updatedAt: now, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(database)
            }
        }

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board != nil }, "reload never applied")

        let squares = vm.sharedCounterArrivalSquares()
        XCTAssertEqual(squares.count, 1)
        XCTAssertEqual(squares.first?.displayed, 5,
                       "source arrival baseline must be the in-window sum (5), not the lifetime cache (12)")
    }

    // MARK: - Ended-board end bound (2026-09-24 amendment of WC Decision 1)

    /// The play CELL read (`windowedState(of:)` — the view's
    /// `windowedIsCompleted` / `windowedCount` resolve through it) on an
    /// ENDED board ignores increments logged after its `endDate` (e.g. today,
    /// on the next window's board). Twin of web `adaptersWindowEnd.test.ts`.
    func test_playCellRead_onEndedBoard_ignoresIncrementsAfterEndDate() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeOneCellBoard(id: "b1")) // 2026-06-21 … 2026-06-30 — ended
        try db.saveTask(makeCountingTask("c1", maxCount: 5, currentCount: 5))
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))
        try db.write { db in
            for (id, delta, at) in [("in", 3, "2026-06-25T00:00:00.000"), ("after", 2, "2026-07-05T00:00:00.000")] {
                try TaskEvent(
                    id: id, userId: "u1", taskId: "c1", kind: .increment, delta: CountValue(delta),
                    occurredAt: at, boardId: nil, createdAt: at, updatedAt: at,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
        }

        let vm = loadedVM(db, boardId: "b1")
        let task = try XCTUnwrap(vm.taskMap["c1"])
        let state = vm.windowedState(of: task)
        XCTAssertEqual(state.count, 3, "the +2 after endDate is not this board's")
        XCTAssertFalse(state.isCompleted)
        XCTAssertEqual(vm.windowedState(forTaskId: "c1").count, 3)
        XCTAssertEqual(vm.kernelCellStates["bt-c1"]?.isCompleted, false, "cell and kernel agree")
    }

    /// The compound detail sheet's child row and the toggle direction come
    /// from the WINDOWED state bounded at both ends, never the lifetime latch:
    /// a child completed today (latch set) reads incomplete on an ended board,
    /// so a tap COMPLETES it there — stamped at the board's `endDate` — and
    /// keeps today's completion.
    func test_compoundChildToggle_onEndedBoard_followsWindowedState_stampsAtEndDate() throws {
        let db = try makeDb()
        try seedUser(db)
        let board = makeOneCellBoard(id: "b1") // ended
        try db.saveBoard(board)
        try db.saveTask(makeCompoundTask("cmp"))
        var child = makeTask("child1")
        child.isCompleted = true
        child.completedAt = AppDatabase.currentTimestamp()
        try db.saveTask(child)
        try db.saveBoardTask(makeBoardTask(id: "bt-cmp", boardId: "b1", taskId: "cmp", row: 0, col: 0))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "cmp", child: "child1", idx: 0).insert(database)
            try makeCompletionEvent("today", taskId: "child1", occurredAt: AppDatabase.currentTimestamp()).save(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        let loadedChild = try XCTUnwrap(vm.taskMap["child1"])
        XCTAssertTrue(loadedChild.isCompleted, "precondition: the lifetime latch is set")
        XCTAssertFalse(vm.compoundChildIsCompleted(loadedChild), "today's completion is outside the ended window")

        vm.handleCompoundChildToggle(childTask: loadedChild)

        let liveEvents: () -> [TaskEvent] = {
            (try? db.read { try TaskEvent.filter(Column("taskId") == "child1" && Column("isDeleted") == false).fetchAll($0) }) ?? []
        }
        XCTAssertTrue(waitUntil { liveEvents().count == 2 && !vm.isProcessing }, "the tap must COMPLETE, not un-complete")
        let appended = try XCTUnwrap(liveEvents().first { $0.id != "today" })
        let end = try XCTUnwrap(board.endDate)
        XCTAssertEqual(appended.occurredAt, DateFormatting.utcISOString(DateFormatting.parseISO(end)!))
        XCTAssertEqual(try db.fetchBoard(id: "b1")?.completedTasks, 1, "the compound completes in its window")
    }

    /// Final-review F12: a non-compound, non-linked, NON-event-owning child
    /// (a legacy achievement child) owns no events, so it reads its latch —
    /// exactly as web `resolveCompoundChildCompleted` does.
    func test_F12_compoundChildIsCompleted_nonEventOwningChild_readsLatch() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeOneCellBoard(id: "b1"))
        try db.saveTask(makeCompoundTask("cmp"))
        var child = makeTask("ach1")
        child.type = .achievement
        child.isCompleted = true
        try db.saveTask(child)
        try db.saveBoardTask(makeBoardTask(id: "bt-cmp", boardId: "b1", taskId: "cmp", row: 0, col: 0))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "cmp", child: "ach1", idx: 0).insert(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        let loaded = try XCTUnwrap(vm.taskMap["ach1"])
        XCTAssertTrue(vm.compoundChildIsCompleted(loaded), "no events to window — the latch is the state")
    }

    // MARK: - Slice 3 self-review

    /// Unlock → hold-move in ONE session: the unlock must land before the
    /// move, or `updateBoardTaskPositions` rejects the still-locked row and
    /// the whole Save fails.
    func test_handleEditSave_unlockThenMove_sameSession_commits() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.dbQueue.write { database in
            guard var row = try BoardTask.fetchOne(database, key: "bt1") else { return }
            row.isLocked = true
            try row.save(database)
        }

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        XCTAssertEqual(vm.handleEditKeyboardMove(cellId: "bt1", direction: .down), .blockedLocked,
                       "a locked square doesn't move")
        vm.handleEditToggleLock(cellKey: "0-0")
        XCTAssertEqual(vm.handleEditKeyboardMove(cellId: "bt1", direction: .up), .blockedEdge)
        XCTAssertEqual(vm.handleEditKeyboardMove(cellId: "bt1", direction: .down), .moved(row: 1, col: 0))
        XCTAssertNotNil(vm.editSquaresDraft["1-0"])

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
        let bt1 = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt1.row, 1)
        XCTAssertEqual(bt1.col, 0)
        XCTAssertFalse(bt1.isLocked)
    }

    /// Move → Lock in place in ONE session: the lock lands after the move.
    func test_handleEditSave_moveThenLock_sameSession_commits() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        vm.handleEditKeyboardMove(cellId: "bt1", direction: .down)
        vm.handleEditToggleLock(cellKey: "1-0")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
        let bt1 = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt1" })
        XCTAssertEqual(bt1.row, 1)
        XCTAssertEqual(bt1.col, 0)
        XCTAssertTrue(bt1.isLocked)
    }

    /// "Edit task…" on a staged NEW task: the draft task map resolves the
    /// pending task (so the menu action works), and Save inserts it WITH the
    /// staged override applied (web `resolveTask` parity).
    func test_editTask_onPendingAdd_overrideAppliedAtInsert() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t-lib")) // `loadedVM` waits for a non-empty library

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        let now = AppDatabase.currentTimestamp()
        let pendingTask = Task(
            id: "pending-y", userId: "u1", title: "Original", type: .normal,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now,
            version: 1, isDeleted: false
        )
        vm.handleEditAdd(
            cellKey: "0-0", taskId: "pending-y",
            pending: PendingTaskPayload(task: pendingTask, childTasks: [], childLinks: [])
        )
        XCTAssertEqual(vm.editDraftTaskMap["pending-y"]?.title, "Original")

        vm.handleEditTaskOverride(
            taskId: "pending-y",
            patch: SquareEditTaskSheet.Patch(title: "Renamed", type: .normal, action: "", unit: "", maxCount: nil)
        )
        XCTAssertEqual(vm.editDraftTaskMap["pending-y"]?.title, "Renamed")

        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
        let saved = try XCTUnwrap(dbTask(db, "pending-y"))
        XCTAssertEqual(saved.title, "Renamed")
        XCTAssertEqual(saved.createdInWizard, false)
    }

    /// D11 — `editShuffled` goes back to false once every placement is back
    /// on its baseline slot, so later hold-moves count per cell again.
    func test_shuffleFlag_clearsWhenPositionsReturnToBaseline() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 2))

        let vm = loadedVM(db, boardId: "b1")
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))
        let baseline = vm.editSquaresEditCells
        vm.handleEditShuffle(rng: { 0.0 })
        XCTAssertTrue(vm.editShuffled)
        XCTAssertEqual(vm.editSquaresEditCount, 1)

        vm.handleEditMove(newCells: baseline)
        XCTAssertFalse(vm.editShuffled)
        XCTAssertEqual(vm.editSquaresEditCount, 0)

        vm.handleEditKeyboardMove(cellId: "bt1", direction: .down)
        vm.handleEditKeyboardMove(cellId: "bt2", direction: .down)
        XCTAssertEqual(vm.editSquaresEditCount, 2, "two plain moves after the reset count per cell")
    }
}
