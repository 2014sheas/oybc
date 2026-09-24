import XCTest
@testable import OYBC

/// PoolHealthTests — Task Pools + Recurring Boards Rework (P2).
///
/// Line-for-line mirror of `packages/shared/tests/algorithms/poolHealth
/// .test.ts`. Any divergence here would mean iOS and web disagree on
/// which repeating boards are short on a pool, or render different
/// warning copy for the same short-by amount.
///
/// 2026-09 audit T2: `computePoolHealth` takes each template's
/// PRE-RESOLVED achievable size and decides consumption from `sources`,
/// never the `poolIds` mirror. The end-to-end "old wrong answer" cases
/// (pool + board source; a capped pool source) run against a real database
/// in `PoolHealthBatchTests`.
final class PoolHealthTests: XCTestCase {

    // MARK: - Fixtures

    private static let ts = "2026-07-19T00:00:00.000Z"

    private func buildTask(_ id: String, isDeleted: Bool = false) -> Task {
        Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func buildPool(_ id: String, _ taskIds: [String]) -> Pool {
        Pool(
            id: id, userId: "u1", name: "Pool \(id)", taskIds: taskIds,
            createdAt: Self.ts, updatedAt: Self.ts, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
    }

    private func buildTemplate(
        _ id: String,
        name: String = "Template",
        timeframe: Timeframe = .weekly,
        boardSize: Int = 3,
        centerSquareType: CenterSquareType = .free,
        poolIds: [String] = [],
        sources: [BoardSource]? = nil,
        isActive: Bool = true,
        isDeleted: Bool = false
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id, userId: "u1", name: name.isEmpty ? "Template \(id)" : name,
            timeframe: timeframe, boardSize: boardSize, centerSquareType: centerSquareType,
            isRandomized: false, seedTaskIds: [],
            poolIds: poolIds, manualTaskIds: [], removedTaskIds: [],
            sources: sources,
            lastSpawnedWindowKey: nil, isActive: isActive,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func byId<T>(_ items: [T], id: (T) -> String) -> [String: T] {
        Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
    }

    private func poolSource(_ id: String, max: Int? = nil) -> BoardSource {
        BoardSource(sourceId: id, kind: .pool, max: max)
    }

    private func boardSource(_ id: String) -> BoardSource {
        BoardSource(sourceId: id, kind: .board)
    }

    private func supply(_ template: RecurringBoardTemplate, _ size: Int) -> PoolHealth.TemplateSupply {
        PoolHealth.TemplateSupply(template: template, achievableSize: size)
    }

    // MARK: - computePoolHealth: taskCount

    func testTaskCount_CountsResolvableNonDeleted_SkipsDeletedAndMissing() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2", isDeleted: true)
        let pool = buildPool("p1", ["t1", "t2", "t3"]) // t3 missing from tasksById

        let result = PoolHealth.computePoolHealth(
            pool, templates: [], tasksById: byId([t1, t2], id: { $0.id })
        )

        XCTAssertEqual(result.taskCount, 1)
        XCTAssertEqual(result.consumers, [])
    }

    // MARK: - templateConsumesPool

    func testConsumesPool_PoolSourceNamingThePool() {
        let template = buildTemplate("tpl", sources: [poolSource("p1")])
        XCTAssertTrue(PoolHealth.templateConsumesPool(template, poolId: "p1"))
    }

    func testConsumesPool_StalePoolIdsMirror_IsNotAConsumer() {
        // The old predicate read `poolIds.contains(pool.id)` and said yes.
        let template = buildTemplate("tpl", poolIds: ["p1"], sources: [poolSource("p2")])
        XCTAssertFalse(PoolHealth.templateConsumesPool(template, poolId: "p1"))
    }

    func testConsumesPool_BoardSourceWithSameId_IsNotAPoolConsumer() {
        let template = buildTemplate("tpl", sources: [boardSource("p1")])
        XCTAssertFalse(PoolHealth.templateConsumesPool(template, poolId: "p1"))
    }

    func testConsumesPool_UnmigratedV1Record_UsesPoolIdsViaDecodeMapping() {
        let template = buildTemplate("tpl", poolIds: ["p1"])
        XCTAssertNil(template.sources)
        XCTAssertTrue(PoolHealth.templateConsumesPool(template, poolId: "p1"))
        XCTAssertFalse(PoolHealth.templateConsumesPool(template, poolId: "p2"))
    }

    // MARK: - computePoolHealth: consumer detection

    private func consumerDetectionFixtures() -> (pool: Pool, tasksById: [String: Task]) {
        (buildPool("p1", ["t1", "t2"]), byId([buildTask("t1"), buildTask("t2")], id: { $0.id }))
    }

    func testConsumerDetection_IncludesActiveTemplateShortOnAchievableSize() {
        let (pool, tasksById) = consumerDetectionFixtures()
        // 3x3 FREE floor is 8; achievable 2 -> shortBy 6.
        let template = buildTemplate("tpl1", name: "Template tpl1", sources: [poolSource("p1")])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [supply(template, 2)], tasksById: tasksById
        )

        XCTAssertEqual(result.consumers, [
            PoolHealth.Consumer(
                templateId: "tpl1", templateName: "Template tpl1",
                timeframe: .weekly, boardSize: 3, shortBy: 6
            ),
        ])
    }

    func testConsumerDetection_SkipsSoftDeletedTemplate() {
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", sources: [poolSource("p1")], isDeleted: true)
        let result = PoolHealth.computePoolHealth(pool, templates: [supply(template, 2)], tasksById: tasksById)
        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_SkipsPausedTemplate() {
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", sources: [poolSource("p1")], isActive: false)
        let result = PoolHealth.computePoolHealth(pool, templates: [supply(template, 2)], tasksById: tasksById)
        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_SkipsShortTemplateNotPullingThisPool() {
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", sources: [poolSource("other-pool")])
        let result = PoolHealth.computePoolHealth(pool, templates: [supply(template, 2)], tasksById: tasksById)
        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_SkipsShortTemplateLinkedOnlyByStalePoolIdsMirror() {
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", poolIds: ["p1"], sources: [boardSource("b1")])
        let result = PoolHealth.computePoolHealth(pool, templates: [supply(template, 2)], tasksById: tasksById)
        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_JudgesAchievableSize_NotThisPoolAlone() {
        // The pool supplies 2, but the template's achievable size (pool +
        // board) is 8 = the 3x3 FREE floor -> not short.
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", sources: [poolSource("p1"), boardSource("b1")])
        let result = PoolHealth.computePoolHealth(pool, templates: [supply(template, 8)], tasksById: tasksById)
        XCTAssertEqual(result.consumers, [])
    }

    // MARK: - computePoolHealth: shortBy math across sizes/centers

    private func shortBy(
        boardSize: Int, center: CenterSquareType, achievable: Int
    ) -> [PoolHealth.Consumer] {
        let (pool, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate(
            "tpl1", boardSize: boardSize, centerSquareType: center, sources: [poolSource("p1")]
        )
        return PoolHealth.computePoolHealth(
            pool, templates: [supply(template, achievable)], tasksById: tasksById
        ).consumers
    }

    func testShortBy_3x3FreeCenter_Floor8_Achievable2_ShortBy6() {
        XCTAssertEqual(shortBy(boardSize: 3, center: .free, achievable: 2).first?.shortBy, 6)
    }

    func testShortBy_3x3NoneCenter_Floor9_Achievable2_ShortBy7() {
        XCTAssertEqual(shortBy(boardSize: 3, center: .none, achievable: 2).first?.shortBy, 7)
    }

    func testShortBy_4x4_Floor16_Achievable2_ShortBy14_ThreadsBoardSize() {
        let consumers = shortBy(boardSize: 4, center: .free, achievable: 2)
        XCTAssertEqual(consumers.first?.shortBy, 14)
        XCTAssertEqual(consumers.first?.boardSize, 4)
    }

    func testShortBy_AchievableAtFloor_NotAConsumer() {
        XCTAssertEqual(shortBy(boardSize: 3, center: .free, achievable: 8), [])
    }

    func testShortBy_AchievableOneBelowFloor_ShortByOne() {
        XCTAssertEqual(shortBy(boardSize: 3, center: .free, achievable: 7).first?.shortBy, 1)
    }

    // MARK: - computePoolHealth: multiple consumers

    func testMultipleConsumers_ReturnsOneEntryPerShortTemplate_InInputOrder() {
        let pool = buildPool("p1", ["t1"])
        let tplA = buildTemplate(
            "tplA", name: "Morning Kickstart", timeframe: .daily,
            boardSize: 3, centerSquareType: .free, sources: [poolSource("p1")]
        )
        let tplB = buildTemplate(
            "tplB", name: "Weekly Reset", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, sources: [poolSource("p1")]
        )

        let result = PoolHealth.computePoolHealth(
            pool,
            templates: [supply(tplA, 1), supply(tplB, 1)],
            tasksById: byId([buildTask("t1")], id: { $0.id })
        )

        XCTAssertEqual(result.consumers, [
            PoolHealth.Consumer(
                templateId: "tplA", templateName: "Morning Kickstart",
                timeframe: .daily, boardSize: 3, shortBy: 7
            ),
            PoolHealth.Consumer(
                templateId: "tplB", templateName: "Weekly Reset",
                timeframe: .weekly, boardSize: 3, shortBy: 8
            ),
        ])
    }

    // MARK: - computePoolHealthByPoolId (batch)

    func testBatch_OneResultPerPool_NoCrossTalk() {
        let tasks = (0..<8).map { buildTask("t\($0)") }
        let tasksById = byId(tasks, id: { $0.id })
        let poolA = buildPool("pA", tasks.map { $0.id })
        let poolB = buildPool("pB", ["t0"])
        let tplA = buildTemplate("tplA", name: "Feeds A", sources: [poolSource("pA")])
        let tplB = buildTemplate("tplB", name: "Feeds B", sources: [poolSource("pB")])

        let result = PoolHealth.computePoolHealthByPoolId(
            pools: [poolA, poolB],
            templates: [tplA, tplB],
            achievableTaskIdsByTemplateId: ["tplA": tasks.map { $0.id }, "tplB": ["t0"]],
            tasksById: tasksById
        )

        XCTAssertEqual(Set(result.keys), ["pA", "pB"])
        XCTAssertEqual(result["pA"]?.consumers, [])
        XCTAssertEqual(result["pB"]?.consumers, [
            PoolHealth.Consumer(
                templateId: "tplB", templateName: "Feeds B",
                timeframe: .weekly, boardSize: 3, shortBy: 7
            ),
        ])
    }

    func testBatch_NilAchievableMap_FlagsNothingWhileLoading() {
        let pool = buildPool("pA", ["t0"])
        let tpl = buildTemplate("tpl", sources: [poolSource("pA")])
        let result = PoolHealth.computePoolHealthByPoolId(
            pools: [pool], templates: [tpl], achievableTaskIdsByTemplateId: nil,
            tasksById: byId([buildTask("t0")], id: { $0.id })
        )
        XCTAssertEqual(result["pA"], PoolHealth.Result(taskCount: 1, consumers: []))
    }

    // MARK: - formatPoolShortSummary

    func testFormatSummary_EmptyConsumers_ReturnsEmptyString() {
        XCTAssertEqual(PoolHealth.formatPoolShortSummary([]), "")
    }

    func testFormatSummary_OneConsumer_ReturnsSingularBoard() {
        let consumer = PoolHealth.Consumer(
            templateId: "tpl1", templateName: "Template tpl1",
            timeframe: .weekly, boardSize: 3, shortBy: 6
        )
        XCTAssertEqual(PoolHealth.formatPoolShortSummary([consumer]), "Short on 1 board")
    }

    func testFormatSummary_MultipleConsumers_ReturnsPluralBoardCount() {
        let consumerA = PoolHealth.Consumer(
            templateId: "tplA", templateName: "Morning Kickstart",
            timeframe: .daily, boardSize: 3, shortBy: 7
        )
        let consumerB = PoolHealth.Consumer(
            templateId: "tplB", templateName: "Weekly Reset",
            timeframe: .weekly, boardSize: 3, shortBy: 8
        )
        let consumerC = PoolHealth.Consumer(
            templateId: "tplC", templateName: "Monthly Refresh",
            timeframe: .monthly, boardSize: 4, shortBy: 14
        )
        XCTAssertEqual(PoolHealth.formatPoolShortSummary([consumerA, consumerB]), "Short on 2 boards")
        XCTAssertEqual(
            PoolHealth.formatPoolShortSummary([consumerA, consumerB, consumerC]), "Short on 3 boards"
        )
    }
}
