import XCTest
@testable import OYBC

/// Cross-platform derivation-pass enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/derivationPassVectors.json`)
/// through iOS's `DerivationPass.findTransitiveParentCompounds` /
/// `findAffectedBoardIds` / `computeBoardStatsUpdate` in
/// `Services/DerivationPass.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/derivationPass.test.ts`
/// against `@oybc/shared`'s `derivationPass.ts`. Both suites passing against
/// the same vectors is what proves the two hand-mirrored implementations
/// agree, not just an audit claim.
final class DerivationPassVectorTests: XCTestCase {

    private let ts = "2026-04-23T00:00:00.000Z"

    // MARK: - Fixture shapes

    private struct MiniChild: Decodable {
        let compoundTaskId: String
        let childTaskId: String
        let isDeleted: Bool
    }

    private struct FtpcVector: Decodable {
        let name: String
        let changedTaskId: String
        let children: [MiniChild]
        let expected: [String]
    }

    private struct MiniBoardTaskRef: Decodable {
        let boardId: String
        let taskId: String
    }

    private struct FabiVector: Decodable {
        let name: String
        let changedTaskId: String
        let parentCompounds: [String]
        let boardTasks: [MiniBoardTaskRef]
        let expected: [String]
    }

    private struct MiniTask: Decodable {
        let id: String
        let type: String
        let isCompleted: Bool
        let isDeleted: Bool
        let operatorField: String?
        let threshold: Int?
        let referencedBoardId: String?
        let referencedTemplateId: String?
        let achievementTrigger: String?
        let requiredCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, type, isCompleted, isDeleted, threshold
            case operatorField = "operator"
            case referencedBoardId, referencedTemplateId, achievementTrigger, requiredCount
        }
    }

    private struct MiniBoardTaskFull: Decodable {
        let taskId: String
        let row: Int
        let col: Int
    }

    private struct MiniBoard: Decodable {
        let id: String
        let boardSize: Int
        let centerSquareType: String
        let startDate: String
        let endDate: String?
        let status: String
        let linesCompleted: Int
        let completedLineIds: [String]?
        let isDeleted: Bool
        let spawnedFromTemplateId: String?
    }

    private struct ExpectedStats: Decodable {
        let boardId: String
        let completedTasks: Int
        let linesCompleted: Int
        let completedLineIds: [String]
        let newBingos: [String]
        let lostBingos: [String]
    }

    private struct CbsuVector: Decodable {
        let name: String
        let board: MiniBoard
        let boardTasksOnBoard: [MiniBoardTaskFull]
        let childrenByCompound: [String: [MiniChild]]
        let taskById: [String: MiniTask]
        let allBoards: [MiniBoard]
        let expected: ExpectedStats
    }

    private struct Fixture: Decodable {
        let findTransitiveParentCompounds: [FtpcVector]
        let findAffectedBoardIds: [FabiVector]
        let computeBoardStatsUpdate: [CbsuVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: DerivationPassVectorTests.self).url(
            forResource: "derivationPassVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "derivationPassVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // MARK: - Converters

    private func toChild(_ m: MiniChild, _ idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(m.compoundTaskId)-\(m.childTaskId)-\(idx)",
            compoundTaskId: m.compoundTaskId,
            childTaskId: m.childTaskId,
            childIndex: idx,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted
        )
    }

    private func toBoardTaskRef(_ m: MiniBoardTaskRef, _ idx: Int) -> BoardTask {
        BoardTask(
            id: "\(m.boardId)-\(m.taskId)-\(idx)",
            boardId: m.boardId,
            taskId: m.taskId,
            row: 0,
            col: idx,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    private func toTask(_ m: MiniTask) -> Task {
        Task(
            id: m.id,
            userId: "u",
            title: m.id,
            type: TaskType(rawValue: m.type) ?? .normal,
            operatorType: m.operatorField.flatMap { OperatorType(rawValue: $0) },
            threshold: m.threshold,
            referencedBoardId: m.referencedBoardId,
            referencedTemplateId: m.referencedTemplateId,
            achievementTrigger: m.achievementTrigger.flatMap { AchievementTrigger(rawValue: $0) },
            requiredCount: m.requiredCount,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: m.isCompleted,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted
        )
    }

    private func toBoardTaskFull(_ m: MiniBoardTaskFull, boardId: String) -> BoardTask {
        BoardTask(
            id: "\(boardId)-\(m.taskId)",
            boardId: boardId,
            taskId: m.taskId,
            row: m.row,
            col: m.col,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    private func toBoard(_ m: MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id,
            "userId": "u",
            "name": m.id,
            "status": m.status,
            "boardSize": m.boardSize,
            "timeframe": "monthly",
            "startDate": m.startDate,
            "centerSquareType": m.centerSquareType,
            "isRandomized": false,
            "totalTasks": m.boardSize * m.boardSize,
            "completedTasks": 0,
            "linesCompleted": m.linesCompleted,
            "createdAt": ts,
            "updatedAt": ts,
            "version": 1,
            "isDeleted": m.isDeleted,
        ]
        if let endDate = m.endDate { dict["endDate"] = endDate }
        if let ids = m.completedLineIds {
            let jsonData = try! JSONEncoder().encode(ids)
            dict["completedLineIds"] = String(data: jsonData, encoding: .utf8)!
        }
        if let tid = m.spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Tests

    func testFindTransitiveParentCompoundsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.findTransitiveParentCompounds.isEmpty)
        for v in fixture.findTransitiveParentCompounds {
            let children = v.children.enumerated().map { toChild($1, $0) }
            let result = DerivationPass.findTransitiveParentCompounds(changedTaskId: v.changedTaskId, children: children)
            XCTAssertEqual(result, Set(v.expected), "Vector '\(v.name)'")
        }
    }

    func testFindAffectedBoardIdsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.findAffectedBoardIds.isEmpty)
        for v in fixture.findAffectedBoardIds {
            let boardTasks = v.boardTasks.enumerated().map { toBoardTaskRef($1, $0) }
            let result = DerivationPass.findAffectedBoardIds(
                changedTaskId: v.changedTaskId, parentCompounds: Set(v.parentCompounds), boardTasks: boardTasks
            )
            XCTAssertEqual(result, Set(v.expected), "Vector '\(v.name)'")
        }
    }

    func testComputeBoardStatsUpdateVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.computeBoardStatsUpdate.isEmpty)
        for v in fixture.computeBoardStatsUpdate {
            let board = toBoard(v.board)
            let boardTasksOnBoard = v.boardTasksOnBoard.map { toBoardTaskFull($0, boardId: board.id) }

            var childrenByCompound: [String: [CompoundChild]] = [:]
            for (key, children) in v.childrenByCompound {
                childrenByCompound[key] = children.enumerated().map { toChild($1, $0) }
            }

            var taskById: [String: Task] = [:]
            for (key, t) in v.taskById { taskById[key] = toTask(t) }

            let allBoards = v.allBoards.map(toBoard)

            let result = DerivationPass.computeBoardStatsUpdate(
                board: board, boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound, taskById: taskById, allBoards: allBoards
            )

            XCTAssertEqual(result.boardId, v.expected.boardId, "Vector '\(v.name)' boardId")
            XCTAssertEqual(result.completedTasks, v.expected.completedTasks, "Vector '\(v.name)' completedTasks")
            XCTAssertEqual(result.linesCompleted, v.expected.linesCompleted, "Vector '\(v.name)' linesCompleted")
            XCTAssertEqual(result.completedLineIds, v.expected.completedLineIds, "Vector '\(v.name)' completedLineIds")
            XCTAssertEqual(result.newBingos, v.expected.newBingos, "Vector '\(v.name)' newBingos")
            XCTAssertEqual(result.lostBingos, v.expected.lostBingos, "Vector '\(v.name)' lostBingos")
        }
    }
}
