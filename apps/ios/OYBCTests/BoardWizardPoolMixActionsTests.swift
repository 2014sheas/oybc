import XCTest
@testable import OYBC

/// BoardWizardPoolMixActionsTests — Task Pools + Recurring Boards Rework
/// (P3). Covers `BoardWizardViewModel.pullPool` / `untogglePool` /
/// `toggleTaskSelection`'s new manual/removed bookkeeping, and
/// `provenanceByTaskId`. Uses the SAME worked-example fixtures (pools
/// A{x,y}, B{y,z}) as `PoolMixTests`/`poolMix.test.ts` so the vectors
/// visibly match across layers and platforms — see docs/POOLS_RECURRING.md
/// §Changed: the spawn record for the canonical worked example.
final class BoardWizardPoolMixActionsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: .defaults, database: try! AppDatabase.makeTestInstance())
    }

    private func makeTask(id: String, isDeleted: Bool = false) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func makePool(id: String, name: String? = nil, _ taskIds: [String], isDeleted: Bool = false) -> Pool {
        Pool(
            id: id, userId: "u1", name: name ?? "Pool \(id)", taskIds: taskIds,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    /// The canonical worked-example fixtures: pools A{x,y}, B{y,z}.
    private func workedExampleFixtures() -> (poolsById: [String: Pool], tasksById: [String: OYBC.Task]) {
        let poolA = makePool(id: "A", ["x", "y"])
        let poolB = makePool(id: "B", ["y", "z"])
        let tasksById = Dictionary(
            uniqueKeysWithValues: ["x", "y", "z", "w"].map { ($0, makeTask(id: $0)) }
        )
        let poolsById = Dictionary(uniqueKeysWithValues: [poolA, poolB].map { ($0.id, $0) })
        return (poolsById, tasksById)
    }

    // MARK: - pullPool

    func test_pullPool_unionsResolvableSupplyIntoSelection() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x", "y"])
        XCTAssertEqual(vm.poolOrder, ["x", "y"])
        XCTAssertEqual(vm.pulledPoolIds, ["A"])
        // Pool-sourced additions are NOT manual.
        XCTAssertTrue(vm.manualTaskIds.isEmpty)
    }

    func test_pullPool_secondPoolUnionsAcrossOverlap() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.pullPool("B", poolsById: poolsById, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x", "y", "z"])
        XCTAssertEqual(vm.poolOrder, ["x", "y", "z"])
        XCTAssertEqual(vm.pulledPoolIds, ["A", "B"])
    }

    func test_pullPool_respectsExistingRemovals_removedTaskStaysSuppressed() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.removedTaskIds = ["y"]
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x"])
        XCTAssertEqual(vm.poolOrder, ["x"])
    }

    func test_pullPool_missingPool_noOp() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("ghost", poolsById: poolsById, tasksById: tasksById)

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
    }

    func test_pullPool_softDeletedPool_noOp() {
        let vm = makeVM()
        var (poolsById, tasksById) = workedExampleFixtures()
        poolsById["A"]?.isDeleted = true
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
    }

    func test_pullPool_alreadyPulled_noOp_doesNotDuplicateInPulledPoolIds() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertEqual(vm.pulledPoolIds, ["A"])
    }

    // MARK: - untogglePool

    func test_untogglePool_onlyPulledPool_removesWholeSupply() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.untogglePool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertTrue(vm.selectedTaskIds.isEmpty)
        XCTAssertTrue(vm.poolOrder.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)
    }

    func test_untogglePool_taskStillSuppliedByRemainingPool_isKept() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.pullPool("B", poolsById: poolsById, tasksById: tasksById)
        vm.untogglePool("A", poolsById: poolsById, tasksById: tasksById)

        // y is still supplied by B → kept. x is removed (only A supplied it).
        XCTAssertEqual(vm.selectedTaskIds, ["y", "z"])
        XCTAssertEqual(vm.pulledPoolIds, ["B"])
    }

    func test_untogglePool_manualTaskNeverRemoved() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        // Hand-add x too (already pool-sourced, but simulate the user having
        // also explicitly selected it before the pull — manual wins).
        vm.manualTaskIds.insert("x")
        vm.untogglePool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertEqual(vm.selectedTaskIds, ["x"])
    }

    func test_untogglePool_clearsCenterMarkPendingAndStagedEditsForRemovedRows() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.centerTaskId = "x"
        vm.stagedEdits["x"] = TaskEditPatch(title: "Renamed")

        vm.untogglePool("A", poolsById: poolsById, tasksById: tasksById)

        XCTAssertNil(vm.centerTaskId)
        XCTAssertNil(vm.stagedEdits["x"])
    }

    /// The doc's worked example, driven end-to-end through the VM actions
    /// rather than the raw `PoolMix` functions: pull A+B, mark w manual and
    /// y removed (simulating a prior manual removal), untoggle B → y's
    /// removal persists (still supplied by A); untoggle A too → y's
    /// removal clears (no longer supplied anywhere); re-pull A → y returns.
    func test_workedExample_pullBothRemoveY_untoggleBThenA_repullA() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.pullPool("B", poolsById: poolsById, tasksById: tasksById)
        vm.manualTaskIds.insert("w")
        // Simulate removing y by hand (still supplied by A and B).
        vm.toggleTaskSelection("y", poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(vm.removedTaskIds, ["y"])
        XCTAssertEqual(vm.selectedTaskIds, ["x", "z"])

        vm.untogglePool("B", poolsById: poolsById, tasksById: tasksById)
        // y still supplied by A → removal persists.
        XCTAssertEqual(vm.removedTaskIds, ["y"])
        XCTAssertEqual(vm.pulledPoolIds, ["A"])

        vm.untogglePool("A", poolsById: poolsById, tasksById: tasksById)
        // y no longer supplied by anyone → removal clears.
        XCTAssertTrue(vm.removedTaskIds.isEmpty)
        XCTAssertTrue(vm.pulledPoolIds.isEmpty)

        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        // Removal was cleared, not remembered — y is back.
        XCTAssertTrue(vm.selectedTaskIds.contains("y"))
    }

    // MARK: - toggleTaskSelection manual/removed bookkeeping

    func test_toggleTaskSelection_select_marksManual() {
        let vm = makeVM()
        vm.toggleTaskSelection("m")
        XCTAssertTrue(vm.manualTaskIds.contains("m"))
    }

    func test_toggleTaskSelection_deselect_clearsManualMark() {
        let vm = makeVM()
        vm.toggleTaskSelection("m")
        vm.toggleTaskSelection("m") // remove
        XCTAssertFalse(vm.manualTaskIds.contains("m"))
    }

    func test_toggleTaskSelection_deselectPoolSuppliedTask_recordsRemoval() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        vm.toggleTaskSelection("x", poolsById: poolsById, tasksById: tasksById) // remove
        XCTAssertTrue(vm.removedTaskIds.contains("x"))
        XCTAssertFalse(vm.selectedTaskIds.contains("x"))
    }

    func test_toggleTaskSelection_deselectManualOnlyTask_noRemovalRecorded() {
        let vm = makeVM()
        vm.toggleTaskSelection("m") // select, manual
        vm.toggleTaskSelection("m", poolsById: [:], tasksById: [:]) // remove
        XCTAssertFalse(vm.removedTaskIds.contains("m"))
    }

    func test_toggleTaskSelection_deselectWithoutPoolLookups_defaultsToNoRemoval() {
        // Existing call sites (onTaskCreated/onCompoundCreated) don't pass
        // poolsById/tasksById — a freshly-created task can't already be
        // pool-sourced, so the default-empty lookups correctly no-op.
        let vm = makeVM()
        vm.toggleTaskSelection("fresh")
        vm.toggleTaskSelection("fresh")
        XCTAssertTrue(vm.removedTaskIds.isEmpty)
    }

    func test_toggleTaskSelection_reselectAfterRemoval_clearsRemovalMark() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.toggleTaskSelection("x", poolsById: poolsById, tasksById: tasksById) // remove
        XCTAssertTrue(vm.removedTaskIds.contains("x"))

        vm.toggleTaskSelection("x") // re-add by hand
        XCTAssertFalse(vm.removedTaskIds.contains("x"))
        XCTAssertTrue(vm.manualTaskIds.contains("x"))
    }

    // MARK: - provenanceByTaskId

    func test_provenanceByTaskId_manualTask_reportsAddedByHand() {
        let vm = makeVM()
        vm.toggleTaskSelection("m")
        let provenance = vm.provenanceByTaskId(poolsById: [:], tasksById: [:])
        XCTAssertEqual(provenance["m"], "added by hand")
    }

    func test_provenanceByTaskId_poolSourcedTask_reportsFromPoolName() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)

        let provenance = vm.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(provenance["x"], "from \(poolsById["A"]!.name)")
        XCTAssertEqual(provenance["y"], "from \(poolsById["A"]!.name)")
    }

    func test_provenanceByTaskId_manualWinsEvenIfAlsoPoolSourced() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.manualTaskIds.insert("x")

        let provenance = vm.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(provenance["x"], "added by hand")
    }

    func test_provenanceByTaskId_firstPulledPoolInPullOrderWins() {
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.pullPool("A", poolsById: poolsById, tasksById: tasksById)
        vm.pullPool("B", poolsById: poolsById, tasksById: tasksById)

        // y is supplied by both A and B, pulled in that order — A wins.
        let provenance = vm.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(provenance["y"], "from \(poolsById["A"]!.name)")
    }

    func test_provenanceByTaskId_defensiveFallback_notManualNotFoundInAnyPulledPool() {
        // Shouldn't normally happen (a selected id is either manual or
        // pool-sourced), but the fallback must still resolve to something
        // sane rather than a missing dictionary entry.
        let vm = makeVM()
        let (poolsById, tasksById) = workedExampleFixtures()
        vm.selectedTaskIds.insert("orphan")
        let provenance = vm.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(provenance["orphan"], "added by hand")
    }
}
