import XCTest
@testable import OYBC

/// `TaskDetailKernel` — hero anchor, next sub-task and the Activity feed,
/// pinned by `taskDetailVectors.json` (TS twin: `taskDetail.test.ts`).
final class TaskDetailKernelTests: XCTestCase {

    private struct BoardV: Decodable {
        let id: String; let status: String; let timeframe: String
        let endDate: String?; let sealedAt: String?; let isDeleted: Bool?; let updatedAt: String
    }
    private struct AnchorV: Decodable { let name: String; let now: String; let boards: [BoardV]; let expected: String? }
    private struct ChildV: Decodable { let id: String; let type: TaskType; let isCompleted: Bool }
    private struct ActionV: Decodable { let kind: String; let childId: String }
    private struct NextV: Decodable { let name: String; let children: [ChildV]; let expected: ActionV? }
    private struct EventV: Decodable {
        let id: String; let kind: TaskEventKind; let delta: Double?; let occurredAt: String
        let boardId: String?; let isDeleted: Bool?
    }
    private struct PlacementV: Decodable { let id: String; let boardId: String; let createdAt: String; let isDeleted: Bool? }
    private struct MissedV: Decodable { let boardId: String; let endDate: String }
    private struct TaskV: Decodable { let id: String; let createdAt: String; let unit: String? }
    private struct InputV: Decodable {
        let task: TaskV; let kind: CountKind; let events: [EventV]; let placements: [PlacementV]
        let missed: [MissedV]; let boardNames: [String: String]
    }
    private struct RowV: Decodable { let key: String; let kind: String; let at: String; let text: String }
    private struct ExpectedV: Decodable { let rows: [RowV]; let completionCount: Int }
    private struct ActivityV: Decodable { let name: String; let input: InputV; let expected: ExpectedV }
    private struct LineV: Decodable { let cells: [Int]; let done: Int }
    private struct ClosestV: Decodable { let name: String; let gridSize: Int; let grid: [Bool]; let expected: LineV? }
    private struct Fixture: Decodable {
        let heroAnchor: [AnchorV]; let nextSubtask: [NextV]; let activity: [ActivityV]; let closestLine: [ClosestV]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "taskDetailVectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func board(_ v: BoardV) -> Board {
        var dict: [String: Any] = [
            "id": v.id, "userId": "u1", "name": v.id, "status": v.status,
            "boardSize": 3, "timeframe": v.timeframe, "startDate": "2026-01-01T00:00:00Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": v.updatedAt, "updatedAt": v.updatedAt, "version": 1, "isDeleted": v.isDeleted ?? false,
        ]
        if let e = v.endDate { dict["endDate"] = e }
        if let s = v.sealedAt { dict["sealedAt"] = s }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    func testHeroAnchorVectors() throws {
        for v in try fixture().heroAnchor {
            let now = try XCTUnwrap(parseISO8601Date(v.now))
            XCTAssertEqual(TaskDetailKernel.heroAnchorBoard(v.boards.map(board), now: now)?.id, v.expected, v.name)
        }
    }

    func testNextSubtaskVectors() throws {
        for v in try fixture().nextSubtask {
            let got = TaskDetailKernel.nextSubtask(v.children.map { .init(id: $0.id, type: $0.type, isCompleted: $0.isCompleted) })
            let want: TaskDetailKernel.SubtaskAction? = v.expected.map {
                $0.kind == "toggle" ? .toggle(childId: $0.childId) : .log(childId: $0.childId)
            }
            XCTAssertEqual(got, want, v.name)
        }
    }

    func testActivityVectors() throws {
        for v in try fixture().activity {
            let i = v.input
            let events = i.events.map {
                TaskEvent(id: $0.id, userId: "u1", taskId: i.task.id, kind: $0.kind, delta: $0.delta,
                          occurredAt: $0.occurredAt, boardId: $0.boardId, createdAt: $0.occurredAt,
                          updatedAt: $0.occurredAt, lastSyncedAt: nil, version: 1,
                          isDeleted: $0.isDeleted ?? false, deletedAt: nil)
            }
            let placements = i.placements.map {
                BoardTask(id: $0.id, boardId: $0.boardId, taskId: i.task.id, row: 0, col: 0, isCenter: false,
                          createdAt: $0.createdAt, updatedAt: $0.createdAt, version: 1, isDeleted: $0.isDeleted ?? false)
            }
            let got = TaskDetailKernel.activity(
                taskId: i.task.id, createdAt: i.task.createdAt, unit: i.task.unit, kind: i.kind,
                events: events, placements: placements,
                missed: i.missed.map { .init(boardId: $0.boardId, endDate: $0.endDate) },
                boardNames: i.boardNames
            )
            XCTAssertEqual(got.completionCount, v.expected.completionCount, v.name)
            XCTAssertEqual(got.rows.map(\.key), v.expected.rows.map(\.key), v.name)
            XCTAssertEqual(got.rows.map(\.kind.rawValue), v.expected.rows.map(\.kind), v.name)
            XCTAssertEqual(got.rows.map(\.at), v.expected.rows.map(\.at), v.name)
            XCTAssertEqual(got.rows.map(\.text), v.expected.rows.map(\.text), v.name)
        }
    }

    func testClosestLineVectors() throws {
        for v in try fixture().closestLine {
            let got = TaskDetailKernel.closestLine(v.grid, gridSize: v.gridSize)
            XCTAssertEqual(got?.cells, v.expected?.cells, v.name)
            XCTAssertEqual(got?.done, v.expected?.done, v.name)
        }
    }
}
