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
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2,
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
        sharedCounterId: String? = nil
    ) -> Task {
        var t = makeTask(id, userId: userId)
        t.type = .counting
        t.action = "Do"
        t.unit = "reps"
        t.maxCount = maxCount
        t.currentCount = currentCount
        t.sharedCounterId = sharedCounterId
        return t
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
        try db.saveBoardTask(makeBoardTask(id: "bt-c1", boardId: "b1", taskId: "c1", row: 0, col: 0))

        let vm = loadedVM(db, boardId: "b1")
        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "c1" })

        // Increment 1 -> 2 reaches goal => completed.
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]))
        XCTAssertTrue(waitUntil { self.dbTask(db, "c1")?.isCompleted == true && !vm.isProcessing })
        XCTAssertEqual(try XCTUnwrap(dbTask(db, "c1")).currentCount, 2)

        // Decrement 2 -> 1 un-completes (standalone legacy path).
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
        XCTAssertTrue(try XCTUnwrap(vm.flashEvent?.creditToast).contains("Board b2"))
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

    // MARK: - 10. cell swap / remove / add

    func test_handleCellSwap_repointsPlacementToNewTask() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")

        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "t1" })
        vm.handleCellSwap(boardTaskId: bt.id, newTaskId: "t2")

        XCTAssertTrue(waitUntil {
            (try? db.fetchBoardTasks(boardId: "b1"))?.first { $0.id == bt.id }?.taskId == "t2"
                && !vm.isProcessing
        }, "swap never repointed the placement")
        let swapped = try XCTUnwrap(db.fetchBoardTasks(boardId: "b1").first { $0.id == bt.id })
        XCTAssertEqual(swapped.taskId, "t2")
    }

    func test_handleRemoveFromBoard_deletesPlacement() throws {
        let db = try makeDb()
        try seedWorkspace(db)
        let vm = loadedVM(db, boardId: "b1")

        let bt = try XCTUnwrap(vm.boardTasks.first { $0.taskId == "t2" })
        vm.handleRemoveFromBoard(boardTaskId: bt.id)

        XCTAssertTrue(waitUntil {
            (try? db.fetchBoardTasks(boardId: "b1"))?.contains { $0.id == bt.id } == false
                && !vm.isProcessing
        }, "placement was never removed")
        XCTAssertEqual(vm.boardTasks.count, 1, "published placements reflect the removal")
    }

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
            } == true && !vm.isProcessing
        }, "placement was never created")
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
}
