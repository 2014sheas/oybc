import XCTest
@testable import OYBC

/// PoolHealthTests — Task Pools + Recurring Boards Rework (P2).
///
/// Line-for-line mirror of `packages/shared/tests/algorithms/poolHealth
/// .test.ts`. Any divergence here would mean iOS and web disagree on
/// which repeating boards are short on a pool, or render different
/// warning copy for the same short-by amount.
final class PoolHealthTests: XCTestCase {

    // MARK: - Fixtures

    private static let ts = "2026-07-19T00:00:00.000Z"

    private func buildTask(_ id: String, isDeleted: Bool = false) -> Task {
        Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
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
        isActive: Bool = true,
        isDeleted: Bool = false
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id, userId: "u1", name: name.isEmpty ? "Template \(id)" : name,
            timeframe: timeframe, boardSize: boardSize, centerSquareType: centerSquareType,
            isRandomized: false, seedTaskIds: [],
            poolIds: poolIds, manualTaskIds: [], removedTaskIds: [],
            lastSpawnedWindowKey: nil, isActive: isActive,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: isDeleted, deletedAt: nil
        )
    }

    private func byId<T>(_ items: [T], id: (T) -> String) -> [String: T] {
        Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
    }

    // MARK: - computePoolHealth: taskCount

    func testTaskCount_CountsResolvableNonDeleted_SkipsDeletedAndMissing() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2", isDeleted: true)
        let pool = buildPool("p1", ["t1", "t2", "t3"]) // t3 missing from tasksById
        let tasksById = byId([t1, t2], id: { $0.id })

        let result = PoolHealth.computePoolHealth(
            pool, templates: [], poolsById: byId([pool], id: { $0.id }), tasksById: tasksById
        )

        XCTAssertEqual(result.taskCount, 1)
        XCTAssertEqual(result.consumers, [])
    }

    // MARK: - computePoolHealth: consumer detection

    private func consumerDetectionFixtures() -> (pool: Pool, poolsById: [String: Pool], tasksById: [String: Task]) {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let pool = buildPool("p1", ["t1", "t2"])
        return (pool, byId([pool], id: { $0.id }), byId([t1, t2], id: { $0.id }))
    }

    func testConsumerDetection_IncludesActiveTemplateShortOnPool() {
        let (pool, poolsById, tasksById) = consumerDetectionFixtures()
        // 3x3 FREE floor is 8; mix supplies only 2 -> shortBy 6.
        let template = buildTemplate("tpl1", name: "Template tpl1", poolIds: ["p1"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers, [
            PoolHealth.Consumer(
                templateId: "tpl1", templateName: "Template tpl1",
                timeframe: .weekly, boardSize: 3, shortBy: 6
            ),
        ])
    }

    func testConsumerDetection_SkipsSoftDeletedTemplate() {
        let (pool, poolsById, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", poolIds: ["p1"], isDeleted: true)

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_SkipsPausedTemplate() {
        let (pool, poolsById, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", poolIds: ["p1"], isActive: false)

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers, [])
    }

    func testConsumerDetection_SkipsTemplateNotReferencingThisPool() {
        let (pool, poolsById, tasksById) = consumerDetectionFixtures()
        let template = buildTemplate("tpl1", poolIds: ["other-pool"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers, [])
    }

    // MARK: - computePoolHealth: shortBy math across sizes/centers

    private func shortByFixtures() -> (pool: Pool, poolsById: [String: Pool], tasksById: [String: Task]) {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let pool = buildPool("p1", ["t1", "t2"]) // supplies 2 resolvable tasks
        return (pool, byId([pool], id: { $0.id }), byId([t1, t2], id: { $0.id }))
    }

    func testShortBy_3x3FreeCenter_Floor8_Mix2_ShortBy6() {
        let (pool, poolsById, tasksById) = shortByFixtures()
        let template = buildTemplate("tpl1", boardSize: 3, centerSquareType: .free, poolIds: ["p1"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers[0].shortBy, 6)
    }

    func testShortBy_3x3NoneCenter_Floor9_Mix2_ShortBy7() {
        let (pool, poolsById, tasksById) = shortByFixtures()
        let template = buildTemplate("tpl1", boardSize: 3, centerSquareType: .none, poolIds: ["p1"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers[0].shortBy, 7)
    }

    func testShortBy_4x4_Floor16_Mix2_ShortBy14_ThreadsBoardSize() {
        let (pool, poolsById, tasksById) = shortByFixtures()
        let template = buildTemplate("tpl1", boardSize: 4, centerSquareType: .free, poolIds: ["p1"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [template], poolsById: poolsById, tasksById: tasksById
        )

        XCTAssertEqual(result.consumers[0].shortBy, 14)
        // boardSize is carried on the consumer itself for any per-template
        // rendering, even though the combined card summary line
        // (`formatPoolShortSummary`) only counts consumers.
        XCTAssertEqual(result.consumers[0].boardSize, 4)
    }

    func testShortBy_EnoughMixToFill_NotAConsumer() {
        let wideTasks = (0..<8).map { buildTask("w\($0)") }
        let widePool = buildPool("p2", wideTasks.map { $0.id })
        let template = buildTemplate("tpl1", boardSize: 3, centerSquareType: .free, poolIds: ["p2"])

        let result = PoolHealth.computePoolHealth(
            widePool,
            templates: [template],
            poolsById: byId([widePool], id: { $0.id }),
            tasksById: byId(wideTasks, id: { $0.id })
        )

        XCTAssertEqual(result.consumers, [])
    }

    // MARK: - computePoolHealth: multiple consumers

    func testMultipleConsumers_ReturnsOneEntryPerShortTemplate() {
        let t1 = buildTask("t1")
        let pool = buildPool("p1", ["t1"])
        let tasksById = byId([t1], id: { $0.id })
        let poolsById = byId([pool], id: { $0.id })
        let tplA = buildTemplate(
            "tplA", name: "Morning Kickstart", timeframe: .daily,
            boardSize: 3, centerSquareType: .free, poolIds: ["p1"]
        )
        let tplB = buildTemplate(
            "tplB", name: "Weekly Reset", timeframe: .weekly,
            boardSize: 3, centerSquareType: .none, poolIds: ["p1"]
        )

        let result = PoolHealth.computePoolHealth(
            pool, templates: [tplA, tplB], poolsById: poolsById, tasksById: tasksById
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

    // MARK: - computePoolHealth: healthy pool

    func testHealthyPool_ReturnsEmptyConsumers() {
        let t1 = buildTask("t1")
        let pool = buildPool("p1", ["t1"])

        let result = PoolHealth.computePoolHealth(
            pool, templates: [], poolsById: byId([pool], id: { $0.id }), tasksById: byId([t1], id: { $0.id })
        )

        XCTAssertEqual(result.consumers, [])
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
