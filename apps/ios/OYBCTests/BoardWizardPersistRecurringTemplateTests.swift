import XCTest
@testable import OYBC

/// Regression coverage for `persistRecurringTemplate`
/// (`BoardWizardPersist.swift`) — Task Pools + Recurring Boards Rework, P3
/// scope-down. A prior revision of this file made `persistRecurringTemplate`
/// write a NEW "native" multi-pool shape (`poolIds`/`manualTaskIds`/
/// `removedTaskIds`) driven by the wizard's SESSION pool-mix state
/// (`pulledPoolIds`/`manualTaskIds`/`removedTaskIds` on
/// `BoardWizardViewModel`), which must not exist before P4
/// (docs/POOLS_RECURRING.md). That introduced two Critical bugs:
///
/// 1. Editing an existing legacy single-pool template and adding ONE
///    ordinary task flipped the wizard's session `manualTaskIds` to
///    non-empty, which flipped the (buggy) shape gate to "non-legacy" and
///    silently stopped writing through to the shared Pool.
/// 2. The Pool lookup used for the write-through path was inconsistent
///    between branches (stale `existing.poolIds?.first` vs. live
///    `pulledPoolIds`), risking writing one pool's flattened tasks into a
///    DIFFERENT, unrelated pool.
///
/// Both are fixed by reverting `persistRecurringTemplate` to the pre-P3
/// (`dev`) logic: the edit-path shape gate reads the FETCHED template's own
/// `existing` shape (never the wizard's session state), and fresh-create
/// always mints exactly one new Pool from the flattened
/// `controller.selectedTaskIds`. These tests drive the REAL
/// `BoardWizardViewModel` mutators (`toggleTaskSelection` / `pullPool` /
/// `untogglePool`) rather than hand-setting VM properties — the shipped bug
/// happened because a prior review used hand-constructed state instead of
/// exercising the real mutators, which masked exactly this class of defect.
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

    // MARK: - Critical 1: edit-path write-through must survive an ordinary
    // task toggle during the same edit session.

    func test_editPath_toggleOrdinaryTask_stillWritesThroughToLinkedPool() throws {
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

        // The regression trigger: an ordinary row toggle during the edit
        // session. This unconditionally marks the task manual in
        // `BoardWizardViewModel.toggleTaskSelection`'s select branch — which
        // is exactly the wizard SESSION state the reverted bug read the
        // shape gate from.
        vm.toggleTaskSelection("z")
        XCTAssertEqual(vm.selectedTaskIds, ["x", "y", "z"])
        XCTAssertTrue(vm.manualTaskIds.contains("z"))

        let expectation = XCTestExpectation(description: "persistRecurringTemplate")
        var outcome: RecurringTemplatePersistOutcome?
        var errorMessage: String?
        persistRecurringTemplate(
            controller: vm,
            userId: userId,
            onSuccess: { result in
                outcome = result
                expectation.fulfill()
            },
            onError: { message in
                errorMessage = message
                expectation.fulfill()
            }
        )
        wait(for: [expectation], timeout: 5.0)

        XCTAssertNil(errorMessage)
        guard case .updated(let templateId) = outcome else {
            XCTFail("Expected .updated outcome, got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(templateId, existingTemplate.id)

        // The shared Pool received the write-through, including the newly
        // toggled ordinary task.
        let updatedPool = try AppDatabase.shared.fetchPool(id: seedPool.id)
        XCTAssertEqual(Set(updatedPool?.taskIds ?? []), ["x", "y", "z"])
        XCTAssertEqual(updatedPool?.version, seedPool.version + 1)

        // The template's OWN pool-mix shape is untouched by the edit — no
        // native multi-pool/manual shape was introduced. This is the crux
        // of the Critical-1 fix: pre-fix, the buggy gate would have read
        // the wizard's now-non-empty `manualTaskIds` and taken the
        // "non-legacy" native-write branch instead, leaving this Pool
        // never updated.
        let refetchedTemplate = try AppDatabase.shared.fetchRecurringBoardTemplate(id: existingTemplate.id)
        XCTAssertEqual(refetchedTemplate?.poolIds, [seedPool.id])
        XCTAssertEqual(refetchedTemplate?.manualTaskIds, [])
        XCTAssertEqual(refetchedTemplate?.removedTaskIds, [])
    }

    // MARK: - Critical 2: fresh-create must always mint exactly ONE new
    // pool from the final flattened selection, never touching an unrelated
    // pool that was pulled in and then untoggled during the session.

    func test_freshCreatePath_pullThenUntogglePool_mintsOnePool_leavesOtherPoolUntouched() throws {
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
        var mintedPoolId: String?
        var createdTemplateId: String?
        var createdBoardId: String?
        defer {
            cleanup(
                poolIds: [poolA.id, poolB.id] + (mintedPoolId.map { [$0] } ?? []),
                templateIds: createdTemplateId.map { [$0] } ?? [],
                boardIds: createdBoardId.map { [$0] } ?? []
            )
        }

        let vm = BoardWizardViewModel(
            preferences: .defaults, startRecurring: true, userId: userId, database: AppDatabase.shared
        )
        vm.name = "Test Recurring"
        vm.timeframe = .daily
        vm.size = 2
        vm.centerType = .none

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

        let expectation = XCTestExpectation(description: "persistRecurringTemplate")
        var outcome: RecurringTemplatePersistOutcome?
        var errorMessage: String?
        persistRecurringTemplate(
            controller: vm,
            userId: userId,
            onSuccess: { result in
                outcome = result
                expectation.fulfill()
            },
            onError: { message in
                errorMessage = message
                expectation.fulfill()
            }
        )
        wait(for: [expectation], timeout: 5.0)

        XCTAssertNil(errorMessage)
        switch outcome {
        case .createdAndSpawned(let templateId, let boardId):
            createdTemplateId = templateId
            createdBoardId = boardId
        case .createdSpawnSkipped(let templateId, _):
            // The template write (what this test verifies) already happened
            // before the spawn was attempted either way, so a skip here
            // (e.g. some other environmental reason) doesn't invalidate the
            // assertions below.
            createdTemplateId = templateId
        case .updated:
            XCTFail("Expected a fresh-create outcome, got .updated")
            return
        case nil:
            XCTFail("Expected a fresh-create outcome, got nil")
            return
        }
        guard let templateId = createdTemplateId else {
            XCTFail("No template id captured")
            return
        }

        // Exactly one NEW pool was minted (Pool A and Pool B are untouched,
        // and no duplicate mint occurred).
        let allPoolsForUser = try AppDatabase.shared.fetchPools(userId: userId)
        let newPools = allPoolsForUser.filter { $0.id != poolA.id && $0.id != poolB.id }
        XCTAssertEqual(newPools.count, 1, "Expected exactly one newly-minted pool")
        let mintedId = try XCTUnwrap(newPools.first?.id)
        mintedPoolId = mintedId
        XCTAssertEqual(Set(newPools.first?.taskIds ?? []), ["m1", "m2", "m3", "m4"])

        // Pool A (pulled in, then untoggled) and Pool B (never touched at
        // all) are both completely untouched — the Critical-2 defect wrote
        // a pulled-then-untoggled pool's contents somewhere they didn't
        // belong.
        let refetchedPoolA = try AppDatabase.shared.fetchPool(id: poolA.id)
        XCTAssertEqual(refetchedPoolA?.taskIds, ["a1", "a2"])
        XCTAssertEqual(refetchedPoolA?.version, poolA.version)
        let refetchedPoolB = try AppDatabase.shared.fetchPool(id: poolB.id)
        XCTAssertEqual(refetchedPoolB?.version, poolBVersionBefore)
        XCTAssertEqual(refetchedPoolB?.taskIds, poolBTaskIdsBefore)

        // The created template carries the legacy P1 shape only — no native
        // multi-pool shape.
        let refetchedTemplate = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId)
        XCTAssertEqual(refetchedTemplate?.poolIds, [mintedId])
        XCTAssertEqual(refetchedTemplate?.manualTaskIds, [])
        XCTAssertEqual(refetchedTemplate?.removedTaskIds, [])
    }
}
