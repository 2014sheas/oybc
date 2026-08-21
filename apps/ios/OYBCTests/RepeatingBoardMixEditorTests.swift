import XCTest
@testable import OYBC

/// RepeatingBoardMixEditorTests — Task Pools + Recurring Boards Rework
/// (P7). Exercises the SAME worked example as `PoolMixTests`
/// (docs/POOLS_RECURRING.md §Changed: the spawn record) but through the
/// P7 Board-settings roster edit sheet's call path
/// (`RepeatingBoardMixEditor`, which mutates a `RecurringBoardTemplate`
/// directly) instead of the abstract `PoolMixSource` the base `PoolMix`
/// tests use. Confirms the roster editor's pool-toggle union rule
/// produces the same mixes the shared algorithm's own test vectors
/// require — no reimplementation, no drift.
final class RepeatingBoardMixEditorTests: XCTestCase {

    // MARK: - Fixtures

    private func buildTask(_ id: String, isDeleted: Bool = false) -> Task {
        Task(
            id: id, userId: "u1", title: "Task \(id)", type: .normal,
            totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-07-19T00:00:00.000Z", updatedAt: "2026-07-19T00:00:00.000Z",
            version: 1, isDeleted: isDeleted
        )
    }

    private func buildPool(_ id: String, _ taskIds: [String], isDeleted: Bool = false) -> Pool {
        Pool(
            id: id, userId: "u1", name: "Pool \(id)", taskIds: taskIds,
            createdAt: "2026-07-19T00:00:00.000Z", updatedAt: "2026-07-19T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func buildTemplate(
        poolIds: [String]? = nil,
        manualTaskIds: [String]? = nil,
        removedTaskIds: [String]? = nil
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: "tpl-1", userId: "u1", name: "Roster Test", timeframe: .weekly,
            boardSize: 3, centerSquareType: .free, isRandomized: false, seedTaskIds: [],
            poolIds: poolIds, manualTaskIds: manualTaskIds, removedTaskIds: removedTaskIds,
            isActive: true, createdAt: "2026-07-19T00:00:00.000Z", updatedAt: "2026-07-19T00:00:00.000Z"
        )
    }

    private func byId<T>(_ items: [T], id: (T) -> String) -> [String: T] {
        Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
    }

    private func workedExampleFixtures() -> (poolsById: [String: Pool], tasksById: [String: Task]) {
        let x = buildTask("x"); let y = buildTask("y"); let z = buildTask("z"); let w = buildTask("w")
        let poolA = buildPool("A", ["x", "y"])
        let poolB = buildPool("B", ["y", "z"])
        return (byId([poolA, poolB]) { $0.id }, byId([x, y, z, w]) { $0.id })
    }

    // MARK: - Worked example, via the roster editor's call path

    func testWorkedExample_Step1_ABPulled_RemovedY_ManualW_YieldsXZW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let template = buildTemplate(poolIds: ["A", "B"], manualTaskIds: ["w"], removedTaskIds: ["y"])

        let mix = PoolMix.resolveMix(template, poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(mix.taskIds, ["x", "z", "w"])
    }

    func testWorkedExample_Step2_UntogglePoolB_RemovalOfYPersists_YieldsXW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let template = buildTemplate(poolIds: ["A", "B"], manualTaskIds: ["w"], removedTaskIds: ["y"])

        let updated = RepeatingBoardMixEditor.untogglePool("B", from: template, poolsById: poolsById)
        XCTAssertEqual(updated.poolIds, ["A"])
        // y is still supplied by A — the removal persists.
        XCTAssertEqual(updated.removedTaskIds, ["y"])

        let mix = PoolMix.resolveMix(updated, poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(mix.taskIds, ["x", "w"])
    }

    func testWorkedExample_Step3_UntogglePoolATooToo_RemovalCleared_YieldsW() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let afterB = buildTemplate(poolIds: ["A"], manualTaskIds: ["w"], removedTaskIds: ["y"])

        let updated = RepeatingBoardMixEditor.untogglePool("A", from: afterB, poolsById: poolsById)
        XCTAssertEqual(updated.poolIds, [])
        // y is no longer supplied by ANY remaining pool — removal clears.
        XCTAssertEqual(updated.removedTaskIds, [])

        let mix = PoolMix.resolveMix(updated, poolsById: poolsById, tasksById: tasksById)
        XCTAssertEqual(mix.taskIds, ["w"])
    }

    func testWorkedExample_RePullPoolA_RemovalStaysCleared_YIsBackInMix() {
        let (poolsById, tasksById) = workedExampleFixtures()
        let emptyTemplate = buildTemplate(poolIds: [], manualTaskIds: ["w"], removedTaskIds: [])

        let updated = RepeatingBoardMixEditor.pullPool("A", into: emptyTemplate, poolsById: poolsById)
        XCTAssertEqual(updated.poolIds, ["A"])

        let mix = PoolMix.resolveMix(updated, poolsById: poolsById, tasksById: tasksById)
        // y's removal was CLEARED (not remembered) when A was untoggled in
        // step 3 above — re-pulling A brings y back.
        XCTAssertEqual(mix.taskIds, ["x", "y", "w"])
    }

    // MARK: - pullPool guards

    func testPullPool_AlreadyAttached_NoOp() {
        let template = buildTemplate(poolIds: ["A"])
        let updated = RepeatingBoardMixEditor.pullPool("A", into: template, poolsById: ["A": buildPool("A", ["x"])])
        // Pulling an already-attached pool doesn't duplicate the id.
        XCTAssertEqual(updated.poolIds, ["A"])
    }

    func testPullPool_DeletedPool_NoOp() {
        let deletedPool = buildPool("A", ["x"], isDeleted: true)
        let template = buildTemplate(poolIds: [])
        let updated = RepeatingBoardMixEditor.pullPool("A", into: template, poolsById: ["A": deletedPool])
        XCTAssertEqual(updated.poolIds ?? [], [])
    }

    // MARK: - removeTaskFromMix / addManualTask

    func testRemoveTaskFromMix_PoolSourcedTask_RecordsRemoval() {
        let pool = buildPool("A", ["x", "y"])
        let tasksById = byId([buildTask("x"), buildTask("y")]) { $0.id }
        let template = buildTemplate(poolIds: ["A"], manualTaskIds: [], removedTaskIds: [])

        let updated = RepeatingBoardMixEditor.removeTaskFromMix(
            "y", from: template, poolsById: ["A": pool], tasksById: tasksById
        )
        XCTAssertEqual(updated.removedTaskIds, ["y"])
        XCTAssertEqual(updated.manualTaskIds ?? [], [])

        let mix = PoolMix.resolveMix(updated, poolsById: ["A": pool], tasksById: tasksById)
        XCTAssertEqual(mix.taskIds, ["x"])
    }

    func testRemoveTaskFromMix_ManualTask_JustDropsFromManualNoRemovalBookkeeping() {
        let template = buildTemplate(poolIds: [], manualTaskIds: ["w"], removedTaskIds: [])
        let updated = RepeatingBoardMixEditor.removeTaskFromMix(
            "w", from: template, poolsById: [:], tasksById: [:]
        )
        XCTAssertEqual(updated.manualTaskIds, [])
        // Not supplied by any pool, so no removal bookkeeping needed.
        XCTAssertEqual(updated.removedTaskIds ?? [], [])
    }

    func testAddManualTask_ClearsStaleRemoval_ManualWinsPerFormula() {
        let template = buildTemplate(poolIds: [], manualTaskIds: [], removedTaskIds: ["y"])
        let updated = RepeatingBoardMixEditor.addManualTask("y", to: template)
        XCTAssertEqual(updated.manualTaskIds, ["y"])
        XCTAssertEqual(updated.removedTaskIds, [])
    }

    func testAddManualTask_AlreadyManual_NoDuplicate() {
        let template = buildTemplate(manualTaskIds: ["w"])
        let updated = RepeatingBoardMixEditor.addManualTask("w", to: template)
        XCTAssertEqual(updated.manualTaskIds, ["w"])
    }
}
