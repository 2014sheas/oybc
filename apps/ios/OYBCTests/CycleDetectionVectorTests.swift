import XCTest
@testable import OYBC

/// Cross-platform achievement-cycle-detection enforcement (workstream C1 /
/// issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/cycleDetectionVectors.json`)
/// through iOS's `CycleDetection.hasCycle` in `Services/CycleDetection.swift`.
/// The SAME fixture is exercised on the shared/web side by
/// `packages/shared/tests/algorithms/cycleDetection.test.ts` against
/// `@oybc/shared`'s `cycleDetection.ts`. Both suites passing against the
/// same vectors is what proves the two hand-mirrored implementations agree,
/// not just an audit claim.
final class CycleDetectionVectorTests: XCTestCase {

    private struct MiniBoard: Decodable {
        let id: String
        let startDate: String
        let endDate: String
        let spawnedFromTemplateId: String?
        let isDeleted: Bool?
    }

    private struct MiniTask: Decodable {
        let id: String
        let type: String?
        let referencedBoardId: String?
        let referencedTemplateId: String?
        let isDeleted: Bool?
    }

    private struct MiniBoardTask: Decodable {
        let boardId: String
        let taskId: String
    }

    private struct Candidate: Decodable {
        let parentBoardIds: [String]
        let referencedBoardId: String?
        let referencedTemplateId: String?
    }

    private struct Expected: Decodable {
        let ok: Bool
        let cyclePathEquals: [String]?
        let cyclePathContains: [String]?
        let cyclePathFirst: String?
        let cyclePathLast: String?
    }

    private struct Vector: Decodable {
        let name: String
        let boards: [MiniBoard]
        let tasks: [MiniTask]
        let boardTasks: [MiniBoardTask]
        let candidate: Candidate
        let expected: Expected
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private let ts = "2026-04-23T00:00:00.000Z"

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CycleDetectionVectorTests.self).url(
            forResource: "cycleDetectionVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "cycleDetectionVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toBoard(_ m: MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id,
            "userId": "u",
            "name": m.id,
            "status": "active",
            "boardSize": 3,
            "timeframe": "monthly",
            "startDate": m.startDate,
            "endDate": m.endDate,
            "centerSquareType": "none",
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "completedLineIds": "[]",
            "createdAt": ts,
            "updatedAt": ts,
            "version": 1,
            "isDeleted": m.isDeleted ?? false,
        ]
        if let tid = m.spawnedFromTemplateId { dict["spawnedFromTemplateId"] = tid }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func toTask(_ m: MiniTask) -> Task {
        Task(
            id: m.id,
            userId: "u",
            title: m.id,
            type: TaskType(rawValue: m.type ?? "achievement") ?? .achievement,
            referencedBoardId: m.referencedBoardId,
            referencedTemplateId: m.referencedTemplateId,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted ?? false
        )
    }

    private func toBoardTask(_ m: MiniBoardTask, _ idx: Int) -> BoardTask {
        BoardTask(
            id: "bt-\(m.boardId)-\(m.taskId)-\(idx)",
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

    func testHasCycleVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let allBoards = v.boards.map(toBoard)
            let allTasks = v.tasks.map(toTask)
            let allBoardTasks = v.boardTasks.enumerated().map { toBoardTask($1, $0) }

            let candidate = CycleCheckCandidate(
                parentBoardIds: v.candidate.parentBoardIds,
                referencedBoardId: v.candidate.referencedBoardId,
                referencedTemplateId: v.candidate.referencedTemplateId
            )
            let context = CycleCheckContext(allBoardTasks: allBoardTasks, allTasks: allTasks, allBoards: allBoards)

            let result = CycleDetection.hasCycle(candidate: candidate, context: context)

            switch result {
            case .ok:
                XCTAssertTrue(v.expected.ok, "Vector '\(v.name)' expected cycle but got ok")
            case .cycle(let path):
                XCTAssertFalse(v.expected.ok, "Vector '\(v.name)' expected ok but got cycle \(path)")
                if let equals = v.expected.cyclePathEquals {
                    XCTAssertEqual(path, equals, "Vector '\(v.name)' cyclePath")
                }
                if let first = v.expected.cyclePathFirst {
                    XCTAssertEqual(path.first, first, "Vector '\(v.name)' cyclePath.first")
                }
                if let last = v.expected.cyclePathLast {
                    XCTAssertEqual(path.last, last, "Vector '\(v.name)' cyclePath.last")
                }
                if let contains = v.expected.cyclePathContains {
                    for id in contains {
                        XCTAssertTrue(path.contains(id), "Vector '\(v.name)' cyclePath should contain \(id)")
                    }
                }
            }
        }
    }
}
