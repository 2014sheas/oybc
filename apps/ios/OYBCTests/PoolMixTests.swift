import XCTest
@testable import OYBC

/// PoolMixTests — Task Pools + Recurring Boards Rework (P1).
///
/// Line-for-line mirror of `packages/shared/tests/algorithms/poolMix.test.ts`,
/// including the worked example from docs/POOLS_RECURRING.md §Changed: the
/// spawn record. Any divergence here would mean iOS and web resolve a
/// migrated (or hand-built) spawn record's mix differently.
final class PoolMixTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal `PoolMixSource` for building ad-hoc test records, mirroring
    /// the TS tests' inline object literals. Default `nil` for every field
    /// so a bare `PoolMixInput()` represents "genuinely un-migrated".
    private struct PoolMixInput: PoolMixSource {
        var poolIds: [String]? = nil
        var manualTaskIds: [String]? = nil
        var removedTaskIds: [String]? = nil
    }

    private func buildTask(_ id: String, isDeleted: Bool = false) -> Task {
        let now = "2026-07-19T00:00:00.000Z"
        return Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func buildPool(_ id: String, _ taskIds: [String], isDeleted: Bool = false) -> Pool {
        let now = "2026-07-19T00:00:00.000Z"
        return Pool(
            id: id, userId: "u1", name: "Pool \(id)", taskIds: taskIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func byId<T>(_ items: [T], id: (T) -> String) -> [String: T] {
        Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
    }

    // MARK: - The worked example (docs §Changed: the spawn record)

    func testWorkedExample_Step1_ABPulled_RemovedY_ManualW_YieldsXZW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: ["w"], removedTaskIds: ["y"]),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x", "z", "w"])
    }

    func testWorkedExample_Step2_UntoggleB_RemovalOfYPersists_YieldsXW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let clearedRemovals = PoolMix.clearRemovalsForUntoggle(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: ["w"], removedTaskIds: ["y"]),
            untoggledPoolId: "B", poolsById: poolsById
        )
        XCTAssertEqual(clearedRemovals, ["y"])

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["w"], removedTaskIds: clearedRemovals),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x", "w"])
    }

    func testWorkedExample_Step3_UntoggleAToo_RemovalCleared_YieldsW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let clearedRemovals = PoolMix.clearRemovalsForUntoggle(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["w"], removedTaskIds: ["y"]),
            untoggledPoolId: "A", poolsById: poolsById
        )
        XCTAssertEqual(clearedRemovals, [])

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: [], manualTaskIds: ["w"], removedTaskIds: clearedRemovals),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["w"])
    }

    func testWorkedExample_Step4_RepullA_RemovalWasCleared_YieldsXYW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["w"], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x", "y", "w"])
    }

    func testWorkedExample_SuppliedByPool_ReflectsEachPulledPoolsResolvableSupply() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: ["w"], removedTaskIds: ["y"]),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.suppliedByPool, ["A": ["x", "y"], "B": ["y", "z"]])
    }

    private func workedExampleFixtures() -> (poolsById: [String: Pool], tasksById: [String: Task]) {
        let x = buildTask("x")
        let y = buildTask("y")
        let z = buildTask("z")
        let w = buildTask("w")
        let poolA = buildPool("A", ["x", "y"])
        let poolB = buildPool("B", ["y", "z"])
        let tasksById = byId([x, y, z, w]) { $0.id }
        let poolsById = byId([poolA, poolB]) { $0.id }
        return (poolsById, tasksById)
    }

    // MARK: - Manual wins over removal

    func testManualWinsOverRemoval_BothManualAndRemoved_IsInMixNoDuplicate() {
        let poolA = buildPool("A", ["y"])
        let tasksById = byId([buildTask("y")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["y"], removedTaskIds: ["y"]),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["y"])
    }

    func testManualOnlyTask_NoPoolSupplies_AppendedAfterPoolSourcedIds() {
        let poolA = buildPool("A", ["x"])
        let tasksById = byId([buildTask("x"), buildTask("m")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["m"], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x", "m"])
    }

    // MARK: - Stale-inert removal entries

    func testStaleInertRemoval_NotSuppliedByAnyPulledPool_HarmlessNoOp() {
        let poolA = buildPool("A", ["x"])
        let tasksById = byId([buildTask("x"), buildTask("never-pulled")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: [], removedTaskIds: ["never-pulled"]),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
    }

    // MARK: - Deleted-pool skip (derived detachment)

    func testDeletedPoolSkip_SoftDeletedPulledPool_ContributesNothingNoSuppliedEntry() {
        let poolA = buildPool("A", ["x"])
        let poolB = buildPool("B", ["y"], isDeleted: true)
        let tasksById = byId([buildTask("x"), buildTask("y")]) { $0.id }
        let poolsById = byId([poolA, poolB]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: [], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
        XCTAssertEqual(result.suppliedByPool, ["A": ["x"]])
    }

    func testDeletedPoolSkip_MissingPoolRecord_SkippedNotAnError() {
        let poolA = buildPool("A", ["x"])
        let tasksById = byId([buildTask("x")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A", "ghost-pool"], manualTaskIds: [], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
        XCTAssertEqual(result.suppliedByPool, ["A": ["x"]])
    }

    // MARK: - Deleted-task skip (resolvable filtering)

    func testDeletedTaskSkip_SoftDeletedTaskInPool_ExcludedFromResolvedSupply() {
        let poolA = buildPool("A", ["x", "y"])
        let tasksById = byId([buildTask("x"), buildTask("y", isDeleted: true)]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: [], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
        XCTAssertEqual(result.suppliedByPool, ["A": ["x"]])
    }

    func testDeletedTaskSkip_MissingTaskRecord_ExcludedNotAnError() {
        let poolA = buildPool("A", ["x", "ghost-task"])
        let tasksById = byId([buildTask("x")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A"], manualTaskIds: [], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
    }

    func testDeletedTaskSkip_ManuallyAddedSoftDeletedTask_StillIncludedVerbatim() {
        // resolveMix resolves POOL supply against non-deleted tasks; the
        // manual layer is caller-curated (the wizard/roster UI only lets a
        // user pick live tasks) and is passed through as-is — mirrors
        // buildSpawnPlacement's "caller must filter" contract for poolTasks.
        let tasksById = byId([buildTask("m", isDeleted: true)]) { $0.id }
        let poolsById: [String: Pool] = [:]

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: [], manualTaskIds: ["m"], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["m"])
    }

    // MARK: - Duplicate poolIds / empty inputs

    func testEdgeInputs_EmptyPoolIdsAndManual_YieldsEmptyMix() {
        let result = PoolMix.resolveMix(PoolMixInput(poolIds: [], manualTaskIds: [], removedTaskIds: []), poolsById: [:], tasksById: [:])
        XCTAssertEqual(result.taskIds, [])
        XCTAssertEqual(result.suppliedByPool, [:])
    }

    func testEdgeInputs_DuplicatePoolId_DoesNotDuplicateSupplyInUnion() {
        let poolA = buildPool("A", ["x"])
        let tasksById = byId([buildTask("x")]) { $0.id }
        let poolsById = byId([poolA]) { $0.id }

        let result = PoolMix.resolveMix(
            PoolMixInput(poolIds: ["A", "A"], manualTaskIds: [], removedTaskIds: []),
            poolsById: poolsById, tasksById: tasksById
        )
        XCTAssertEqual(result.taskIds, ["x"])
    }

    // MARK: - clearRemovalsForUntoggle — additional cases

    func testClearRemovalsForUntoggle_NeverSoleSupplier_LeavesUnrelatedRemovalsUntouched() {
        let poolA = buildPool("A", ["x"])
        let poolB = buildPool("B", ["y"])
        let poolsById = byId([poolA, poolB]) { $0.id }

        let cleared = PoolMix.clearRemovalsForUntoggle(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: [], removedTaskIds: ["x"]),
            untoggledPoolId: "B", poolsById: poolsById
        )
        // x is still supplied by A (untouched by B's untoggle) → persists.
        XCTAssertEqual(cleared, ["x"])
    }

    func testClearRemovalsForUntoggle_DeletedRemainingPool_DoesNotCountAsSupply() {
        let poolA = buildPool("A", ["x"], isDeleted: true)
        let poolB = buildPool("B", ["y"])
        let poolsById = byId([poolA, poolB]) { $0.id }

        let cleared = PoolMix.clearRemovalsForUntoggle(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: [], removedTaskIds: ["x"]),
            untoggledPoolId: "B", poolsById: poolsById
        )
        // A is soft-deleted, so it no longer counts as supply — x's removal clears.
        XCTAssertEqual(cleared, [])
    }

    // MARK: - isLegacyShapedRecord — truth table

    func testIsLegacyShapedRecord_AllThreeFieldsAbsent_True() {
        XCTAssertTrue(PoolMix.isLegacyShapedRecord(PoolMixInput()))
    }

    func testIsLegacyShapedRecord_MigrationMintedShape_True() {
        XCTAssertTrue(PoolMix.isLegacyShapedRecord(
            PoolMixInput(poolIds: ["A"], manualTaskIds: [], removedTaskIds: [])
        ))
    }

    func testIsLegacyShapedRecord_ZeroPoolsExplicitEmptyArrays_True() {
        XCTAssertTrue(PoolMix.isLegacyShapedRecord(
            PoolMixInput(poolIds: [], manualTaskIds: [], removedTaskIds: [])
        ))
    }

    func testIsLegacyShapedRecord_TwoOrMorePools_False() {
        XCTAssertFalse(PoolMix.isLegacyShapedRecord(
            PoolMixInput(poolIds: ["A", "B"], manualTaskIds: [], removedTaskIds: [])
        ))
    }

    func testIsLegacyShapedRecord_AnyManualAdditions_False() {
        XCTAssertFalse(PoolMix.isLegacyShapedRecord(
            PoolMixInput(poolIds: ["A"], manualTaskIds: ["m"], removedTaskIds: [])
        ))
    }

    func testIsLegacyShapedRecord_AnyRemovals_False() {
        XCTAssertFalse(PoolMix.isLegacyShapedRecord(
            PoolMixInput(poolIds: ["A"], manualTaskIds: [], removedTaskIds: ["r"])
        ))
    }

    // MARK: - clampMintedPoolName (review finding I1)

    func testClampMintedPoolName_ShortSourceLeftUntouched() {
        XCTAssertEqual(PoolMix.clampMintedPoolName("Daily", suffix: "default"), "Daily default")
        XCTAssertEqual(
            PoolMix.clampMintedPoolName("Morning Kickstart", suffix: "pool"), "Morning Kickstart pool"
        )
    }

    func testClampMintedPoolName_Boundary_120CharTemplateNameMintsExactly120CharPoolName() {
        // PoolSchema.name (mirrored by the write-helper layer) is bounded to
        // 120 chars — also matches RecurringBoardTemplate.name's own 120-char
        // max, so this is a realistic worst-case source, not a contrived one.
        let name120 = String(repeating: "x", count: 120)
        let minted = PoolMix.clampMintedPoolName(name120, suffix: "pool")
        XCTAssertEqual(minted.count, 120)
        XCTAssertEqual(minted, String(repeating: "x", count: 115) + " pool")
    }

    func testClampMintedPoolName_ExactBoundary_115CharsPlusPoolSuffixIsUntouched() {
        let name115 = String(repeating: "y", count: 115)
        let minted = PoolMix.clampMintedPoolName(name115, suffix: "pool")
        XCTAssertEqual(minted, name115 + " pool")
        XCTAssertEqual(minted.count, 120)
    }

    func testClampMintedPoolName_LongerSuffixClampsSourceToASmallerBudget() {
        let name120 = String(repeating: "z", count: 120)
        let minted = PoolMix.clampMintedPoolName(name120, suffix: "default")
        XCTAssertEqual(minted.count, 120)
        XCTAssertEqual(minted, String(repeating: "z", count: 112) + " default")
    }

    func testClampMintedPoolName_RespectsACustomMaxLen() {
        XCTAssertEqual(PoolMix.clampMintedPoolName("abcdefghij", suffix: "pool", maxLen: 10), "abcde pool")
    }

    // Cross-platform clamp-unit parity (#336 review M-1): must measure UTF-16
    // code units — like PoolSchema's max(120) — not Swift Characters, and must
    // never split a non-BMP surrogate pair. Mirrors the web vector.
    func testClampMintedPoolName_ClampsByUTF16Units_NoSurrogateSplit() {
        // 57 × 🎯 = 114 UTF-16 units; + " pool" (5) = 119 ≤ 120 → unclamped.
        let name57 = String(repeating: "🎯", count: 57)
        let under = PoolMix.clampMintedPoolName(name57, suffix: "pool")
        XCTAssertEqual(under, name57 + " pool")
        XCTAssertEqual(under.utf16.count, 119)

        // 58 × 🎯 = 116 units; source budget 115 → drop the last whole 🎯
        // (never split it) → 57 🎯 + " pool" = 119 ≤ 120.
        let name58 = String(repeating: "🎯", count: 58)
        let clamped = PoolMix.clampMintedPoolName(name58, suffix: "pool")
        XCTAssertEqual(clamped, String(repeating: "🎯", count: 57) + " pool")
        XCTAssertLessThanOrEqual(clamped.utf16.count, 120)
    }
}
