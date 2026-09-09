import XCTest
@testable import OYBC

/// `RecurringBoardTemplatesViewModel.computeRosterHealth` — the
/// sources-native roster mix + attention computation (loose-ends sweep
/// 2026-09-09; supersedes the legacy `computeTemplateMixes` +
/// `computeAttention` pair). Mirrors web's `computeRosterHealth` suite
/// (`templateHealth.test.ts`): board-source-only templates are HEALTHY
/// (the legacy path badged them with an empty mix), dead board sources
/// badge `.sourceBoardMissing` statically, and counts respect ranges +
/// the counter-family rule.
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
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
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

    private func poolSource(_ id: String, min: Int = 0, max: Int? = nil) -> BoardSource {
        BoardSource(sourceId: id, kind: .pool, min: min, max: max)
    }

    private func boardSource(_ id: String) -> BoardSource {
        BoardSource(sourceId: id, kind: .board)
    }

    private func resolution(
        supplies: [BoardSources.Supply] = [],
        deadBoardSourceIds: [String] = [],
        manualTaskIds: [String] = []
    ) -> RecurringBoardTemplatesViewModel.TemplateSupplyResolution {
        RecurringBoardTemplatesViewModel.TemplateSupplyResolution(
            supplies: supplies,
            deadBoardSourceIds: deadBoardSourceIds,
            manualTaskIds: manualTaskIds
        )
    }

    private let nine = (1...9).map { "s\($0)" }

    private func nineTasks() -> [String: Task] {
        Dictionary(uniqueKeysWithValues: nine.map { ($0, makeTask($0)) })
    }

    func testBoardSourceOnlyTemplate_IsHealthyWithSquaresCounted() {
        // THE legacy-path regression: resolveMix saw no poolIds → empty mix
        // → spurious badge + "0 tasks" for a board-source-only template.
        let tpl = makeTemplate(poolIds: nil, manualTaskIds: nil, removedTaskIds: nil)
        let res = resolution(
            supplies: [BoardSources.Supply(source: boardSource("b1"), supplyTaskIds: nine)]
        )
        let (mix, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: res],
            tasksById: nineTasks()
        )
        XCTAssertNil(attention[tpl.id])
        XCTAssertEqual(mix[tpl.id]?.count, 9)
    }

    func testDeadBoardSource_BadgesSourceBoardMissing() {
        let tpl = makeTemplate()
        let res = resolution(
            supplies: [
                BoardSources.Supply(source: boardSource("b-gone"), supplyTaskIds: []),
                BoardSources.Supply(source: poolSource("p1"), supplyTaskIds: nine),
            ],
            deadBoardSourceIds: ["b-gone"]
        )
        let (_, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: res],
            tasksById: nineTasks()
        )
        XCTAssertEqual(attention[tpl.id], .sourceBoardMissing)
    }

    func testDeletedManualTask_BadgesHasDeletedTasks_AndStaysOutOfTheCount() {
        let tpl = makeTemplate()
        let tasks = nineTasks()
        // "dead" is absent from tasksById entirely (deleted-and-purged).
        let res = resolution(manualTaskIds: nine + ["dead"])
        let (mix, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: res],
            tasksById: tasks
        )
        XCTAssertEqual(attention[tpl.id], .hasDeletedTasks)
        XCTAssertEqual(mix[tpl.id]?.count, 9)
        XCTAssertFalse(mix[tpl.id]?.contains("dead") ?? true)
    }

    func testNumericRange_MakesPoolTooSmallHonest() {
        // Raw union (9) ≥ the 3×3 FREE floor (8), but max: 4 caps the
        // achievable pick below it — the legacy size check missed this.
        let tpl = makeTemplate()
        let res = resolution(
            supplies: [BoardSources.Supply(source: poolSource("p1", max: 4), supplyTaskIds: nine)]
        )
        let (mix, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: res],
            tasksById: nineTasks()
        )
        XCTAssertEqual(mix[tpl.id]?.count, 4)
        XCTAssertEqual(attention[tpl.id], .poolTooSmall)
    }

    func testSharedCounterFamily_CountsOnceInTheRosterMix() {
        let tpl = makeTemplate()
        var tasks = nineTasks()
        tasks["r50"] = Task(
            id: "r50", userId: "u1", title: "Read 50", description: nil, type: .counting,
            action: "Read", unit: "pages", maxCount: 50,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-07-19T00:00:00.000Z", updatedAt: "2026-07-19T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        tasks["r20"] = Task(
            id: "r20", userId: "u1", title: "Read 20", description: nil, type: .counting,
            action: "Read", unit: "pages", maxCount: 20,
            operatorType: nil, threshold: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-07-19T00:00:00.000Z", updatedAt: "2026-07-19T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            sharedCounterId: "r50", baseline: 0
        )
        let res = resolution(manualTaskIds: ["r50", "r20"] + Array(nine.prefix(8)))
        let (mix, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: res],
            tasksById: tasks
        )
        let famPicks = (mix[tpl.id] ?? []).filter { $0 == "r50" || $0 == "r20" }
        XCTAssertEqual(famPicks.count, 1)
        XCTAssertEqual(mix[tpl.id]?.count, 9)
        XCTAssertNil(attention[tpl.id])
    }

    func testEmptyTemplate_BadgesNoPoolTasksResolved() {
        let tpl = makeTemplate()
        let (_, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [tpl.id: resolution()],
            tasksById: [:]
        )
        XCTAssertEqual(attention[tpl.id], .noPoolTasksResolved)
    }

    func testMissingResolutionEntry_FallsBackToSeedTaskIdsWithNoBadge() {
        let tpl = makeTemplate(seedTaskIds: nine)
        let (mix, attention) = RecurringBoardTemplatesViewModel.computeRosterHealth(
            templates: [tpl],
            resolutionByTemplateId: [:],
            tasksById: [:]
        )
        XCTAssertEqual(mix[tpl.id], nine)
        XCTAssertNil(attention[tpl.id])
    }
}
