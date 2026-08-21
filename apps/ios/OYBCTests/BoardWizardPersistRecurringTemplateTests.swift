import XCTest
@testable import OYBC

/// Regression + behavior coverage for `persistRecurringTemplate`
/// (`BoardWizardPersist.swift`) — Task Pools + Recurring Boards Rework, P4
/// unified-persist-path rewrite.
///
/// P4 retired the P1→P3 shape-scoped legacy write-through
/// (`PoolMix.isLegacyShapedRecord` / pool-minting via
/// `createPoolAndEnqueue`/`updatePoolAndEnqueue`) entirely: this function now
/// ALWAYS persists the controller's own `pulledPoolIds`/`manualTaskIds`/
/// `removedTaskIds` directly — no Pool write-through on edit, no Pool minted
/// on fresh-create. It also drains the wizard's in-memory (Bug #85)
/// `pendingTasks` — for the FULL final selection, not a placement-based
/// subset — BEFORE persisting, which is the actual bug this rewrite fixes:
/// pre-P4, a pending task selected into a repeating board's pool was NEVER
/// written to GRDB, so `PoolMix.resolveMix`/the spawn path's `tasksById`
/// lookup silently dropped it from the mix forever (and could push the mix
/// below the fillable floor, permanently skipping the window).
///
/// The OLD test file (pre-P4) guarded the retired P1-era write-through
/// bugs (a wizard-session-shape read instead of the fetched template's own
/// shape, and an inconsistent Pool lookup between branches). Both bugs are
/// moot now that there is no write-through branch at all — this file is
/// rewritten to assert the NEW native-fields-only behavior instead.
///
/// ── AppDatabase.shared, not makeTestInstance() ──────────────────────────
/// `persistRecurringTemplate` (like `RecurringBoardSpawn.spawnTemplateBoard`
/// — see `RecurringBoardTemplatesTests`'s "End-to-end spawn" note) is a free
/// function that reaches for `AppDatabase.shared` directly; it has no
/// injectable-database seam today, so it cannot be pointed at an isolated
/// `makeTestInstance()`. This is the ONLY test file in the suite that writes
/// through `AppDatabase.shared` as a result. Every test uses a fresh
/// `UUID()`-derived `userId` (and matching real `User`/`Task` rows, required
/// by `PoolMix.resolveMix`'s resolvability check and by the `tasks`/`boards`
/// FK on `users(id)`) and hard-deletes (raw SQL, not soft-delete) every row
/// it creates in a `defer` block scoped by the exact ids it created, so this
/// doesn't leave residue in the shared local database across runs.
final class BoardWizardPersistRecurringTemplateTests: XCTestCase {

    // MARK: - Fixtures

    private func seedUser(_ userId: String) throws {
        let now = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveUser(User(
            id: userId,
            email: "\(userId)@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        ))
    }

    private func seedTask(_ id: String, userId: String) throws {
        let now = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveTask(Task(
            id: id, userId: userId, title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        ))
    }

    /// Seeds a Counting task (Action/Goal/Unit) for staged-edit tests.
    private func seedCountingTask(_ id: String, userId: String, action: String, maxCount: Int, unit: String) throws {
        let now = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveTask(Task(
            id: id, userId: userId,
            title: TaskTitle.generateCounterTaskTitle(action: action, maxCount: maxCount, unit: unit),
            description: nil, type: .counting,
            action: action, unit: unit, maxCount: maxCount,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        ))
    }

    // MARK: - Cleanup helper

    /// Hard-deletes rows created during a test, scoped to the exact ids
    /// passed in (never a broad `DELETE ... WHERE userId = ?`, so a
    /// mid-test throw can't leave a wider blast radius than intended).
    /// Deletion order respects the `tasks`/`boards` → `users` FK
    /// (`foreign_keys = ON`): boards/tasks are dropped before the user row.
    private func cleanup(
        poolIds: [String] = [],
        templateIds: [String] = [],
        boardIds: [String] = [],
        taskIds: [String] = [],
        userIds: [String] = []
    ) {
        try? AppDatabase.shared.write { db in
            for id in boardIds {
                try db.execute(sql: "DELETE FROM board_tasks WHERE boardId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM boards WHERE id = ?", arguments: [id])
            }
            for id in templateIds {
                try db.execute(sql: "DELETE FROM recurring_board_templates WHERE id = ?", arguments: [id])
            }
            for id in poolIds {
                try db.execute(sql: "DELETE FROM pools WHERE id = ?", arguments: [id])
            }
            for id in taskIds {
                try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [id])
            }
            for id in userIds {
                try db.execute(sql: "DELETE FROM users WHERE id = ?", arguments: [id])
            }
            for id in poolIds + templateIds + boardIds {
                try db.execute(sql: "DELETE FROM sync_queue WHERE entityId = ?", arguments: [id])
            }
        }
    }

    /// Runs `persistRecurringTemplate` synchronously (wraps the
    /// callback-based free function in an `XCTestExpectation`), returning
    /// the outcome or failing the test on an unexpected error.
    private func runPersist(
        controller: BoardWizardViewModel, userId: String
    ) throws -> RecurringTemplatePersistOutcome {
        let expectation = XCTestExpectation(description: "persistRecurringTemplate")
        var outcome: RecurringTemplatePersistOutcome?
        var errorMessage: String?
        persistRecurringTemplate(
            controller: controller,
            userId: userId,
            onSuccess: { result in outcome = result; expectation.fulfill() },
            onError: { message in errorMessage = message; expectation.fulfill() }
        )
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNil(errorMessage)
        return try XCTUnwrap(outcome)
    }

    // MARK: - 1. Edit path writes native fields directly, no Pool write-through

    func test_editPath_writesNativeFieldsDirectly_neverTouchesLinkedPool() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let now = AppDatabase.currentTimestamp()

        try seedUser(userId)
        try seedTask("x", userId: userId)
        try seedTask("y", userId: userId)
        try seedTask("z", userId: userId)
        defer { cleanup(taskIds: ["x", "y", "z"], userIds: [userId]) }

        let seedPool = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Seed Pool", taskIds: ["x", "y"], now: now
        )
        let existingTemplate = RecurringBoardTemplate(
            id: AppDatabase.generateUUID(),
            userId: userId,
            name: "Daily",
            timeframe: .daily,
            boardSize: 3,
            centerSquareType: .none,
            isRandomized: true,
            seedTaskIds: ["x", "y"],
            poolIds: [seedPool.id],
            manualTaskIds: [],
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
        try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
            existingTemplate, operation: .create, now: now
        )
        defer { cleanup(poolIds: [seedPool.id], templateIds: [existingTemplate.id]) }

        // Hydrate the wizard exactly as the real Edit-template entry point
        // does: via the `editingTemplate:` initializer parameter.
        let vm = BoardWizardViewModel(
            preferences: .defaults,
            editingTemplate: existingTemplate,
            userId: userId,
            database: AppDatabase.shared
        )
        XCTAssertEqual(vm.selectedTaskIds, ["x", "y"])
        XCTAssertEqual(vm.pulledPoolIds, [seedPool.id])
        XCTAssertTrue(vm.manualTaskIds.isEmpty)

        // An ordinary row toggle during the edit session — marks "z" manual.
        vm.toggleTaskSelection("z")
        XCTAssertEqual(vm.selectedTaskIds, ["x", "y", "z"])
        XCTAssertTrue(vm.manualTaskIds.contains("z"))

        let outcome = try runPersist(controller: vm, userId: userId)
        guard case .updated(let templateId) = outcome else {
            XCTFail("Expected .updated outcome, got \(outcome)")
            return
        }
        XCTAssertEqual(templateId, existingTemplate.id)

        // P4: the template's OWN native fields are written directly —
        // poolIds unchanged (still the one pulled pool), manualTaskIds
        // gains "z", removedTaskIds empty.
        let refetchedTemplate = try AppDatabase.shared.fetchRecurringBoardTemplate(id: existingTemplate.id)
        XCTAssertEqual(refetchedTemplate?.poolIds, [seedPool.id])
        XCTAssertEqual(refetchedTemplate?.manualTaskIds, ["z"])
        XCTAssertEqual(refetchedTemplate?.removedTaskIds, [])

        // P4's crux: the shared Pool is NEVER touched by an edit anymore —
        // no write-through. Pre-P4 this pool would have received "z" too.
        let updatedPool = try AppDatabase.shared.fetchPool(id: seedPool.id)
        XCTAssertEqual(updatedPool?.taskIds, ["x", "y"])
        XCTAssertEqual(updatedPool?.version, seedPool.version)
    }

    // MARK: - 2. Fresh-create path never mints a Pool

    func test_freshCreatePath_pullThenUntogglePool_mintsNoPool_persistsNativeFields() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let now = AppDatabase.currentTimestamp()
        let allTaskIds = ["a1", "a2", "b1", "b2", "m1", "m2", "m3", "m4"]

        try seedUser(userId)
        for id in allTaskIds { try seedTask(id, userId: userId) }
        defer { cleanup(taskIds: allTaskIds, userIds: [userId]) }

        let poolA = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Pool A", taskIds: ["a1", "a2"], now: now
        )
        let poolB = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Pool B", taskIds: ["b1", "b2"], now: now
        )
        let poolBVersionBefore = poolB.version
        let poolBTaskIdsBefore = poolB.taskIds
        var createdTemplateId: String?
        var createdBoardId: String?
        defer {
            cleanup(
                poolIds: [poolA.id, poolB.id],
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? []
            )
        }

        // Board Creation Split (iOS PR A) — recurring mode is now fixed at
        // init via `startRecurring`; the retired `setRepeats(_:)` mid-wizard
        // toggle is gone. Cadence is still adjustable post-init via
        // `updateTimeframe(_:)` (used below where a test wants Daily).
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Test Recurring"
        vm.size = 2
        vm.centerType = .none
        vm.updateTimeframe(.daily)

        let poolsById = [poolA.id: poolA, poolB.id: poolB]
        let tasksById = Dictionary(
            uniqueKeysWithValues: try allTaskIds.map { id -> (String, Task) in
                (id, try XCTUnwrap(AppDatabase.shared.fetchTask(id: id)))
            }
        )
        // Pull pool A in, then untoggle it back out — exercising the REAL
        // pull/untoggle mutators, not hand-set VM state.
        vm.pullPool(poolA.id, poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(vm.pulledPoolIds, [poolA.id])
        XCTAssertEqual(vm.selectedTaskIds, ["a1", "a2"])
        vm.untogglePool(poolA.id, poolsById: poolsById, tasksById: tasksById)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
        XCTAssertTrue(vm.selectedTaskIds.isEmpty)

        // Fill the 2x2 board (centerType .none ⇒ no reserved center) by
        // hand via the real toggle mutator.
        for taskId in ["m1", "m2", "m3", "m4"] {
            vm.toggleTaskSelection(taskId)
        }
        XCTAssertEqual(vm.selectedTaskIds, ["m1", "m2", "m3", "m4"])

        let outcome = try runPersist(controller: vm, userId: userId)
        switch outcome {
        case .createdAndSpawned(let templateId, let boardId):
            createdTemplateId = templateId
            createdBoardId = boardId
        case .createdSpawnSkipped(let templateId, _):
            createdTemplateId = templateId
        case .updated:
            XCTFail("Expected a fresh-create outcome, got .updated")
            return
        }
        guard let templateId = createdTemplateId else {
            XCTFail("No template id captured")
            return
        }

        // P4 crux: NO new pool was minted at all — pull-then-untoggle left
        // the mix entirely in the manual layer, and fresh-create no longer
        // auto-mints a Pool from the selection.
        let allPoolsForUser = try AppDatabase.shared.fetchPools(userId: userId)
        let newPools = allPoolsForUser.filter { $0.id != poolA.id && $0.id != poolB.id }
        XCTAssertEqual(newPools.count, 0, "P4 must never mint a Pool on fresh-create")

        // Pool A (pulled in, then untoggled) and Pool B (never touched at
        // all) are both completely untouched.
        let refetchedPoolA = try AppDatabase.shared.fetchPool(id: poolA.id)
        XCTAssertEqual(refetchedPoolA?.taskIds, ["a1", "a2"])
        XCTAssertEqual(refetchedPoolA?.version, poolA.version)
        let refetchedPoolB = try AppDatabase.shared.fetchPool(id: poolB.id)
        XCTAssertEqual(refetchedPoolB?.version, poolBVersionBefore)
        XCTAssertEqual(refetchedPoolB?.taskIds, poolBTaskIdsBefore)

        // The created template carries the native shape straight from the
        // controller's own pool-mix state: no pools pulled, all 4 tasks manual.
        let refetchedTemplate = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId)
        XCTAssertEqual(refetchedTemplate?.poolIds, [])
        XCTAssertEqual(Set(refetchedTemplate?.manualTaskIds ?? []), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(refetchedTemplate?.removedTaskIds, [])
    }

    // MARK: - Regression A: pending (Bug #85) task drain — the actual bug

    /// Drives a REAL `BoardWizardViewModel`: selects real library tasks up
    /// to ONE SHORT of the fillable floor (8, for a 3×3 board with a FREE
    /// center), then adds a not-yet-persisted pending task via
    /// `toggleTaskSelection` + `addPendingTask` (mirroring the wizard's
    /// inline "New Task" sheet), sets Repeats to Daily, and persists.
    ///
    /// Pre-fix: the pending task was never written to GRDB, so the spawn
    /// path's `tasksById` lookup dropped it — the mix landed at 7 (one
    /// short of the floor) and the window was skipped FOREVER
    /// (`.createdSpawnSkipped(reason: .poolTooSmall)`), with no way for the
    /// user to recover short of re-adding the task.
    ///
    /// Post-fix: the pending task is drained into GRDB before the spawn
    /// resolves the mix, so all 8 tasks are there and the board spawns.
    func test_pendingTaskDrain_repeatingBoard_spawnsWithPendingTaskIncluded() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let realTaskIds = (0..<7).map { "real-\($0)" }
        try seedUser(userId)
        for id in realTaskIds { try seedTask(id, userId: userId) }
        var createdTemplateId: String?
        var createdBoardId: String?
        let pendingId = "pending-\(UUID().uuidString)"
        defer {
            cleanup(
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? [],
                taskIds: realTaskIds + [pendingId],
                userIds: [userId]
            )
        }

        // Board Creation Split (iOS PR A) — recurring mode is now fixed at
        // init via `startRecurring`; the retired `setRepeats(_:)` mid-wizard
        // toggle is gone. Cadence is still adjustable post-init via
        // `updateTimeframe(_:)` (used below where a test wants Daily).
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Daily Habits"
        vm.size = 3
        vm.centerType = .free // fillable floor = 3*3 - 1 = 8

        for id in realTaskIds { vm.toggleTaskSelection(id) }
        XCTAssertEqual(vm.selectedTaskIds.count, 7, "one short of the 8-task fillable floor")

        // Bug #85 — mirrors the wizard's inline "New Task" sheet: select
        // first, then stash the deferred payload.
        let now = AppDatabase.currentTimestamp()
        let pendingTask = Task(
            id: pendingId, userId: userId, title: "Not yet persisted", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        vm.toggleTaskSelection(pendingId)
        vm.addPendingTask(PendingTaskPayload(task: pendingTask, childTasks: [], childLinks: []))
        XCTAssertEqual(vm.selectedTaskIds.count, 8)

        vm.updateTimeframe(.daily)
        XCTAssertTrue(vm.isRecurring)

        // Sanity: the pending task does NOT exist in GRDB yet.
        XCTAssertNil(try AppDatabase.shared.fetchTask(id: pendingId))

        let outcome = try runPersist(controller: vm, userId: userId)

        // (a) The pending task now exists in GRDB.
        let persistedPending = try AppDatabase.shared.fetchTask(id: pendingId)
        XCTAssertNotNil(persistedPending, "pending task must be drained into GRDB")
        XCTAssertEqual(persistedPending?.title, "Not yet persisted")

        // (b) The outcome is a successful spawn — NOT a pool_too_small skip,
        // which is exactly what the pre-fix bug produced.
        guard case .createdAndSpawned(let templateId, let boardId) = outcome else {
            XCTFail("Expected .createdAndSpawned, got \(outcome) — the pending task likely fell out of the mix")
            return
        }
        createdTemplateId = templateId
        createdBoardId = boardId

        // (c) The spawned board is filled to exactly the fillable floor and
        // includes the pending task's placement.
        let boardTasks = try AppDatabase.shared.fetchBoardTasks(boardId: boardId)
        XCTAssertEqual(boardTasks.count, 8)
        XCTAssertTrue(boardTasks.contains { $0.taskId == pendingId })
    }

    // MARK: - Regression B: recurring finish produces a template, never a draft Board

    /// Both the fresh-create and edit branches of `persistRecurringTemplate`
    /// — the SAME function `BoardWizardView.handleDialogSaveDraft` calls
    /// when `controller.isRecurring` (verified by inspection: that branch is
    /// a direct passthrough with identical outcome handling to
    /// `BoardWizardPreviewStepView.performCreation`'s recurring branch) —
    /// must produce a `RecurringBoardTemplate` row, never a one-off DRAFT
    /// `Board`. Pre-P4, the cancel dialog's "Save Draft" path ignored
    /// `controller.isRecurring` entirely and always called the one-off
    /// `persistWizardBoard`, silently saving a draft Board instead.
    func test_recurringFinish_freshCreate_producesTemplateNotDraftBoard() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let taskIds = (0..<4).map { "t-\($0)" }
        try seedUser(userId)
        for id in taskIds { try seedTask(id, userId: userId) }
        var createdTemplateId: String?
        var createdBoardId: String?
        defer {
            cleanup(
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? [],
                taskIds: taskIds,
                userIds: [userId]
            )
        }

        // Board Creation Split (iOS PR A) — recurring mode is now fixed at
        // init via `startRecurring`; the retired `setRepeats(_:)` mid-wizard
        // toggle is gone. Cadence is still adjustable post-init via
        // `updateTimeframe(_:)` (used below where a test wants Daily).
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Weekly Reset"
        vm.size = 2
        vm.centerType = .none
        for id in taskIds { vm.toggleTaskSelection(id) }
        vm.updateTimeframe(.weekly)

        let outcome = try runPersist(controller: vm, userId: userId)
        guard case .createdAndSpawned(let templateId, let boardId) = outcome else {
            XCTFail("Expected .createdAndSpawned, got \(outcome)")
            return
        }
        createdTemplateId = templateId
        createdBoardId = boardId

        // A RecurringBoardTemplate row exists...
        let template = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId)
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.timeframe, .weekly)

        // ...and the spawned board is ACTIVE, never a draft — this is what
        // the cancel-dialog's pre-P4 bug produced instead of a template.
        let board = try AppDatabase.shared.fetchBoard(id: boardId)
        XCTAssertEqual(board?.status, .active)
        XCTAssertEqual(board?.spawnedFromTemplateId, templateId)
    }

    func test_recurringFinish_edit_updatesTemplateInPlace_neverCreatesBoard() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let taskIds = ["x", "y"]
        try seedUser(userId)
        for id in taskIds { try seedTask(id, userId: userId) }
        let now = AppDatabase.currentTimestamp()
        defer { cleanup(taskIds: taskIds, userIds: [userId]) }

        let existingTemplate = RecurringBoardTemplate(
            id: AppDatabase.generateUUID(),
            userId: userId,
            name: "Monthly Check-in",
            timeframe: .monthly,
            boardSize: 2,
            centerSquareType: .none,
            isRandomized: true,
            seedTaskIds: taskIds,
            poolIds: [],
            manualTaskIds: taskIds,
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
        try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
            existingTemplate, operation: .create, now: now
        )
        defer { cleanup(templateIds: [existingTemplate.id]) }

        let boardCountBefore = try AppDatabase.shared.fetchBoards(userId: userId).count

        let vm = BoardWizardViewModel(
            preferences: .defaults, editingTemplate: existingTemplate, userId: userId, database: AppDatabase.shared
        )
        vm.name = "Monthly Check-in (renamed)"

        let outcome = try runPersist(controller: vm, userId: userId)
        guard case .updated(let templateId) = outcome else {
            XCTFail("Expected .updated, got \(outcome)")
            return
        }
        XCTAssertEqual(templateId, existingTemplate.id)

        let refetched = try AppDatabase.shared.fetchRecurringBoardTemplate(id: existingTemplate.id)
        XCTAssertEqual(refetched?.name, "Monthly Check-in (renamed)")

        // No new Board was created by an edit.
        let boardCountAfter = try AppDatabase.shared.fetchBoards(userId: userId).count
        XCTAssertEqual(boardCountAfter, boardCountBefore)
    }

    // MARK: - `?editTemplate=`-equivalent native-shape round-trip

    /// Hydrating from a NATIVE-shaped template (2 pools + manual additions)
    /// and making a small edit must round-trip without flattening OR
    /// mutating either shared pool — "not flattened, not pool-mutated"
    /// (docs/POOLS_RECURRING.md §Migration "seedTaskIds end state").
    func test_editTemplate_nativeShapeRoundTrip_notFlattened_notPoolMutated() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let now = AppDatabase.currentTimestamp()
        let allTaskIds = ["a1", "a2", "b1", "b2", "manual-1", "manual-2"]
        try seedUser(userId)
        for id in allTaskIds { try seedTask(id, userId: userId) }
        defer { cleanup(taskIds: allTaskIds, userIds: [userId]) }

        let poolA = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Pool A", taskIds: ["a1", "a2"], now: now
        )
        let poolB = try AppDatabase.shared.createPoolAndEnqueue(
            userId: userId, name: "Pool B", taskIds: ["b1", "b2"], now: now
        )
        defer { cleanup(poolIds: [poolA.id, poolB.id]) }

        let existingTemplate = RecurringBoardTemplate(
            id: AppDatabase.generateUUID(),
            userId: userId,
            name: "Native Shape Template",
            timeframe: .weekly,
            boardSize: 3,
            centerSquareType: .none,
            isRandomized: true,
            seedTaskIds: ["a1", "a2", "b1", "b2", "manual-1"],
            poolIds: [poolA.id, poolB.id],
            manualTaskIds: ["manual-1"],
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
        try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
            existingTemplate, operation: .create, now: now
        )
        defer { cleanup(templateIds: [existingTemplate.id]) }

        let vm = BoardWizardViewModel(
            preferences: .defaults, editingTemplate: existingTemplate, userId: userId, database: AppDatabase.shared
        )
        // Hydration resolves the mix natively — 2 pools + the manual layer.
        XCTAssertEqual(vm.pulledPoolIds.count, 2)
        XCTAssertEqual(vm.manualTaskIds, ["manual-1"])
        XCTAssertEqual(vm.selectedTaskIds, ["a1", "a2", "b1", "b2", "manual-1"])

        // A small edit: hand-add one more manual task. Never touches pools.
        vm.toggleTaskSelection("manual-2")

        let outcome = try runPersist(controller: vm, userId: userId)
        guard case .updated = outcome else {
            XCTFail("Expected .updated, got \(outcome)")
            return
        }

        let refetched = try AppDatabase.shared.fetchRecurringBoardTemplate(id: existingTemplate.id)
        // Still 2 pools — the edit didn't collapse/flatten the native shape.
        XCTAssertEqual(refetched?.poolIds?.count, 2)
        XCTAssertEqual(Set(refetched?.poolIds ?? []), [poolA.id, poolB.id])
        // The manual layer reflects the edit (both the original AND the new one).
        XCTAssertEqual(Set(refetched?.manualTaskIds ?? []), ["manual-1", "manual-2"])
        XCTAssertEqual(refetched?.removedTaskIds, [])

        // Neither shared pool was mutated by the edit.
        let refetchedPoolA = try AppDatabase.shared.fetchPool(id: poolA.id)
        XCTAssertEqual(refetchedPoolA?.taskIds, ["a1", "a2"])
        XCTAssertEqual(refetchedPoolA?.version, poolA.version)
        let refetchedPoolB = try AppDatabase.shared.fetchPool(id: poolB.id)
        XCTAssertEqual(refetchedPoolB?.taskIds, ["b1", "b2"])
        XCTAssertEqual(refetchedPoolB?.version, poolB.version)
    }

    // MARK: - Regression C: staged inline edits (Inline Task Editing) must not
    // be dropped on a repeating board's persist path.
    //
    // Pre-fix: `persistRecurringTemplate` never read `controller.stagedEdits`
    // at all, so an inline edit made while building/editing a REPEATING
    // board's task pool (rename, counting-goal change, compound sub-task
    // edit) was silently dropped on save — the pre-edit task values
    // persisted even though the Preview step showed the edit applied (via
    // `buildWizardPlacement`'s staged-edit overlay). These tests drive the
    // REAL controller mutators (`stageEdit`, `toggleTaskSelection`,
    // `addPendingTask`) and assert the persisted `Task` row reflects the
    // edit — they fail before the fix (task values are unedited) and pass
    // after it.

    /// Fresh-create branch: a staged rename on a Normal library task and a
    /// staged goal change on a Counting library task must both land globally
    /// once the repeating board is created.
    func test_freshCreate_appliesStagedEdits_normalAndCountingLibraryTasks() throws {
        let userId = "test-user-\(UUID().uuidString)"
        try seedUser(userId)
        try seedTask("normal-1", userId: userId)
        try seedCountingTask("counting-1", userId: userId, action: "Read", maxCount: 10, unit: "pages")
        try seedTask("filler-1", userId: userId)
        try seedTask("filler-2", userId: userId)
        let taskIds = ["normal-1", "counting-1", "filler-1", "filler-2"]
        var createdTemplateId: String?
        var createdBoardId: String?
        defer {
            cleanup(
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? [],
                taskIds: taskIds,
                userIds: [userId]
            )
        }

        // Board Creation Split (iOS PR A) — recurring mode is now fixed at
        // init via `startRecurring`; the retired `setRepeats(_:)` mid-wizard
        // toggle is gone. Cadence is still adjustable post-init via
        // `updateTimeframe(_:)` (used below where a test wants Daily).
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Daily Chores"
        vm.size = 2
        vm.centerType = .none // fillable floor = 2*2 = 4, matches taskIds.count
        for id in taskIds { vm.toggleTaskSelection(id) }
        XCTAssertEqual(vm.selectedTaskIds.count, 4)

        // Stage an inline rename on the Normal task via the real editor patch.
        let normalTask = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "normal-1"))
        var normalPatch = TaskEditPatch.seededForEditor(from: normalTask)
        normalPatch.title = "Take out recycling"
        vm.stageEdit(normalPatch, for: "normal-1")

        // Stage a goal change on the Counting task via the real editor patch.
        let countingTask = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "counting-1"))
        var countingPatch = TaskEditPatch.seededForEditor(from: countingTask)
        countingPatch.goal = "25"
        vm.stageEdit(countingPatch, for: "counting-1")

        vm.updateTimeframe(.daily)
        XCTAssertTrue(vm.isRecurring)

        let outcome = try runPersist(controller: vm, userId: userId)
        switch outcome {
        case .createdAndSpawned(let templateId, let boardId):
            createdTemplateId = templateId
            createdBoardId = boardId
        case .createdSpawnSkipped(let templateId, _):
            createdTemplateId = templateId
        case .updated:
            XCTFail("Expected a fresh-create outcome, got .updated")
            return
        }

        // The staged edits must be persisted globally on the Task rows —
        // pre-fix, both tasks would still carry their ORIGINAL values here.
        let persistedNormal = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "normal-1"))
        XCTAssertEqual(persistedNormal.title, "Take out recycling")
        XCTAssertGreaterThan(persistedNormal.version, normalTask.version)

        let persistedCounting = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "counting-1"))
        XCTAssertEqual(persistedCounting.maxCount, 25)
        XCTAssertEqual(
            persistedCounting.title,
            TaskTitle.generateCounterTaskTitle(action: "Read", maxCount: 25, unit: "pages"),
            "counting title must regenerate from the edited goal"
        )
        XCTAssertGreaterThan(persistedCounting.version, countingTask.version)
    }

    /// Fresh-create branch: a staged edit on a not-yet-persisted (Bug #85)
    /// pending task must be merged into the payload BEFORE it's drained into
    /// GRDB, so the pending task lands with its EDITED values, never its
    /// pre-edit draft values.
    func test_freshCreate_appliesStagedEdit_toPendingTaskBeforeDrain() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let realTaskIds = ["r1", "r2", "r3"]
        try seedUser(userId)
        for id in realTaskIds { try seedTask(id, userId: userId) }
        let pendingId = "pending-\(UUID().uuidString)"
        var createdTemplateId: String?
        var createdBoardId: String?
        defer {
            cleanup(
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? [],
                taskIds: realTaskIds + [pendingId],
                userIds: [userId]
            )
        }

        // Board Creation Split (iOS PR A) — recurring mode is now fixed at
        // init via `startRecurring`; the retired `setRepeats(_:)` mid-wizard
        // toggle is gone. Cadence is still adjustable post-init via
        // `updateTimeframe(_:)` (used below where a test wants Daily).
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared)
        vm.name = "Weekly Habits"
        vm.size = 2
        vm.centerType = .none
        for id in realTaskIds { vm.toggleTaskSelection(id) }

        let now = AppDatabase.currentTimestamp()
        let pendingTask = Task(
            id: pendingId, userId: userId, title: "Draft title", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        vm.toggleTaskSelection(pendingId)
        vm.addPendingTask(PendingTaskPayload(task: pendingTask, childTasks: [], childLinks: []))
        XCTAssertEqual(vm.selectedTaskIds.count, 4)

        // Edit the still-pending task before it's ever been written to GRDB.
        var patch = TaskEditPatch.seededForEditor(from: pendingTask)
        patch.title = "Edited before create"
        vm.stageEdit(patch, for: pendingId)

        vm.updateTimeframe(.weekly)

        let outcome = try runPersist(controller: vm, userId: userId)
        switch outcome {
        case .createdAndSpawned(let templateId, let boardId):
            createdTemplateId = templateId
            createdBoardId = boardId
        case .createdSpawnSkipped(let templateId, _):
            createdTemplateId = templateId
        case .updated:
            XCTFail("Expected a fresh-create outcome, got .updated")
            return
        }

        let persistedPending = try XCTUnwrap(AppDatabase.shared.fetchTask(id: pendingId))
        XCTAssertEqual(
            persistedPending.title, "Edited before create",
            "the pending task's staged edit must be merged in before the drain write"
        )
    }

    /// Edit branch: staging an inline edit on a template's already-selected
    /// library task, then re-saving the (unchanged-cadence) template, must
    /// apply the edit globally — this is the OTHER branch of
    /// `persistRecurringTemplate` that pre-fix never read `stagedEdits`.
    func test_editBranch_appliesStagedEdit_toSelectedLibraryTask() throws {
        let userId = "test-user-\(UUID().uuidString)"
        let taskIds = ["e1", "e2"]
        try seedUser(userId)
        for id in taskIds { try seedTask(id, userId: userId) }
        let now = AppDatabase.currentTimestamp()
        defer { cleanup(taskIds: taskIds, userIds: [userId]) }

        let existingTemplate = RecurringBoardTemplate(
            id: AppDatabase.generateUUID(),
            userId: userId,
            name: "Evening Routine",
            timeframe: .daily,
            boardSize: 2,
            centerSquareType: .none,
            isRandomized: true,
            seedTaskIds: taskIds,
            poolIds: [],
            manualTaskIds: taskIds,
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
        try AppDatabase.shared.saveRecurringBoardTemplateAndEnqueue(
            existingTemplate, operation: .create, now: now
        )
        defer { cleanup(templateIds: [existingTemplate.id]) }

        let vm = BoardWizardViewModel(
            preferences: .defaults, editingTemplate: existingTemplate, userId: userId, database: AppDatabase.shared
        )
        XCTAssertEqual(vm.selectedTaskIds, ["e1", "e2"])

        let libraryTask = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "e1"))
        var patch = TaskEditPatch.seededForEditor(from: libraryTask)
        patch.title = "Brush teeth"
        vm.stageEdit(patch, for: "e1")

        let outcome = try runPersist(controller: vm, userId: userId)
        guard case .updated(let templateId) = outcome else {
            XCTFail("Expected .updated outcome, got \(outcome)")
            return
        }
        XCTAssertEqual(templateId, existingTemplate.id)

        let persisted = try XCTUnwrap(AppDatabase.shared.fetchTask(id: "e1"))
        XCTAssertEqual(persisted.title, "Brush teeth", "staged edit must apply on the edit branch too")
        XCTAssertGreaterThan(persisted.version, libraryTask.version)
    }
}
