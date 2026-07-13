import XCTest
@testable import OYBC

/// Cross-platform Windowed Completion enforcement (docs/WINDOWED_COMPLETION.md
/// §Testing matrix → "Cross-platform vectors").
///
/// Runs the three hand-authored PR-A fixtures
/// (`packages/shared/tests/fixtures/{taskWindowStateVectors,backfillEventVectors,
/// sealReDerivationVectors}.json`, synced to `OYBCTests/Fixtures/`) through the
/// iOS ports:
///   - `resolveTaskWindowState` (Helpers/TaskEvents.swift)
///   - `UUIDv5.uuidv5` + `backfillTaskEventId` + `buildBackfillTaskEvent`
///     (Helpers/UUIDv5.swift + Helpers/TaskEvents.swift)
///   - `DerivationPass.computeSealedCompletedCells` (Services/DerivationPass.swift)
///
/// The SAME fixtures are exercised on the shared/web side by
/// `packages/shared/tests/algorithms/{taskEvents,taskEventBackfill,sealReDerivation}.test.ts`.
/// Both suites passing against the same vectors is what proves the two
/// hand-mirrored implementations agree, not just an audit claim.
final class TaskEventVectorTests: XCTestCase {

    private let ts = "2026-07-01T00:00:00.000Z"

    // MARK: - Fixture loading

    private func loadFixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle(for: TaskEventVectorTests.self).url(
            forResource: name, withExtension: "json"
        ) else {
            XCTFail(
                "\(name).json not found in test bundle — check project.yml's OYBCTests " +
                "`resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }

    // MARK: - resolveTaskWindowState vectors

    private struct WindowEvent: Decodable {
        let kind: String
        let delta: Int?
        let occurredAt: String
        let isDeleted: Bool
    }

    private struct WindowVector: Decodable {
        struct MiniTask: Decodable { let type: String; let maxCount: Int? }
        struct Expected: Decodable { let isCompleted: Bool; let count: Int }
        let name: String
        let task: MiniTask
        let windowStart: String?
        let events: [WindowEvent]
        let expected: Expected
    }

    private struct WindowFixture: Decodable { let vectors: [WindowVector] }

    /// Build a minimal event-owning Task (type + maxCount) for windowed resolution.
    private func makeTask(type: String, maxCount: Int?, sharedCounterId: String? = nil) -> Task {
        Task(
            id: "t", userId: "u", title: "t",
            type: TaskType(rawValue: type) ?? .normal,
            maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false,
            createdAt: ts, updatedAt: ts, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId
        )
    }

    private func makeEvent(_ e: WindowEvent, taskId: String = "t") -> TaskEvent {
        TaskEvent(
            id: UUID().uuidString, userId: "u", taskId: taskId,
            kind: TaskEventKind(rawValue: e.kind) ?? .completion,
            delta: e.delta, occurredAt: e.occurredAt, boardId: nil,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
            version: 1, isDeleted: e.isDeleted, deletedAt: nil
        )
    }

    func testResolveTaskWindowStateVectors() throws {
        let fixture = try loadFixture("taskWindowStateVectors", as: WindowFixture.self)
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let task = makeTask(type: v.task.type, maxCount: v.task.maxCount)
            let events = v.events.map { makeEvent($0) }
            let result = resolveTaskWindowState(task: task, events: events, windowStart: v.windowStart)
            XCTAssertEqual(result.isCompleted, v.expected.isCompleted, "Vector '\(v.name)' isCompleted")
            XCTAssertEqual(result.count, v.expected.count, "Vector '\(v.name)' count")
        }
    }

    // MARK: - uuidv5 + backfill vectors

    private struct Uuidv5Vector: Decodable {
        let name: String
        let namespace: String
        let name_input: String
        let expected: String
    }

    private struct IdVector: Decodable {
        let taskId: String
        let completionId: String
        let incrementId: String
    }

    private struct BackfillTaskSnapshot: Decodable {
        let id: String
        let userId: String
        let type: String
        let sharedCounterId: String?
        let isCompleted: Bool
        let completedAt: String?
        let currentCount: Int?
        let updatedAt: String
        let isDeleted: Bool
    }

    private struct ExpectedEvent: Decodable {
        let id: String
        let userId: String
        let taskId: String
        let kind: String
        let delta: Int?
        let occurredAt: String
        let createdAt: String
        let updatedAt: String
        let version: Int
        let isDeleted: Bool
    }

    private struct EventVector: Decodable {
        let name: String
        let task: BackfillTaskSnapshot
        let expected: ExpectedEvent?
    }

    private struct BackfillFixture: Decodable {
        let uuidv5Vectors: [Uuidv5Vector]
        let idVectors: [IdVector]
        let eventVectors: [EventVector]
    }

    func testUuidv5KnownAnswerVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.uuidv5Vectors.isEmpty)
        for v in fixture.uuidv5Vectors {
            let result = UUIDv5.uuidv5(name: v.name_input, namespace: v.namespace)
            XCTAssertEqual(result, v.expected, "uuidv5 vector '\(v.name)'")
        }
        // Belt-and-braces: the canonical RFC 4122 v5 known answer, independent
        // of any fixture regeneration.
        XCTAssertEqual(
            UUIDv5.uuidv5(name: "www.example.com", namespace: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"),
            "2ed6657d-e927-568b-95e1-2665a8aea6a2"
        )
    }

    func testBackfillTaskEventIdVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.idVectors.isEmpty)
        for v in fixture.idVectors {
            XCTAssertEqual(
                backfillTaskEventId(taskId: v.taskId, kind: .completion),
                v.completionId, "completion id for \(v.taskId)"
            )
            XCTAssertEqual(
                backfillTaskEventId(taskId: v.taskId, kind: .increment),
                v.incrementId, "increment id for \(v.taskId)"
            )
            // Kind-qualified: completion and increment ids must differ.
            XCTAssertNotEqual(v.completionId, v.incrementId)
        }
    }

    func testBuildBackfillTaskEventVectors() throws {
        let fixture = try loadFixture("backfillEventVectors", as: BackfillFixture.self)
        XCTAssertFalse(fixture.eventVectors.isEmpty)
        for v in fixture.eventVectors {
            let task = Task(
                id: v.task.id, userId: v.task.userId, title: v.task.id,
                type: TaskType(rawValue: v.task.type) ?? .normal,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: v.task.isCompleted,
                completedAt: v.task.completedAt,
                currentCount: v.task.currentCount,
                createdAt: v.task.updatedAt, updatedAt: v.task.updatedAt,
                version: 1, isDeleted: v.task.isDeleted,
                sharedCounterId: v.task.sharedCounterId
            )
            let result = buildBackfillTaskEvent(task: task)

            guard let expected = v.expected else {
                XCTAssertNil(result, "Vector '\(v.name)' expected nil")
                continue
            }
            let event = try XCTUnwrap(result, "Vector '\(v.name)' expected an event")
            XCTAssertEqual(event.id, expected.id, "Vector '\(v.name)' id")
            XCTAssertEqual(event.userId, expected.userId, "Vector '\(v.name)' userId")
            XCTAssertEqual(event.taskId, expected.taskId, "Vector '\(v.name)' taskId")
            XCTAssertEqual(event.kind.rawValue, expected.kind, "Vector '\(v.name)' kind")
            XCTAssertEqual(event.delta, expected.delta, "Vector '\(v.name)' delta")
            XCTAssertEqual(event.occurredAt, expected.occurredAt, "Vector '\(v.name)' occurredAt")
            XCTAssertEqual(event.createdAt, expected.createdAt, "Vector '\(v.name)' createdAt")
            XCTAssertEqual(event.updatedAt, expected.updatedAt, "Vector '\(v.name)' updatedAt")
            XCTAssertEqual(event.version, expected.version, "Vector '\(v.name)' version")
            XCTAssertEqual(event.isDeleted, expected.isDeleted, "Vector '\(v.name)' isDeleted")
        }
    }

    // MARK: - Seal re-derivation vectors

    private struct SealVector: Decodable {
        struct MiniBoard: Decodable {
            let id: String
            let boardSize: Int
            let centerSquareType: String
            let startDate: String
            let endDate: String?
            let status: String
            let linesCompleted: Int
            let completedLineIds: [String]?
            let isDeleted: Bool
        }
        struct MiniTask: Decodable {
            let id: String
            let type: String
            let maxCount: Int?
            let sharedCounterId: String?
            let isCompleted: Bool
            let isDeleted: Bool
        }
        struct MiniBoardTask: Decodable { let taskId: String; let row: Int; let col: Int }
        struct MiniEvent: Decodable {
            let id: String
            let taskId: String
            let kind: String
            let delta: Int?
            let occurredAt: String
            let isDeleted: Bool
        }
        let name: String
        let board: MiniBoard
        let tasks: [MiniTask]
        let boardTasks: [MiniBoardTask]
        let events: [MiniEvent]
        let expectedCells: [Int]
    }

    private struct SealFixture: Decodable { let vectors: [SealVector] }

    private func toBoard(_ m: SealVector.MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id, "userId": "u", "name": m.id,
            "status": m.status, "boardSize": m.boardSize,
            "timeframe": "daily", "startDate": m.startDate,
            "centerSquareType": m.centerSquareType, "isRandomized": false,
            "totalTasks": m.boardSize * m.boardSize, "completedTasks": 0,
            "linesCompleted": m.linesCompleted,
            "createdAt": ts, "updatedAt": ts, "version": 1, "isDeleted": m.isDeleted,
        ]
        if let endDate = m.endDate { dict["endDate"] = endDate }
        if let ids = m.completedLineIds {
            dict["completedLineIds"] = String(data: try! JSONEncoder().encode(ids), encoding: .utf8)!
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func toTask(_ m: SealVector.MiniTask) -> Task {
        Task(
            id: m.id, userId: "u", title: m.id,
            type: TaskType(rawValue: m.type) ?? .normal,
            maxCount: m.maxCount,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: m.isCompleted,
            createdAt: ts, updatedAt: ts, version: 1, isDeleted: m.isDeleted,
            sharedCounterId: m.sharedCounterId
        )
    }

    private func toBoardTask(_ m: SealVector.MiniBoardTask, boardId: String) -> BoardTask {
        BoardTask(
            id: "\(boardId)-\(m.taskId)", boardId: boardId, taskId: m.taskId,
            row: m.row, col: m.col, isCenter: false,
            createdAt: ts, updatedAt: ts, version: 1
        )
    }

    private func toEvent(_ m: SealVector.MiniEvent) -> TaskEvent {
        TaskEvent(
            id: m.id, userId: "u", taskId: m.taskId,
            kind: TaskEventKind(rawValue: m.kind) ?? .completion,
            delta: m.delta, occurredAt: m.occurredAt, boardId: nil,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
            version: 1, isDeleted: m.isDeleted, deletedAt: nil
        )
    }

    func testComputeSealedCompletedCellsVectors() throws {
        let fixture = try loadFixture("sealReDerivationVectors", as: SealFixture.self)
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let board = toBoard(v.board)
            let boardTasks = v.boardTasks.map { toBoardTask($0, boardId: board.id) }
            var taskById: [String: Task] = [:]
            for t in v.tasks { taskById[t.id] = toTask(t) }

            var eventsByTaskId: [String: [TaskEvent]] = [:]
            for e in v.events { eventsByTaskId[e.taskId, default: []].append(toEvent(e)) }

            let cells = DerivationPass.computeSealedCompletedCells(
                board: board,
                boardTasksOnBoard: boardTasks,
                childrenByCompound: [:],
                taskById: taskById,
                allBoards: [board],
                windowContext: WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
            )
            XCTAssertEqual(cells, v.expectedCells, "Vector '\(v.name)' cells")
        }
    }
}
