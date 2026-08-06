import XCTest
@testable import OYBC

/// `RecurringBoardTemplatesViewModel.computeTemplateMixes` — the batched,
/// per-template mix resolver. iOS twin of web's `computeTemplateMixes`
/// (`hooks/useTemplateMixes.ts`); see
/// `apps/web/src/hooks/__tests__/useTemplateMixes.test.ts` for the mirror.
///
/// Review finding M2 (P1 final fix wave, docs/POOLS_RECURRING.md): the
/// `poolIds`-absent-OR-empty fallback to `seedTaskIds` was too loose — an
/// empty-but-PRESENT `poolIds: []` also covers the defensive "flattened"
/// write-through shape (`manualTaskIds` populated, `poolIds: []`), and
/// falling back to stale `seedTaskIds` there is a destructive-edit bug
/// (re-editing resurrects stale seeds instead of the flatten's actual
/// selection). The fix: fall back ONLY when `poolIds == nil`; `poolIds: []`
/// resolves through `PoolMix.resolveMix` like any other shape.
final class RecurringBoardTemplatesMixTests: XCTestCase {

    private func makeTemplate(
        id: String = "tpl-1",
        seedTaskIds: [String] = ["stale-1", "stale-2"],
        poolIds: [String]? = ["pool-1"],
        manualTaskIds: [String]? = [],
        removedTaskIds: [String]? = []
    ) -> RecurringBoardTemplate {
        let now = "2026-07-19T00:00:00.000Z"
        return RecurringBoardTemplate(
            id: id,
            userId: "u1",
            name: "Daily Workout",
            timeframe: .daily,
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: true,
            seedTaskIds: seedTaskIds,
            poolIds: poolIds,
            manualTaskIds: manualTaskIds,
            removedTaskIds: removedTaskIds,
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    private func makeTask(_ id: String) -> Task {
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
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func makePool(_ id: String, _ taskIds: [String]) -> Pool {
        let now = "2026-07-19T00:00:00.000Z"
        return Pool(
            id: id, userId: "u1", name: id, taskIds: taskIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    func testResolvesAMigratedTemplateThroughPoolsAndTasks_IgnoringSeedTaskIds() {
        let tpl = makeTemplate(poolIds: ["pool-1"])
        let poolsById = ["pool-1": makePool("pool-1", ["a1", "a2", "a3"])]
        let tasksById = [
            "a1": makeTask("a1"), "a2": makeTask("a2"), "a3": makeTask("a3"),
        ]

        let result = RecurringBoardTemplatesViewModel.computeTemplateMixes(
            templates: [tpl], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result[tpl.id], ["a1", "a2", "a3"])
    }

    func testFallsBackToSeedTaskIds_WhenPoolIdsIsNil_GenuinelyUnmigrated() {
        let tpl = makeTemplate(poolIds: nil, manualTaskIds: nil, removedTaskIds: nil)

        let result = RecurringBoardTemplatesViewModel.computeTemplateMixes(
            templates: [tpl], poolsById: [:], tasksById: [:]
        )

        XCTAssertEqual(result[tpl.id], tpl.seedTaskIds)
    }

    func testResolvesViaEmptyMix_WhenPoolIdsIsEmptyArrayWithNoManualAdditions() {
        // The "no pool yet" edge — must NOT fall back to seedTaskIds.
        let tpl = makeTemplate(
            seedTaskIds: ["stale-should-never-appear"],
            poolIds: [], manualTaskIds: [], removedTaskIds: []
        )

        let result = RecurringBoardTemplatesViewModel.computeTemplateMixes(
            templates: [tpl], poolsById: [:], tasksById: [:]
        )

        XCTAssertEqual(result[tpl.id], [])
        XCTAssertNotEqual(result[tpl.id], tpl.seedTaskIds)
    }

    func testResolvesViaManualLayer_WhenPoolIdsIsEmptyArrayButManualTaskIdsPopulated() {
        // The "flattened" defensive write-through shape. Falling back to
        // seedTaskIds here would silently drop the manual selection —
        // exactly the destructive-edit bug M2 fixes.
        let tpl = makeTemplate(
            seedTaskIds: ["stale-should-never-appear"],
            poolIds: [], manualTaskIds: ["m1", "m2"], removedTaskIds: []
        )

        let result = RecurringBoardTemplatesViewModel.computeTemplateMixes(
            templates: [tpl], poolsById: [:], tasksById: [:]
        )

        XCTAssertEqual(result[tpl.id], ["m1", "m2"])
    }

    func testBatchesMultipleTemplatesIndependently() {
        let t1 = makeTemplate(id: "tmpl-1", seedTaskIds: ["x"], poolIds: ["pool-1"])
        let t2 = makeTemplate(id: "tmpl-2", seedTaskIds: ["y"], poolIds: ["pool-2"])
        let poolsById = [
            "pool-1": makePool("pool-1", ["a1"]),
            "pool-2": makePool("pool-2", ["a2"]),
        ]
        let tasksById = ["a1": makeTask("a1"), "a2": makeTask("a2")]

        let result = RecurringBoardTemplatesViewModel.computeTemplateMixes(
            templates: [t1, t2], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result["tmpl-1"], ["a1"])
        XCTAssertEqual(result["tmpl-2"], ["a2"])
    }
}
