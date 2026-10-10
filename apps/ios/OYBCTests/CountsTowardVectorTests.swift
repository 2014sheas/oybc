import XCTest
@testable import OYBC

/// Cross-platform vector pins for `CountsToward` (Swift twin of
/// `packages/shared/src/algorithms/countsToward.ts`), driven by the checked-in
/// copy of `countsTowardVectors.json` — the same fixture
/// `packages/shared/tests/algorithms/countsToward.test.ts` runs
/// (docs/SHARED_COUNTER_SETTINGS.md §3; D10: one credit per completion occurrence).
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
        let forkedFromTaskId: String?

        enum CodingKeys: String, CodingKey {
            case id, type, threshold, maxCount, isCompleted, completedAt, isDeleted, isCounter
            case sharedCounterId, createdInWizard, startDate, endDate, countKind, createdAt
            case countsTowardCounterId, countsTowardAmount, forkedFromTaskId
            case operatorField = "operator"
        }

        var task: Task {
            var t = Task(
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
            t.forkedFromTaskId = forkedFromTaskId
            return t
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

    private struct MiniBoard: Decodable {
        let id: String
        let startDate: String
        let endDate: String?
        let sealedAt: String?
        let status: String?
        let isDeleted: Bool?

        var board: Board {
            var dict: [String: Any] = [
                "id": id, "userId": "u", "name": id, "status": status ?? BoardStatus.active.rawValue,
                "boardSize": 3, "timeframe": Timeframe.custom.rawValue, "startDate": startDate,
                "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
                "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
                "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
                "version": 1, "isDeleted": isDeleted ?? false,
            ]
            if let endDate { dict["endDate"] = endDate }
            if let sealedAt {
                dict["sealedAt"] = sealedAt
                dict["sealedCompletedCells"] = "[]"
            }
            let data = try! JSONSerialization.data(withJSONObject: dict)
            return try! JSONDecoder().decode(Board.self, from: data)
        }
    }

    private struct MiniPlacement: Decodable {
        let boardId: String
        let taskId: String
        let isDeleted: Bool?

        func placement(_ index: Int) -> BoardTask {
            BoardTask(
                id: "bt\(index)", boardId: boardId, taskId: taskId, row: 0, col: 0, isCenter: false,
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                version: 1, isDeleted: isDeleted ?? false
            )
        }
    }

    private struct MiniOccurrence: Decodable {
        let kind: String
        let eventId: String?
        let startDate: String?

        var occurrence: CountsToward.Occurrence {
            switch kind {
            case "event": return .event(eventId: eventId!)
            case "window": return .window(startDate: startDate!)
            default: return .lifetime
            }
        }
    }

    private struct MiniWindow: Decodable {
        let windowStart: String?
        let windowEnd: String?
    }

    private struct State: Decodable, Equatable {
        let isCompleted: Bool
        let completedAt: String?
        let completingEventId: String?
    }

    private struct MiniCredit: Decodable { let occurrence: MiniOccurrence; let occurredAt: String }
    private struct MiniStored: Decodable {
        let occurrence: MiniOccurrence; let taskId: String; let delta: Double?; let occurredAt: String; let isDeleted: Bool?
    }

    private struct EventIdVector: Decodable { let contributorId: String; let occurrence: MiniOccurrence; let expected: String }
    private struct AmountVector: Decodable { let name: String; let countsTowardAmount: Double?; let expected: Int }
    private struct StateVector: Decodable {
        let name: String; let taskId: String; let tasks: [MiniTask]; let events: [MiniEvent]
        let children: [MiniLink]; let window: MiniWindow?; let expected: State
    }
    private struct CreditsVector: Decodable {
        let name: String; let taskId: String; let tasks: [MiniTask]; let events: [MiniEvent]; let children: [MiniLink]
        let placements: [MiniPlacement]; let boards: [MiniBoard]; let expected: [MiniCredit]
    }
    private struct CandidatesVector: Decodable {
        let name: String; let taskId: String; let tasks: [MiniTask]; let events: [MiniEvent]
        let placements: [MiniPlacement]; let boards: [MiniBoard]; let expected: [MiniOccurrence]
    }
    private struct ExpectedAction: Decodable {
        let occurrence: MiniOccurrence; let kind: String; let rootId: String; let delta: Int?; let occurredAt: String
        let previousRootId: String?; let previousOccurredAt: String?; let wasDeleted: Bool?
    }
    private struct PlanSetVector: Decodable {
        let name: String; let contributor: MiniTask; let tasks: [MiniTask]; let wanted: [MiniCredit]
        let candidates: [MiniOccurrence]; let stored: [MiniStored]; let expected: [ExpectedAction]
    }
    private struct ProblemVector: Decodable {
        let name: String; let taskId: String; let targetId: String; let amount: Double?
        let tasks: [MiniTask]; let children: [MiniLink]; let expected: String?
    }
    private struct Fixture: Decodable {
        let eventId: [EventIdVector]
        let amount: [AmountVector]
        let state: [StateVector]
        let credits: [CreditsVector]
        let candidates: [CandidatesVector]
        let planSet: [PlanSetVector]
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

    /// The `CountsToward.Inputs` a credits / candidates vector describes.
    private func inputs(
        tasks: [MiniTask], events: [MiniEvent], children: [MiniLink], placements: [MiniPlacement], boards: [MiniBoard]
    ) -> CountsToward.Inputs {
        let taskRows = tasks.map(\.task)
        var byCompound: [String: [CompoundChild]] = [:]
        for l in links(children) { byCompound[l.compoundTaskId, default: []].append(l) }
        var live: [String: [TaskEvent]] = [:]
        var all: [String: [TaskEvent]] = [:]
        for (i, m) in events.enumerated() {
            let e = m.event(i)
            all[e.taskId, default: []].append(e)
            if !e.isDeleted { live[e.taskId, default: []].append(e) }
        }
        return CountsToward.Inputs(
            taskById: Dictionary(uniqueKeysWithValues: taskRows.map { ($0.id, $0) }),
            childrenByCompound: byCompound, eventsByTaskId: live, allEventsByTaskId: all,
            placements: placements.enumerated().map { $1.placement($0) },
            boardById: Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0.board) })
        )
    }

    private func miniTask(_ id: String, amount: Double? = nil, from: String? = nil) -> Task {
        MiniTask(
            id: id, type: nil, operatorField: nil, threshold: nil, maxCount: nil, isCompleted: nil, completedAt: nil,
            isDeleted: nil, isCounter: nil, sharedCounterId: nil, createdInWizard: nil, startDate: nil, endDate: nil,
            countKind: nil, createdAt: nil, countsTowardCounterId: nil, countsTowardAmount: amount, forkedFromTaskId: from
        ).task
    }

    func test_eventId() throws {
        for v in try load().eventId {
            XCTAssertEqual(
                CountsToward.eventId(contributorId: v.contributorId, occurrence: v.occurrence.occurrence), v.expected,
                "\(v.contributorId) \(v.occurrence.kind)"
            )
        }
    }

    func test_amount() throws {
        // A fractional amount can't reach Swift (`Task.countsTowardAmount` is an
        // Int; Zod refuses it at the sync boundary) — those vectors are TS-only.
        for v in try load().amount where v.countsTowardAmount.map({ $0 == $0.rounded() }) ?? true {
            XCTAssertEqual(CountsToward.amount(of: miniTask("t", amount: v.countsTowardAmount)), v.expected, v.name)
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
            let window = v.window.map { CountsToward.Window(windowStart: $0.windowStart, windowEnd: $0.windowEnd) } ?? .lifetime
            let s = CountsToward.resolveContributionState(
                taskById[v.taskId]!, childrenByCompound: byCompound, taskById: taskById, eventsByTaskId: byTask, window: window
            )
            XCTAssertEqual(
                State(isCompleted: s.isCompleted, completedAt: s.completedAt, completingEventId: s.completingEventId),
                v.expected, v.name
            )
            // Agrees with the kernel's windowed compound evaluation.
            if let root = taskById[v.taskId], root.type == .compound {
                var liveByTask: [String: [TaskEvent]] = [:]
                for (id, evs) in byTask { liveByTask[id] = evs.filter { !$0.isDeleted } }
                let ctx = CompoundWindowContext(windowStart: window.windowStart, windowEnd: window.windowEnd, eventsByTaskId: liveByTask)
                XCTAssertEqual(
                    CompoundEvaluation.evaluate(compound: root, childrenByCompound: byCompound, taskById: taskById, windowContext: ctx),
                    v.expected.isCompleted, v.name
                )
            }
        }
    }

    func test_resolveContributionCredits() throws {
        for v in try load().credits {
            let inputs = inputs(tasks: v.tasks, events: v.events, children: v.children, placements: v.placements, boards: v.boards)
            let task = try XCTUnwrap(inputs.taskById[v.taskId])
            let expected = v.expected.map {
                CountsToward.Credit(
                    eventId: CountsToward.eventId(contributorId: task.id, occurrence: $0.occurrence.occurrence),
                    occurrence: $0.occurrence.occurrence, occurredAt: $0.occurredAt
                )
            }.sorted { $0.eventId < $1.eventId }
            let credits = CountsToward.resolveContributionCredits(task, inputs: inputs)
            XCTAssertEqual(credits, expected, v.name)
            // Every wanted credit is among the candidates.
            let candidates = Set(CountsToward.candidateContributionIds(task, inputs: inputs))
            for c in credits { XCTAssertTrue(candidates.contains(c.eventId), "\(v.name): \(c.eventId) not a candidate") }
        }
    }

    func test_candidateContributionIds() throws {
        for v in try load().candidates {
            let inputs = inputs(tasks: v.tasks, events: v.events, children: [], placements: v.placements, boards: v.boards)
            let task = try XCTUnwrap(inputs.taskById[v.taskId])
            let expected = Set(v.expected.map { CountsToward.eventId(contributorId: task.id, occurrence: $0.occurrence) }).sorted()
            XCTAssertEqual(CountsToward.candidateContributionIds(task, inputs: inputs), expected, v.name)
        }
    }

    func test_planSet() throws {
        for v in try load().planSet {
            let contributor = v.contributor.task
            var taskById = Dictionary(uniqueKeysWithValues: v.tasks.map { ($0.task.id, $0.task) })
            taskById[contributor.id] = contributor
            func idOf(_ o: MiniOccurrence) -> String { CountsToward.eventId(contributorId: contributor.id, occurrence: o.occurrence) }
            let wanted = v.wanted.map { CountsToward.Credit(eventId: idOf($0.occurrence), occurrence: $0.occurrence.occurrence, occurredAt: $0.occurredAt) }
            let candidates = v.candidates.map(idOf)
            var storedById: [String: TaskEvent] = [:]
            for s in v.stored {
                let id = idOf(s.occurrence)
                storedById[id] = MiniEvent(id: id, taskId: s.taskId, delta: s.delta, occurredAt: s.occurredAt, isDeleted: s.isDeleted).event(0)
            }
            let expected: [CountsToward.Action] = v.expected.map { exp in
                let id = idOf(exp.occurrence)
                switch exp.kind {
                case "insert":
                    return .insert(eventId: id, rootId: exp.rootId, delta: exp.delta!, occurredAt: exp.occurredAt)
                case "revise":
                    return .revise(
                        eventId: id, rootId: exp.rootId, delta: exp.delta!, occurredAt: exp.occurredAt,
                        previousRootId: exp.previousRootId!, previousOccurredAt: exp.previousOccurredAt!,
                        wasDeleted: exp.wasDeleted!
                    )
                default:
                    return .tombstone(eventId: id, rootId: exp.rootId, occurredAt: exp.occurredAt)
                }
            }.sorted { $0.eventId < $1.eventId }
            let actions = CountsToward.plan(
                contributor: contributor, taskById: taskById, wanted: wanted, candidateIds: candidates, storedById: storedById
            )
            XCTAssertEqual(actions, expected, v.name)
        }
    }

    func test_canonicalOccurrenceEventId_walksAForkOfAFork() {
        let (o, f1, f2, orphan) = (miniTask("o"), miniTask("f1", from: "o"), miniTask("f2", from: "f1"), miniTask("orphan", from: "missing"))
        let at = "2026-01-01T00:00:00.000Z"
        let e = MiniEvent(id: "e", taskId: "o", delta: nil, occurredAt: at, isDeleted: nil).event(0)
        let e1 = MiniEvent(id: BoardScopedFork.forkedEventId(forkId: "f1", eventId: "e"), taskId: "f1", delta: nil, occurredAt: at, isDeleted: nil).event(1)
        let e2 = MiniEvent(id: BoardScopedFork.forkedEventId(forkId: "f2", eventId: e1.id), taskId: "f2", delta: nil, occurredAt: at, isDeleted: nil).event(2)
        let own = MiniEvent(id: "own", taskId: "f1", delta: nil, occurredAt: at, isDeleted: nil).event(3)
        let taskById = ["o": o, "f1": f1, "f2": f2, "orphan": orphan]
        let all = ["o": [e], "f1": [e1, own], "f2": [e2]]
        XCTAssertEqual(CountsToward.canonicalOccurrenceEventId(e2.id, task: f2, taskById: taskById, allEventsByTaskId: all), "e")
        XCTAssertEqual(CountsToward.canonicalOccurrenceEventId(e1.id, task: f1, taskById: taskById, allEventsByTaskId: all), "e")
        XCTAssertEqual(CountsToward.canonicalOccurrenceEventId("own", task: f1, taskById: taskById, allEventsByTaskId: all), "own")
        XCTAssertEqual(CountsToward.canonicalOccurrenceEventId("e", task: o, taskById: taskById, allEventsByTaskId: all), "e")
        XCTAssertEqual(CountsToward.canonicalOccurrenceEventId("x", task: orphan, taskById: taskById, allEventsByTaskId: all), "x")
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
