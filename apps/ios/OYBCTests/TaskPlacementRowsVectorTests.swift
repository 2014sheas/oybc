import XCTest
@testable import OYBC

/// Task Detail PR 5 — `TaskPlacementRows.rows`, pinned by
/// `Fixtures/taskPlacementRowsVectors.json` (byte-identical to
/// `packages/shared/tests/fixtures/taskPlacementRowsVectors.json`). Twin of
/// `taskPlacementRows.test.ts`; defaults per the fixture's notes.
final class TaskPlacementRowsVectorTests: XCTestCase {
    private static let t0 = "2026-10-01T00:00:00.000Z"

    private struct Fixture: Decodable { let vectors: [Vector] }
    private struct ChildTarget: Decodable { let childId: String; let target: Double }
    private struct MiniBoardTask: Decodable {
        let id: String
        let boardId: String
        let taskId: String
        let row: Int
        let col: Int
        let targetOverride: Double?
        let targetKind: String?
        let childTargets: [ChildTarget]?
    }
    private struct MiniLink: Decodable { let id: String; let compoundTaskId: String; let childTaskId: String }
    private struct MiniEvent: Decodable { let taskId: String; let kind: String?; let delta: Double?; let occurredAt: String }
    private struct Expected: Decodable, Equatable {
        let boardId: String
        let boardTaskId: String
        let memberTaskId: String
        let viaCompoundId: String?
        let done: Bool
        let count: Double?
        let goal: Double?
        let childrenDone: Int?
        let childrenTotal: Int?
    }
    private struct Vector: Decodable {
        let name: String
        let taskId: String
        let boardTasks: [MiniBoardTask]
        let links: [MiniLink]
        let events: [MiniEvent]
        let expected: [Expected]
    }

    /// The raw `tasks` / `boards` arrays, decoded into the models over the fixture's defaults.
    private func rawVectors(_ data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["vectors"] as? [[String: Any]])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func task(_ raw: [String: Any]) throws -> Task {
        var dict: [String: Any] = [
            "userId": "u", "isCompleted": false, "isDeleted": false, "version": 1,
            "createdAt": Self.t0, "updatedAt": Self.t0, "totalCompletions": 0, "totalInstances": 0,
        ]
        dict["title"] = raw["id"]
        for (k, v) in raw { dict[k] = v }
        return try decode(Task.self, dict)
    }

    private func board(_ raw: [String: Any]) throws -> Board {
        var dict: [String: Any] = [
            "userId": "u", "status": "active", "boardSize": 3, "timeframe": "weekly", "centerSquareType": "none",
            "isRandomized": false, "isDeleted": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": Self.t0, "updatedAt": Self.t0, "version": 1,
        ]
        dict["name"] = raw["id"]
        for (k, v) in raw where k != "sealedCompletedCells" { dict[k] = v }
        var b = try decode(Board.self, dict)
        b.sealedCompletedCells = raw["sealedCompletedCells"] as? [Int]
        return b
    }

    func testTaskPlacementRows_matchTheSharedVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "taskPlacementRowsVectors", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let raws = try rawVectors(data)
        XCTAssertEqual(fixture.vectors.count, 11)

        for (v, raw) in zip(fixture.vectors, raws) {
            let tasks = try XCTUnwrap(raw["tasks"] as? [[String: Any]]).map(task)
            let boards = try XCTUnwrap(raw["boards"] as? [[String: Any]]).map(board)
            let boardTasks = v.boardTasks.map { m in
                BoardTask(
                    id: m.id, boardId: m.boardId, taskId: m.taskId, row: m.row, col: m.col, isCenter: false,
                    targetOverride: m.targetOverride, targetKind: m.targetKind.flatMap(CountKind.init(rawValue:)),
                    childTargets: m.childTargets?.map { PlacementChildTarget(childId: $0.childId, target: $0.target) },
                    createdAt: Self.t0, updatedAt: Self.t0, version: 1
                )
            }
            var index: [String: Int] = [:]
            let links = v.links.map { l -> CompoundChild in
                let i = index[l.compoundTaskId, default: 0]
                index[l.compoundTaskId] = i + 1
                return CompoundChild(
                    id: l.id, compoundTaskId: l.compoundTaskId, childTaskId: l.childTaskId, childIndex: i,
                    createdAt: Self.t0, updatedAt: Self.t0, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                )
            }
            let events = v.events.enumerated().map { i, e in
                TaskEvent(
                    id: "e\(i)", userId: "u", taskId: e.taskId, kind: TaskEventKind(rawValue: e.kind ?? "increment") ?? .increment,
                    delta: e.delta, occurredAt: e.occurredAt, boardId: nil, createdAt: e.occurredAt, updatedAt: e.occurredAt,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                )
            }
            let reach = DerivationPass.placementsReachedByTasks(
                ids: [v.taskId], tasks: tasks, compoundChildren: links, boardTasks: boardTasks
            )
            let got = TaskPlacementRows.rows(
                taskId: v.taskId,
                reach: reach.placements,
                boardsById: Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) }),
                taskById: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }),
                childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId),
                eventsByTaskId: Dictionary(grouping: events, by: \.taskId),
                boardTasksByBoard: Dictionary(grouping: boardTasks, by: \.boardId),
                allBoards: boards
            ).map {
                Expected(
                    boardId: $0.boardId, boardTaskId: $0.boardTaskId, memberTaskId: $0.memberTaskId,
                    viaCompoundId: $0.viaCompoundId, done: $0.done, count: $0.count, goal: $0.goal,
                    childrenDone: $0.childrenDone, childrenTotal: $0.childrenTotal
                )
            }
            XCTAssertEqual(got, v.expected, v.name)
        }
    }
}
