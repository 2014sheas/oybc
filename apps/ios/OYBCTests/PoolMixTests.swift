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
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
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

    // MARK: - F5: legacy-template edit preserves soft-deleted-but-not-removed refs
    // Swift twins of poolMix.test.ts's `mergeLegacyPoolTaskIds` cases.

    func testMergeLegacyPoolTaskIds_PreservesSoftDeletedNotRemovedRef() {
        let live = buildTask("live")
        let gone = buildTask("gone", isDeleted: true)
        let tasksById = byId([live, gone], id: { $0.id })
        let merged = PoolMix.mergeLegacyPoolTaskIds(
            ["live", "gone"], selectedTaskIds: ["live"], tasksById: tasksById
        )
        // `gone` survives (never shown to the user → can't have been removed).
        XCTAssertEqual(merged, ["live", "gone"])
    }

    func testMergeLegacyPoolTaskIds_DropsExplicitlyRemovedResolvableRef() {
        let a = buildTask("a")
        let b = buildTask("b")
        let tasksById = byId([a, b], id: { $0.id })
        let merged = PoolMix.mergeLegacyPoolTaskIds(
            ["a", "b"], selectedTaskIds: ["a"], tasksById: tasksById
        )
        XCTAssertEqual(merged, ["a"])
    }

    func testMergeLegacyPoolTaskIds_AppendsAdditionsAfterPreservedOrder() {
        let a = buildTask("a")
        let gone = buildTask("gone", isDeleted: true)
        let added = buildTask("added")
        let tasksById = byId([a, gone, added], id: { $0.id })
        let merged = PoolMix.mergeLegacyPoolTaskIds(
            ["a", "gone"], selectedTaskIds: ["a", "added"], tasksById: tasksById
        )
        XCTAssertEqual(merged, ["a", "gone", "added"])
    }

    func testMergeLegacyPoolTaskIds_PreservesRefMissingFromLibrary() {
        let a = buildTask("a")
        let tasksById = byId([a], id: { $0.id })
        let merged = PoolMix.mergeLegacyPoolTaskIds(
            ["a", "orphan"], selectedTaskIds: ["a"], tasksById: tasksById
        )
        XCTAssertEqual(merged, ["a", "orphan"])
    }

    // MARK: - resolvePoolPullAdditions / resolvePoolUntoggleRemovals (P3 wizard actions)
    //
    // Both operate on the SAME worked-example-shaped fixtures as resolveMix
    // above, but drive the wizard's flat `selectedTaskIds` mutation directly
    // (rather than recomputing the whole mix) — see
    // docs/POOLS_RECURRING.md §Surfaces item 5 (Wizard step 2) + §Data model
    // "Union rule". Line-for-line mirror of poolMix.test.ts's
    // `resolvePoolPullAdditions` / `resolvePoolUntoggleRemovals` describe blocks.

    func testResolvePoolPullAdditions_FreshPool_ReturnsFullResolvableSupply() {
        let (poolsById, tasksById) = pullAdditionsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("A", removedTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            ["x", "y"]
        )
    }

    func testResolvePoolPullAdditions_RemovedTaskStaysSuppressedAcrossAPull() {
        let (poolsById, tasksById) = pullAdditionsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("A", removedTaskIds: ["y"], poolsById: poolsById, tasksById: tasksById),
            ["x"]
        )
    }

    func testResolvePoolPullAdditions_RepullAfterRemovalCleared_ReturnsFullSupplyAgain() {
        let (poolsById, tasksById) = pullAdditionsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("A", removedTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            ["x", "y"]
        )
    }

    func testResolvePoolPullAdditions_SoftDeletedTaskInPool_ExcludedFromAdditions() {
        let (poolsById, _) = pullAdditionsFixtures()
        let tasksWithDeleted = byId([buildTask("x"), buildTask("y", isDeleted: true)], id: { $0.id })
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("A", removedTaskIds: [], poolsById: poolsById, tasksById: tasksWithDeleted),
            ["x"]
        )
    }

    func testResolvePoolPullAdditions_MissingOrSoftDeletedPool_ContributesNoAdditionsNotAnError() {
        let (poolsById, tasksById) = pullAdditionsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("ghost", removedTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            []
        )
        var deletedPoolsById = poolsById
        deletedPoolsById["A"]?.isDeleted = true
        XCTAssertEqual(
            PoolMix.resolvePoolPullAdditions("A", removedTaskIds: [], poolsById: deletedPoolsById, tasksById: tasksById),
            []
        )
    }

    private func pullAdditionsFixtures() -> (poolsById: [String: Pool], tasksById: [String: Task]) {
        let x = buildTask("x")
        let y = buildTask("y")
        let z = buildTask("z")
        let poolA = buildPool("A", ["x", "y"])
        let poolB = buildPool("B", ["y", "z"])
        return (byId([poolA, poolB]) { $0.id }, byId([x, y, z]) { $0.id })
    }

    func testResolvePoolUntoggleRemovals_OnlyPulledPool_RemovesWholeNonManualSupply() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("A", remainingPoolIds: [], manualTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            ["x", "y"]
        )
    }

    func testResolvePoolUntoggleRemovals_ManualWins_ManuallyAddedTaskNeverInRemovalSet() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("A", remainingPoolIds: [], manualTaskIds: ["x"], poolsById: poolsById, tasksById: tasksById),
            ["y"]
        )
    }

    func testResolvePoolUntoggleRemovals_TaskStillSuppliedByRemainingPool_NotRemoved() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        // Untoggling A while B stays pulled: y is also supplied by B → keep it.
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("A", remainingPoolIds: ["B"], manualTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            ["x"]
        )
    }

    func testResolvePoolUntoggleRemovals_UntoggleBWithARemaining_RemovesOnlyZ() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        // y stays (A still supplies it).
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("B", remainingPoolIds: ["A"], manualTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            ["z"]
        )
    }

    func testResolvePoolUntoggleRemovals_RemainingSupplyCheckedStructurally_EvenIfTaskSoftDeleted() {
        let (poolsById, _) = untoggleRemovalsFixtures()
        // y is soft-deleted (unresolvable) but B's RAW taskIds still list it, so
        // it still counts as "remaining supply" and is not removed by A's untoggle.
        let deletedY = byId([buildTask("x"), buildTask("y", isDeleted: true), buildTask("z"), buildTask("w")], id: { $0.id })
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("A", remainingPoolIds: ["B"], manualTaskIds: [], poolsById: poolsById, tasksById: deletedY),
            ["x"]
        )
    }

    func testResolvePoolUntoggleRemovals_SoftDeletedRemainingPool_ContributesNoSupply() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        var poolsWithDeletedB = poolsById
        poolsWithDeletedB["B"]?.isDeleted = true
        // B is soft-deleted, so its previously-shared task (y) is now removed too.
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("A", remainingPoolIds: ["B"], manualTaskIds: [], poolsById: poolsWithDeletedB, tasksById: tasksById),
            ["x", "y"]
        )
    }

    func testResolvePoolUntoggleRemovals_MissingOrSoftDeletedTargetPool_ContributesNoRemovalsNotAnError() {
        let (poolsById, tasksById) = untoggleRemovalsFixtures()
        XCTAssertEqual(
            PoolMix.resolvePoolUntoggleRemovals("ghost", remainingPoolIds: ["A"], manualTaskIds: [], poolsById: poolsById, tasksById: tasksById),
            []
        )
    }

    private func untoggleRemovalsFixtures() -> (poolsById: [String: Pool], tasksById: [String: Task]) {
        let x = buildTask("x")
        let y = buildTask("y")
        let z = buildTask("z")
        let w = buildTask("w")
        let poolA = buildPool("A", ["x", "y"])
        let poolB = buildPool("B", ["y", "z"])
        return (byId([poolA, poolB]) { $0.id }, byId([x, y, z, w]) { $0.id })
    }

    // MARK: - summarizeSpawnProvenance / formatSpawnProvenanceNote (P6)

    func testSummarizeSpawnProvenance_PurePool_AllDealtAreFromThePool() {
        let poolTaskIds = (0..<10).map { "p\($0)" }
        let pool = buildPool("pool-1", poolTaskIds)
        let tasks = poolTaskIds.map { buildTask($0) }
        let source = PoolMixInput(poolIds: ["pool-1"], manualTaskIds: [], removedTaskIds: [])
        let poolsById = byId([pool]) { $0.id }
        let tasksById = byId(tasks) { $0.id }

        // Loose-fit overfill: the mix has 10 resolvable tasks but only 8
        // cells were actually dealt.
        let dealt = Array(poolTaskIds.prefix(8))
        let summary = PoolMix.summarizeSpawnProvenance(
            spawnSource: source, poolsById: poolsById, tasksById: tasksById, dealtTaskIds: dealt
        )
        XCTAssertEqual(summary.dealt, 8)
        XCTAssertEqual(summary.mixSize, 10)
        XCTAssertEqual(summary.poolSourcedCount, 8)
        XCTAssertEqual(summary.manualSourcedCount, 0)
        XCTAssertEqual(PoolMix.formatSpawnProvenanceNote(summary), "Dealt 8 of 10 — 8 from the pool")
    }

    func testSummarizeSpawnProvenance_PureManual_AllDealtAreAddedToday() {
        // "Repeat this board…" shape: zero pools, everything manual.
        let manualIds = (0..<5).map { "m\($0)" }
        let tasks = manualIds.map { buildTask($0) }
        let source = PoolMixInput(poolIds: [], manualTaskIds: manualIds, removedTaskIds: [])
        let tasksById = byId(tasks) { $0.id }

        let summary = PoolMix.summarizeSpawnProvenance(
            spawnSource: source, poolsById: [:], tasksById: tasksById, dealtTaskIds: manualIds
        )
        XCTAssertEqual(summary.dealt, 5)
        XCTAssertEqual(summary.mixSize, 5)
        XCTAssertEqual(summary.poolSourcedCount, 0)
        XCTAssertEqual(summary.manualSourcedCount, 5)
        XCTAssertEqual(PoolMix.formatSpawnProvenanceNote(summary), "Dealt 5 of 5 — 5 added today")
    }

    func testSummarizeSpawnProvenance_Mixed_CountsSplitAccurately() {
        let poolTaskIds = (0..<6).map { "p\($0)" }
        let manualIds = ["m0", "m1"]
        let pool = buildPool("pool-1", poolTaskIds)
        let tasks = (poolTaskIds + manualIds).map { buildTask($0) }
        let source = PoolMixInput(poolIds: ["pool-1"], manualTaskIds: manualIds, removedTaskIds: [])
        let poolsById = byId([pool]) { $0.id }
        let tasksById = byId(tasks) { $0.id }

        // mix = 6 pool + 2 manual = 8. Dealt: 5 pool-sourced + both manual = 7.
        let dealt = Array(poolTaskIds.prefix(5)) + manualIds
        let summary = PoolMix.summarizeSpawnProvenance(
            spawnSource: source, poolsById: poolsById, tasksById: tasksById, dealtTaskIds: dealt
        )
        XCTAssertEqual(summary.dealt, 7)
        XCTAssertEqual(summary.mixSize, 8)
        XCTAssertEqual(summary.poolSourcedCount, 5)
        XCTAssertEqual(summary.manualSourcedCount, 2)
        XCTAssertEqual(PoolMix.formatSpawnProvenanceNote(summary), "Dealt 7 of 8 — 5 from the pool, 2 added today")
    }
}
