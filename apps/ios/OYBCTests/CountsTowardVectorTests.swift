import XCTest
@testable import OYBC

/// Cross-platform vector pins for `CountsToward` (Swift twin of
/// `packages/shared/src/algorithms/countsToward.ts`), driven by the checked-in
/// copy of `countsTowardVectors.json` — the same fixture
/// `packages/shared/tests/algorithms/countsToward.test.ts` runs
/// (docs/SHARED_COUNTER_SETTINGS.md §3).
final class CountsTowardVectorTests: XCTestCase {

    private struct MiniTask: Decodable {
        let id: String
        let type: String?
        let operatorField: String?
        let threshold: Int?
        let maxCount: Double?
        let isCompleted: Bool?
        let completedAt: String?
        let isDeleted: Bool?
        let isCounter: Bool?
        let sharedCounterId: String?
        let createdInWizard: Bool?
        let startDate: String?
        let endDate: String?
        let countKind: CountKind?
        let createdAt: String?
        let countsTowardCounterId: String?
        let countsTowardAmount: Double?

        enum CodingKeys: String, CodingKey {
            case id, type, threshold, maxCount, isCompleted, completedAt, isDeleted, isCounter
            case sharedCounterId, createdInWizard, startDate, endDate, countKind, createdAt
            case countsTowardCounterId, countsTowardAmount
            case operatorField = "operator"
        }

        var task: Task {
            Task(
                id: id, userId: "u", title: id, type: TaskType(rawValue: type ?? "normal") ?? .normal,
                maxCount: maxCount, operatorType: operatorField.flatMap { OperatorType(rawValue: $0) },
                threshold: threshold, totalCompletions: 0, totalInstances: 0,
                isCompleted: isCompleted ?? false, completedAt: completedAt,
                createdAt: createdAt ?? "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                version: 1, isDeleted: isDeleted ?? false,
                startDate: startDate, endDate: endDate, sharedCounterId: sharedCounterId,
                createdInWizard: createdInWizard ?? false, isCounter: isCounter ?? false,
                countKind: countKind, countsTowardCounterId: countsTowardCounterId,
                countsTowardAmount: countsTowardAmount.map { Int($0) }
            )
        }
    }

    private struct MiniEvent: Decodable {
        let id: String?
        let taskId: String
        let delta: Double?
        let occurredAt: String
        let isDeleted: Bool?

        func event(_ index: Int) -> TaskEvent {
            TaskEvent(
                id: id ?? "e\(index)", userId: "u", taskId: taskId, kind: delta == nil ? .completion : .increment,
                delta: delta, occurredAt: occurredAt, boardId: nil, createdAt: occurredAt, updatedAt: occurredAt,
                lastSyncedAt: nil, version: 1, isDeleted: isDeleted ?? false, deletedAt: nil
            )
        }
    }

    private struct MiniLink: Decodable {
        let compoundTaskId: String
        let childTaskId: String
        let isDeleted: Bool?
    }

    private struct State: Decodable, Equatable {
        let isCompleted: Bool
        let completedAt: String?
    }

    private struct EventIdVector: Decodable { let taskId: String; let expected: String }
    private struct AmountVector: Decodable { let name: String; let countsTowardAmount: Double?; let expected: Int }
    private struct StateVector: Decodable {
        let name: String; let taskId: String; let tasks: [MiniTask]; let events: [MiniEvent]
        let children: [MiniLink]; let expected: State
    }
    private struct Expected: Decodable {
        let kind: String; let rootId: String; let delta: Int?; let occurredAt: String
        let previousRootId: String?; let previousOccurredAt: String?; let wasDeleted: Bool?
    }
    private struct PlanVector: Decodable {
        let name: String; let contributor: MiniTask; let tasks: [MiniTask]; let state: State
        let existing: MiniEvent?; let expected: Expected?
    }
    private struct ProblemVector: Decodable {
        let name: String; let taskId: String; let targetId: String; let amount: Double?
        let tasks: [MiniTask]; let children: [MiniLink]; let expected: String?
    }
    private struct Fixture: Decodable {
        let eventId: [EventIdVector]
        let amount: [AmountVector]
        let state: [StateVector]
        let plan: [PlanVector]
        let problem: [ProblemVector]
    }

    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "countsTowardVectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func links(_ rows: [MiniLink]) -> [CompoundChild] {
        rows.enumerated().map { i, r in
            CompoundChild(
                id: "l\(i)", compoundTaskId: r.compoundTaskId, childTaskId: r.childTaskId, childIndex: i,
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                lastSyncedAt: nil, version: 1, isDeleted: r.isDeleted ?? false, deletedAt: nil
            )
        }
    }

    func test_eventId() throws {
        for v in try load().eventId {
            XCTAssertEqual(CountsToward.eventId(contributingTaskId: v.taskId), v.expected, v.taskId)
        }
    }

    func test_amount() throws {
        // A fractional amount can't reach Swift (`Task.countsTowardAmount` is an
        // Int; Zod refuses it at the sync boundary) — those vectors are TS-only.
        for v in try load().amount where v.countsTowardAmount.map({ $0 == $0.rounded() }) ?? true {
            let task = MiniTask(
                id: "t", type: nil, operatorField: nil, threshold: nil, maxCount: nil, isCompleted: nil,
                completedAt: nil, isDeleted: nil, isCounter: nil, sharedCounterId: nil, createdInWizard: nil,
                startDate: nil, endDate: nil, countKind: nil, createdAt: nil, countsTowardCounterId: nil,
                countsTowardAmount: v.countsTowardAmount
            ).task
            XCTAssertEqual(CountsToward.amount(of: task), v.expected, v.name)
        }
    }

    func test_resolveContributionState() throws {
        for v in try load().state {
            let tasks = v.tasks.map(\.task)
            let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            var byCompound: [String: [CompoundChild]] = [:]
            for l in links(v.children) { byCompound[l.compoundTaskId, default: []].append(l) }
            var byTask: [String: [TaskEvent]] = [:]
            for (i, e) in v.events.enumerated() { byTask[e.taskId, default: []].append(e.event(i)) }
            let s = CountsToward.resolveContributionState(
                taskById[v.taskId]!, childrenByCompound: byCompound, taskById: taskById, eventsByTaskId: byTask
            )
            XCTAssertEqual(State(isCompleted: s.isCompleted, completedAt: s.completedAt), v.expected, v.name)
        }
    }

    func test_plan() throws {
        for v in try load().plan {
            let contributor = v.contributor.task
            var taskById = Dictionary(uniqueKeysWithValues: v.tasks.map { ($0.task.id, $0.task) })
            taskById[contributor.id] = contributor
            let eventId = CountsToward.eventId(contributingTaskId: contributor.id)
            let existing = v.existing.map { e in
                MiniEvent(id: eventId, taskId: e.taskId, delta: e.delta, occurredAt: e.occurredAt, isDeleted: e.isDeleted).event(0)
            }
            let action = CountsToward.plan(
                contributor: contributor, taskById: taskById,
                state: CountsToward.ContributionState(isCompleted: v.state.isCompleted, completedAt: v.state.completedAt),
                existing: existing
            )
            guard let exp = v.expected else {
                XCTAssertNil(action, v.name)
                continue
            }
            let want: CountsToward.Action
            switch exp.kind {
            case "insert":
                want = .insert(eventId: eventId, rootId: exp.rootId, delta: exp.delta!, occurredAt: exp.occurredAt)
            case "revise":
                want = .revise(
                    eventId: eventId, rootId: exp.rootId, delta: exp.delta!, occurredAt: exp.occurredAt,
                    previousRootId: exp.previousRootId!, previousOccurredAt: exp.previousOccurredAt!,
                    wasDeleted: exp.wasDeleted!
                )
            default:
                want = .tombstone(eventId: eventId, rootId: exp.rootId, occurredAt: exp.occurredAt)
            }
            XCTAssertEqual(action, want, v.name)
        }
    }

    func test_problem() throws {
        for v in try load().problem {
            let tasks = v.tasks.map(\.task)
            let task = try XCTUnwrap(tasks.first { $0.id == v.taskId })
            let p = CountsToward.problem(task: task, targetId: v.targetId, amount: v.amount, tasks: tasks, children: links(v.children))
            XCTAssertEqual(p?.rawValue, v.expected, v.name)
        }
    }
}
