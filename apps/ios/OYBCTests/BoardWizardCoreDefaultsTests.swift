import XCTest
@testable import OYBC

/// Task Pools + Recurring Boards Rework (P5) — core-board setup prefill +
/// checkbox-derivation coverage for `BoardWizardViewModel`
/// (docs/POOLS_RECURRING.md §Surfaces item 6, §Behavior invariants
/// "Fillable floor everywhere").
///
/// The prefill resolver (`resolveCoreBoardDefaultPrefill`) is `private
/// static`, so it's only reachable through the wizard's real init path —
/// mirrors how `resolveTemplateHydrationTaskIds` is covered elsewhere.
/// These tests seed a real in-memory `AppDatabase` and construct the VM
/// via `prefilledRecurringTimeframe:` (the banner / core-board-browser
/// launch path), matching `RecurringBoardsSnapshotTests
/// .testSetupStepCoreBoard`'s construction shape.
final class BoardWizardCoreDefaultsTests: XCTestCase {

    private let userId = "u1"
    private static let ts = "2026-01-01T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(_ id: String, title: String? = nil, isDeleted: Bool = false) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: userId, title: title ?? "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func seedTask(_ db: AppDatabase, _ task: OYBC.Task) throws {
        try db.write { grdb in try task.insert(grdb) }
    }

    private func seedPool(_ db: AppDatabase, name: String, taskIds: [String]) throws -> Pool {
        try db.createPoolAndEnqueue(userId: userId, name: name, taskIds: taskIds, now: AppDatabase.currentTimestamp())
    }

    // MARK: - Prefill (via the real init path — resolver is private)

    func testPrefill_UnionsPoolSupplyAndCoreDefaultTaskIds() throws {
        let db = try makeDb()
        try seedUser(db)
        try seedTask(db, makeTask("t1"))
        try seedTask(db, makeTask("t2"))
        try seedTask(db, makeTask("t3")) // individual default, not pool-sourced
        let pool = try seedPool(db, name: "Pool A", taskIds: ["t1", "t2"])
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .weekly, corePoolIds: [pool.id], coreDefaultTaskIds: ["t3"],
            now: AppDatabase.currentTimestamp()
        )

        let vm = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .weekly, userId: userId, database: db
        )

        XCTAssertEqual(vm.selectedTaskIds, ["t1", "t2", "t3"])
        XCTAssertEqual(vm.poolOrder, ["t1", "t2", "t3"])
        XCTAssertEqual(vm.pulledPoolIds, [pool.id])
        // Critical fix under test: nothing is hand-added at init time — the
        // prior code stomped this into `manualTaskIds == selectedTaskIds`.
        XCTAssertTrue(vm.manualTaskIds.isEmpty)
        XCTAssertEqual(vm.savedCorePoolIds, [pool.id])
        XCTAssertTrue(vm.isCore)
    }

    func testPrefill_SkipsDeletedPool() throws {
        let db = try makeDb()
        try seedUser(db)
        try seedTask(db, makeTask("t1"))
        let pool = try seedPool(db, name: "Doomed Pool", taskIds: ["t1"])
        try db.softDeletePoolAndEnqueue(id: pool.id, now: AppDatabase.currentTimestamp())
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .daily, corePoolIds: [pool.id], coreDefaultTaskIds: [],
            now: AppDatabase.currentTimestamp()
        )

        let vm = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .daily, userId: userId, database: db
        )

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
        // savedCorePoolIds reflects the raw stored default even though the
        // pool no longer resolves — the checkbox correctly reads unchecked
        // (pulledPoolIds is empty) rather than the derivation crashing.
        XCTAssertEqual(vm.savedCorePoolIds, [pool.id])
    }

    func testPrefill_SkipsDeletedCoreDefaultTask() throws {
        let db = try makeDb()
        try seedUser(db)
        try seedTask(db, makeTask("t1", isDeleted: true))
        try seedTask(db, makeTask("t2"))
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: [], coreDefaultTaskIds: ["t1", "t2"],
            now: AppDatabase.currentTimestamp()
        )

        let vm = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .monthly, userId: userId, database: db
        )

        XCTAssertEqual(vm.selectedTaskIds, ["t2"])
        XCTAssertEqual(vm.poolOrder, ["t2"])
    }

    func testPrefill_NoCoreBoardDefaultRow_YieldsEmptySelection() throws {
        let db = try makeDb()
        try seedUser(db)

        let vm = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .yearly, userId: userId, database: db
        )

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.poolOrder.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
        XCTAssertTrue(vm.savedCorePoolIds.isEmpty)
        XCTAssertTrue(vm.manualTaskIds.isEmpty)
    }

    // MARK: - isCorePoolDefaultSaved (pure)

    func testIsCorePoolDefaultSaved_TrueOnMatchingSetsOrderIndependent() {
        XCTAssertTrue(BoardWizardViewModel.isCorePoolDefaultSaved(
            pulledPoolIds: ["a", "b"], savedCorePoolIds: ["b", "a"]
        ))
    }

    func testIsCorePoolDefaultSaved_FalseOnMismatch() {
        XCTAssertFalse(BoardWizardViewModel.isCorePoolDefaultSaved(
            pulledPoolIds: ["a", "b"], savedCorePoolIds: ["a"]
        ))
    }

    func testIsCorePoolDefaultSaved_FalseWhenEitherEmpty() {
        XCTAssertFalse(BoardWizardViewModel.isCorePoolDefaultSaved(pulledPoolIds: [], savedCorePoolIds: ["a"]))
        XCTAssertFalse(BoardWizardViewModel.isCorePoolDefaultSaved(pulledPoolIds: ["a"], savedCorePoolIds: []))
        XCTAssertFalse(BoardWizardViewModel.isCorePoolDefaultSaved(pulledPoolIds: [], savedCorePoolIds: []))
    }

    // MARK: - setCorePoolDefaultSaved write path

    func testSetCorePoolDefaultSaved_CheckPersistsCurrentPulledSnapshot() throws {
        let db = try makeDb()
        try seedUser(db)
        let t1 = makeTask("t1")
        try seedTask(db, t1)
        let pool = try seedPool(db, name: "Pool A", taskIds: ["t1"])

        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        vm.timeframe = .weekly
        vm.pullPool(pool.id, poolsById: [pool.id: pool], tasksById: ["t1": t1])

        vm.setCorePoolDefaultSaved(true, userId: userId)

        XCTAssertEqual(vm.savedCorePoolIds, [pool.id])
        let stored = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .weekly))
        XCTAssertEqual(stored.corePoolIds, [pool.id])
    }

    func testSetCorePoolDefaultSaved_UncheckClears() throws {
        let db = try makeDb()
        try seedUser(db)
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .daily, corePoolIds: ["p1"], coreDefaultTaskIds: [],
            now: AppDatabase.currentTimestamp()
        )
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        vm.timeframe = .daily

        vm.setCorePoolDefaultSaved(false, userId: userId)

        XCTAssertEqual(vm.savedCorePoolIds, [])
        let stored = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .daily))
        XCTAssertEqual(stored.corePoolIds, [])
    }

    // MARK: - Floor-gate math (proves it's not hardcoded to 8/3x3)

    func test3x3FreeCenterFloorIs8() {
        XCTAssertEqual(tasksNeededForBoard(size: 3, centerType: .free), 8)
    }

    func test4x4NoneFloorIs16() {
        XCTAssertEqual(tasksNeededForBoard(size: 4, centerType: .none), 16)
    }

    func testFloorGateRemaining_DerivedFromControllerTasksRequired_NotHardcoded() throws {
        let db = try makeDb()
        try seedUser(db)

        let vm3x3 = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .daily, userId: userId, database: db
        )
        vm3x3.updateSize(3)
        vm3x3.updateCenterType(.free)
        XCTAssertEqual(vm3x3.tasksRequired, 8)
        XCTAssertEqual(vm3x3.tasksRequired - vm3x3.selectedTaskIds.count, 8)

        let vm4x4 = BoardWizardViewModel(
            preferences: .defaults, prefilledRecurringTimeframe: .monthly, userId: userId, database: db
        )
        vm4x4.updateSize(4)
        XCTAssertEqual(vm4x4.centerType, .none) // even board forces NONE
        XCTAssertEqual(vm4x4.tasksRequired, 16)
        XCTAssertEqual(vm4x4.tasksRequired - vm4x4.selectedTaskIds.count, 16)
    }
}
