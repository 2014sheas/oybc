import XCTest
@testable import OYBC

/// Cross-platform pin for the replay kernel (Swift twin of
/// `packages/shared/src/algorithms/boardMoment.ts`), driven by the checked-in
/// copy of `boardMomentVectors.json` — the same fixture
/// `packages/shared/tests/algorithms/boardMoment.test.ts` runs
/// (docs/BOARD_MOMENTS.md). Asserts the landing order, FREE index, line
/// closure beats, rail numbers, final beats, and per-frame counter /
/// landed / green / popToken for every cell.
final class BoardMomentVectorTests: XCTestCase {

    // MARK: Fixture shape

    private struct MiniTask: Decodable {
        let id: String
        let title: String?
        let type: String?
        let operatorField: String?
        let threshold: Int?
        let maxCount: Double?
        let referencedBoardId: String?
        let achievementTrigger: String?
        let isCompleted: Bool?
        let completedAt: String?
        let isDeleted: Bool?
        let createdAt: String?
        let sharedCounterId: String?
        let startDate: String?
        let endDate: String?
        let createdInWizard: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, type, threshold, maxCount, referencedBoardId, achievementTrigger
            case isCompleted, completedAt, isDeleted, createdAt
            case sharedCounterId, startDate, endDate, createdInWizard
            case operatorField = "operator"
        }

        var task: Task {
            Task(
                id: id, userId: "u", title: title ?? id, type: TaskType(rawValue: type ?? "normal") ?? .normal,
                maxCount: maxCount, operatorType: operatorField.flatMap { OperatorType(rawValue: $0) },
                threshold: threshold, referencedBoardId: referencedBoardId,
                achievementTrigger: achievementTrigger.flatMap { AchievementTrigger(rawValue: $0) },
                totalCompletions: 0, totalInstances: 0,
                isCompleted: isCompleted ?? false, completedAt: completedAt,
                createdAt: createdAt ?? "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                version: 1, isDeleted: isDeleted ?? false,
                startDate: startDate, endDate: endDate, sharedCounterId: sharedCounterId,
                createdInWizard: createdInWizard ?? false
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

    private struct MiniPlacement: Decodable {
        let id: String
        let taskId: String
        let row: Int
        let col: Int
        let isDeleted: Bool?
    }

    private struct MiniBoard: Decodable {
        let id: String
        let size: Int?
        let centerSquareType: String?
        let startDate: String
        let endDate: String?
        let completedTasks: Int?
        let completedLineIds: [String]?
        let sealedAt: String?
        let sealedCompletedCells: [Int]?
        let status: String?
        let linesCompleted: Int?

        var board: Board {
            let n = size ?? 3
            func json<T: Encodable>(_ v: T) -> String { String(data: try! JSONEncoder().encode(v), encoding: .utf8)! }
            var dict: [String: Any] = [
                "id": id, "userId": "u", "name": id, "status": status ?? BoardStatus.active.rawValue,
                "boardSize": n, "timeframe": Timeframe.custom.rawValue, "startDate": startDate,
                "centerSquareType": centerSquareType ?? CenterSquareType.none.rawValue, "isRandomized": false,
                "totalTasks": n * n, "completedTasks": completedTasks ?? 0,
                "linesCompleted": linesCompleted ?? completedLineIds?.count ?? 0,
                "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z",
                "version": 1, "isDeleted": false,
            ]
            if let endDate { dict["endDate"] = endDate }
            if let completedLineIds { dict["completedLineIds"] = json(completedLineIds) }
            if let sealedAt { dict["sealedAt"] = sealedAt }
            if let sealedCompletedCells { dict["sealedCompletedCells"] = json(sealedCompletedCells) }
            let data = try! JSONSerialization.data(withJSONObject: dict)
            return try! JSONDecoder().decode(Board.self, from: data)
        }
    }

    private struct Entry: Decodable { let boardTaskId: String; let idx: Int; let completedAt: String? }
    private struct FinalBeat: Decodable { let bingo: Int; let greenlog: Int }
    private struct Expected: Decodable {
        let order: [Entry]
        let freeIdx: Int?
        let lineClosureBeat: [String: Int]
        let completedTasks: Int
        let totalTasks: Int
        let size: Int
        let finalBeat: FinalBeat
    }
    private struct Frame: Decodable {
        let kind: String
        let beat: Int
        let counter: Int
        let landed: [Int]
        let green: [Int]
        let popTokens: [String: Int]
    }
    private struct Case: Decodable {
        let name: String
        let board: MiniBoard
        let tasks: [MiniTask]
        let children: [MiniLink]?
        let boardTasks: [MiniPlacement]
        let allBoards: [MiniBoard]?
        let events: [MiniEvent]
        let expected: Expected
        let frames: [Frame]
    }
    private struct PosterCaseCell: Decodable {
        let idx: Int
        let label: String
        let type: String
        let isFree: Bool
        let state: String?
    }
    private struct PosterReplay: Decodable {
        let order: [Entry]
        let freeIdx: Int?
        let lineClosureBeat: [String: Int]
        let completedTasks: Int
        let totalTasks: Int
        let size: Int
    }
    private struct PosterCase: Decodable {
        let name: String
        let kind: String
        let replay: PosterReplay
        let cells: [PosterCaseCell]
        let expected: [PosterCaseCell]
    }
    private struct Fixture: Decodable {
        let cases: [Case]
        let posterCells: [PosterCase]
    }

    private func load() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "boardMomentVectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func replay(for c: Case) -> BoardMomentReplay {
        let board = c.board.board
        let taskRows = c.tasks.map(\.task)
        var byCompound: [String: [CompoundChild]] = [:]
        for (i, l) in (c.children ?? []).enumerated() where !(l.isDeleted ?? false) {
            byCompound[l.compoundTaskId, default: []].append(CompoundChild(
                id: "l\(i)", compoundTaskId: l.compoundTaskId, childTaskId: l.childTaskId, childIndex: i,
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ))
        }
        var events: [String: [TaskEvent]] = [:]
        for (i, m) in c.events.enumerated() where !(m.isDeleted ?? false) {
            let e = m.event(i)
            events[e.taskId, default: []].append(e)
        }
        let placements = c.boardTasks.map {
            BoardTask(
                id: $0.id, boardId: board.id, taskId: $0.taskId, row: $0.row, col: $0.col, isCenter: false,
                createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
                version: 1, isDeleted: $0.isDeleted ?? false
            )
        }
        return computeBoardMomentReplay(
            board: board, boardTasks: placements, childrenByCompound: byCompound,
            taskById: Dictionary(uniqueKeysWithValues: taskRows.map { ($0.id, $0) }),
            eventsByTaskId: events, allBoards: (c.allBoards ?? []).map(\.board)
        )
    }

    // MARK: Tests

    func test_fixtureCoversEveryCase() throws {
        XCTAssertGreaterThanOrEqual(try load().cases.count, 13)
    }

    func test_replayMatchesVectors() throws {
        for c in try load().cases {
            let r = replay(for: c)
            let e = c.expected
            XCTAssertEqual(r.order.map(\.boardTaskId), e.order.map(\.boardTaskId), "\(c.name): order ids")
            XCTAssertEqual(r.order.map(\.idx), e.order.map(\.idx), "\(c.name): order idx")
            XCTAssertEqual(r.order.map(\.completedAt), e.order.map(\.completedAt), "\(c.name): order instants")
            XCTAssertEqual(r.freeIdx, e.freeIdx, "\(c.name): freeIdx")
            XCTAssertEqual(r.lineClosureBeat, e.lineClosureBeat, "\(c.name): lineClosureBeat")
            XCTAssertEqual(r.completedTasks, e.completedTasks, "\(c.name): completedTasks")
            XCTAssertEqual(r.totalTasks, e.totalTasks, "\(c.name): totalTasks")
            XCTAssertEqual(r.size, e.size, "\(c.name): size")
            XCTAssertEqual(momentFinalBeat(r, kind: .bingo), e.finalBeat.bingo, "\(c.name): final beat (bingo)")
            XCTAssertEqual(momentFinalBeat(r, kind: .greenlog), e.finalBeat.greenlog, "\(c.name): final beat (greenlog)")
        }
    }

    func test_framesMatchVectors() throws {
        for c in try load().cases {
            let r = replay(for: c)
            for f in c.frames {
                let kind: MomentTrigger.Kind = f.kind == "greenlog" ? .greenlog : .bingo
                let tag = "\(c.name) \(f.kind)@\(f.beat)"
                XCTAssertEqual(momentCounterAt(f.beat, replay: r), f.counter, "\(tag): counter")
                var landed: [Int] = [], green: [Int] = [], tokens: [String: Int] = [:]
                for idx in 0..<(r.size * r.size) {
                    let v = momentCellVisual(idx: idx, beat: f.beat, replay: r, kind: kind)
                    if v.landed { landed.append(idx) }
                    if v.green { green.append(idx) }
                    if let t = v.popToken { tokens["\(idx)"] = t }
                }
                XCTAssertEqual(landed, f.landed, "\(tag): landed")
                XCTAssertEqual(green, f.green, "\(tag): green")
                XCTAssertEqual(tokens, f.popTokens, "\(tag): popTokens")
            }
        }
    }

    func test_posterCellsMatchVectors() throws {
        let cases = try load().posterCells
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        func type(_ s: String) -> CellTaskType {
            switch s {
            case "counting": return .counting
            case "compound": return .compound
            case "achievement": return .achievement
            default: return .normal
            }
        }
        for c in cases {
            let r = BoardMomentReplay(
                order: c.replay.order.map { MomentOrderEntry(boardTaskId: $0.boardTaskId, idx: $0.idx, completedAt: $0.completedAt) },
                freeIdx: c.replay.freeIdx, lineClosureBeat: c.replay.lineClosureBeat,
                completedTasks: c.replay.completedTasks, totalTasks: c.replay.totalTasks, size: c.replay.size
            )
            let kind: MomentTrigger.Kind = c.kind == "greenlog" ? .greenlog : .bingo
            let inputs = c.cells.map { PosterCellInput(idx: $0.idx, label: $0.label, type: type($0.type), isFree: $0.isFree) }
            let got = momentPosterCells(replay: r, cells: inputs, kind: kind)
            XCTAssertEqual(got.map(\.idx), c.expected.map(\.idx), "\(c.name): idx")
            XCTAssertEqual(got.map(\.label), c.expected.map(\.label), "\(c.name): label")
            XCTAssertEqual(got.map(\.isFree), c.expected.map(\.isFree), "\(c.name): isFree")
            XCTAssertEqual(got.map(\.type), c.expected.map { type($0.type) }, "\(c.name): type")
            XCTAssertEqual(got.map(\.state.rawValue), c.expected.map { $0.state ?? "" }, "\(c.name): state")
        }
    }
}
