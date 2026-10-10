import XCTest
@testable import OYBC

/// Cross-platform vector pins for `CounterPlacement` (Swift twin of
/// `packages/shared/src/algorithms/counterPlacement.ts`), the root-settings
/// `TaskTitle.counterCopyTitle` / `generateCounterTaskTitle`, the planner's
/// placement defaults and `effectiveMemberTarget`'s default — driven by the
/// checked-in copy of `counterPlacementVectors.json`, the fixture
/// `packages/shared/tests/algorithms/counterPlacement.test.ts` runs
/// (docs/SHARED_COUNTER_SETTINGS.md §2).
final class CounterPlacementVectorTests: XCTestCase {

    private struct Goals: Decodable {
        let daily: Double?, weekly: Double?, monthly: Double?, yearly: Double?
        var value: CounterTimeframeGoals {
            CounterTimeframeGoals(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
        }
    }

    private struct Root: Decodable {
        let type: String?
        let title: String?
        let action: String?
        let unit: String?
        let maxCount: Double?
        let countKind: CountKind?
        let counterName: String?
        let titleTemplateSingular: String?
        let titleTemplatePlural: String?
        let timeframeGoals: Goals?
        let sharedCounterId: String?

        var fields: CounterSettings.Fields {
            CounterSettings.Fields(
                title: title, action: action, unit: unit, maxCount: maxCount, countKind: countKind,
                counterName: counterName, titleTemplateSingular: titleTemplateSingular,
                titleTemplatePlural: titleTemplatePlural, timeframeGoals: timeframeGoals?.value
            )
        }

        var settings: CounterSettings.TitleSettings {
            CounterSettings.TitleSettings(
                counterName: counterName, titleTemplateSingular: titleTemplateSingular,
                titleTemplatePlural: titleTemplatePlural
            )
        }

        func task(id: String) -> Task {
            var t = Task(
                id: id, userId: "u1", title: title ?? "", type: TaskType(rawValue: type ?? "counting") ?? .counting,
                action: action, unit: unit, maxCount: maxCount, totalCompletions: 0, totalInstances: 0,
                createdAt: "2026-10-09T00:00:00.000Z", updatedAt: "2026-10-09T00:00:00.000Z", version: 1,
                isDeleted: false, countKind: countKind
            )
            t.sharedCounterId = sharedCounterId
            t.counterName = counterName
            t.titleTemplateSingular = titleTemplateSingular
            t.titleTemplatePlural = titleTemplatePlural
            t.timeframeGoals = timeframeGoals?.value
            return t
        }
    }

    private struct Board: Decodable { let timeframe: String }
    private struct Existing: Decodable { let maxCount: Double? }

    private struct DefaultVector: Decodable { let name: String; let root: Root; let timeframe: String; let expected: Double? }
    private struct GoalVector: Decodable {
        let name: String; let root: Root; let board: Board; let existingCopy: Existing?; let expected: Double?
    }
    private struct NeedsVector: Decodable { let name: String; let root: Root; let board: Board; let expected: Bool }
    private struct SearchVector: Decodable { let name: String; let query: String; let root: Root; let expected: Bool }
    private struct TaskSearchVector: Decodable { let name: String; let query: String; let task: Root; let expected: Bool }
    private struct CopyVector: Decodable {
        let name: String; let member: Root; let root: Root; let newMaxCount: Double; let expected: String
    }
    private struct GenerateVector: Decodable {
        let name: String; let action: String; let maxCount: Double; let unit: String
        let providedTitle: String?; let countKind: CountKind?; let settings: Root?; let expected: String
    }
    private struct TargetVector: Decodable {
        let name: String; let goal: Double; let explicit: Double?; let fromBoard: Bool
        let sourceWindow: String; let targetWindow: String; let timeframeDefault: Double?; let expected: Double
    }
    private struct PlanSupply: Decodable {
        let kind: String; let supply: [String]; let memberRules: [String: BoardSourceMemberRule]?
    }
    private struct PlanDraft: Decodable, Equatable { let root: String; let maxCount: Double; let title: String }
    private struct PlanExpected: Decodable { let placement: [String]; let drafts: [PlanDraft] }
    private struct PlanVector: Decodable {
        let name: String; let window: String; let selected: [String]; let manual: [String]
        let supplies: [PlanSupply]; let rng: Double?; let expected: PlanExpected
    }
    private struct Plan: Decodable {
        let boardId: String; let tasks: [String: Root]; let sourceWindows: [String: String]; let vectors: [PlanVector]
    }

    private struct Fixture: Decodable {
        let counterTimeframeDefault: [DefaultVector]
        let placementGoalForCounter: [GoalVector]
        let placementNeedsCopy: [NeedsVector]
        let counterSearchMatches: [SearchVector]
        let taskSearchMatches: [TaskSearchVector]
        let counterCopyTitleWithRoot: [CopyVector]
        let planDerivedTasks: Plan
        let effectiveMemberTarget: [TargetVector]
        let generateCounterTaskTitleWithSettings: [GenerateVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CounterPlacementVectorTests.self).url(
            forResource: "counterPlacementVectors", withExtension: "json"
        ) else {
            XCTFail("counterPlacementVectors.json not found in test bundle — re-run xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    private func tf(_ raw: String) throws -> Timeframe { try XCTUnwrap(Timeframe(rawValue: raw), raw) }

    func testCounterTimeframeDefault() throws {
        for v in try loadFixture().counterTimeframeDefault {
            XCTAssertEqual(
                CounterPlacement.counterTimeframeDefault(v.root.fields, timeframe: try tf(v.timeframe)), v.expected, v.name
            )
        }
    }

    func testPlacementGoalForCounter() throws {
        for v in try loadFixture().placementGoalForCounter {
            XCTAssertEqual(
                CounterPlacement.placementGoalForCounter(
                    v.root.fields, timeframe: try tf(v.board.timeframe), existingCopyGoal: v.existingCopy?.maxCount
                ),
                v.expected, v.name
            )
        }
    }

    func testPlacementNeedsCopy() throws {
        let vectors = try loadFixture().placementNeedsCopy
        XCTAssertEqual(Set(vectors.map(\.expected)), [true, false])
        for v in vectors {
            XCTAssertEqual(
                CounterPlacement.placementNeedsCopy(v.root.fields, timeframe: try tf(v.board.timeframe)), v.expected, v.name
            )
        }
    }

    func testCounterSearchMatches() throws {
        let vectors = try loadFixture().counterSearchMatches
        XCTAssertEqual(Set(vectors.map(\.expected)), [true, false])
        for v in vectors {
            XCTAssertEqual(CounterPlacement.counterSearchMatches(v.query, root: v.root.fields), v.expected, v.name)
        }
    }

    func testTaskSearchMatches() throws {
        for v in try loadFixture().taskSearchMatches {
            XCTAssertEqual(CounterPlacement.taskSearchMatches(v.query, task: v.task.task(id: "t")), v.expected, v.name)
        }
    }

    func testNormalizeSearchText() {
        XCTAssertEqual(CounterPlacement.normalizeSearchText("  Crème   BRÛLÉE "), "creme brulee")
        XCTAssertEqual(CounterPlacement.normalizeSearchText(nil), "")
    }

    func testCounterCopyTitleWithRootSettings() throws {
        for v in try loadFixture().counterCopyTitleWithRoot {
            XCTAssertEqual(
                TaskTitle.counterCopyTitle(member: v.member.task(id: "m"), newMaxCount: v.newMaxCount, settings: v.root.settings),
                v.expected, v.name
            )
        }
    }

    func testGenerateCounterTaskTitleWithSettings() throws {
        for v in try loadFixture().generateCounterTaskTitleWithSettings {
            XCTAssertEqual(
                TaskTitle.generateCounterTaskTitle(
                    action: v.action, maxCount: v.maxCount, unit: v.unit, providedTitle: v.providedTitle,
                    countKind: v.countKind ?? .discrete, settings: v.settings?.settings
                ),
                v.expected, v.name
            )
        }
    }

    func testEffectiveMemberTargetConsultsTheDefault() throws {
        for v in try loadFixture().effectiveMemberTarget {
            XCTAssertEqual(
                BoardSources.effectiveMemberTarget(
                    goal: v.goal, explicit: v.explicit, mode: .recurring, fromBoard: v.fromBoard,
                    sourceWindow: .init(timeframe: try tf(v.sourceWindow)),
                    targetWindow: .init(timeframe: try tf(v.targetWindow)),
                    timeframeDefault: v.timeframeDefault
                ),
                v.expected, v.name
            )
        }
    }

    func testPlanDerivedTasksPlacementDefaults() throws {
        let p = try loadFixture().planDerivedTasks
        let tasksById = Dictionary(uniqueKeysWithValues: p.tasks.map { ($0.key, $0.value.task(id: $0.key)) })
        let sourceWindows = try p.sourceWindows.mapValues { BoardSources.BoardWindow(timeframe: try tf($0)) }
        func resolve(_ token: String) -> String {
            token.hasPrefix("derived:")
                ? BoardSources.derivedTaskId(boardId: p.boardId, rootTaskId: String(token.dropFirst("derived:".count)))
                : token
        }
        for v in p.vectors {
            let supplies = v.supplies.enumerated().map { i, s in
                BoardSources.ExpandedSupply(
                    source: BoardSource(
                        sourceId: "s\(i)", kind: BoardSource.Kind(rawValue: s.kind) ?? .pool, memberRules: s.memberRules
                    ),
                    supplyTaskIds: s.supply, partOf: [:]
                )
            }
            let out = BoardSources.planDerivedTasks(
                selectedIds: v.selected, supplies: supplies, manualTaskIds: v.manual, manualTaskVary: [:],
                boardId: p.boardId, window: .init(timeframe: try tf(v.window)), mode: .oneOff,
                tasksById: tasksById, childrenByCompoundId: [:], sourceWindowByTaskId: sourceWindows,
                baselineByRootId: [:], rootsById: tasksById,
                rng: {
                    guard let r = v.rng else { XCTFail("vary is off — no rng"); return 0 }
                    return r
                }
            )
            XCTAssertEqual(out.placementIds, v.expected.placement.map(resolve), v.name)
            XCTAssertEqual(
                out.derivedTasks.map { PlanDraft(root: $0.rootTaskId, maxCount: $0.maxCount, title: $0.title) },
                v.expected.drafts, v.name
            )
        }
    }
}
