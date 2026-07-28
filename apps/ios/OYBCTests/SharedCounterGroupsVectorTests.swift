import XCTest
@testable import OYBC

/// Cross-platform shared-counter-groups enforcement (workstream C1 /
/// issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/sharedCounterGroupsVectors.json`)
/// through iOS's `buildSharedCounterGroups` in `Helpers/SharedCounterGroups.swift`.
/// The SAME fixture is exercised on the shared/web side by
/// `packages/shared/tests/algorithms/sharedCounterGroups.test.ts` against
/// `@oybc/shared`'s `sharedCounterGroups.ts`. Both suites passing against
/// the same vectors is what proves the two hand-mirrored implementations
/// agree, not just an audit claim.
final class SharedCounterGroupsVectorTests: XCTestCase {

    private let ts = "2026-02-01T12:00:00.000Z"

    private struct MiniTask: Decodable {
        let id: String
        let title: String
        let currentCount: Int?
        let maxCount: Int?
        let sharedCounterId: String?
        let baseline: Int?
        let isDeleted: Bool
        /// P5 hub-born-counter flag. Optional in the JSON — absent/false on
        /// the core 11 vectors; extend with `decodeIfPresent ?? false` since
        /// the Swift `Task.isCounter` field is non-optional.
        let isCounter: Bool

        private enum CodingKeys: String, CodingKey {
            case id, title, currentCount, maxCount, sharedCounterId, baseline, isDeleted, isCounter
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            currentCount = try container.decodeIfPresent(Int.self, forKey: .currentCount)
            maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount)
            sharedCounterId = try container.decodeIfPresent(String.self, forKey: .sharedCounterId)
            baseline = try container.decodeIfPresent(Int.self, forKey: .baseline)
            isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
            isCounter = try container.decodeIfPresent(Bool.self, forKey: .isCounter) ?? false
        }
    }

    private struct MiniBoard: Decodable {
        let id: String
        let name: String
        let status: String
        let isDeleted: Bool
    }

    private struct MiniBoardTask: Decodable {
        let taskId: String
        let boardId: String
    }

    private struct MiniMemberTask: Decodable {
        let taskId: String
        let isSource: Bool
        let boardId: String?
        let boardName: String?
        let goal: Int
        let logged: Int
        let met: Bool
        let over: Int
        let isActive: Bool
    }

    private struct MiniGroup: Decodable {
        let counterId: String
        let name: String
        let lifetime: Int
        let taskCount: Int
        let boardCount: Int
        let activeTaskCount: Int
        let tasks: [MiniMemberTask]
    }

    private struct Vector: Decodable {
        let name: String
        let tasks: [MiniTask]
        let boards: [MiniBoard]
        let boardTasks: [MiniBoardTask]
        let expected: [MiniGroup]
    }

    private struct Fixture: Decodable {
        let vectors: [Vector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: SharedCounterGroupsVectorTests.self).url(
            forResource: "sharedCounterGroupsVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "sharedCounterGroupsVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func toTask(_ m: MiniTask) -> Task {
        Task(
            id: m.id,
            userId: "u1",
            title: m.title,
            type: .counting,
            // R1 (pair-derived counter names): intentionally left nil. These
            // fixture vectors predate pair-derived naming and were authored
            // to assert on `title`; leaving action/unit nil means
            // `CounterName.formatCounterName(nil, nil) == ""`, so
            // `buildSharedCounterGroups`'s `name` falls back to the stored
            // `title` — every vector's `expected.name` stays exactly what it
            // was pre-R1. Pair-derivation itself is covered by
            // `CounterNameTests` and the dedicated pair-derived-name cases in
            // `SharedCounterGroupsTests`. Mirrors the TS fixture-driven
            // test's `toTask` (packages/shared/tests/algorithms/
            // sharedCounterGroups.test.ts), which leaves action/unit
            // undefined for the same reason.
            action: nil,
            unit: nil,
            maxCount: m.maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            currentCount: m.currentCount,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted,
            sharedCounterId: m.sharedCounterId,
            baseline: m.baseline,
            isCounter: m.isCounter
        )
    }

    private func toBoard(_ m: MiniBoard) -> Board {
        let dict: [String: Any] = [
            "id": m.id,
            "userId": "u1",
            "name": m.name,
            "status": m.status,
            "boardSize": 5,
            "timeframe": "weekly",
            "startDate": ts,
            "endDate": "2026-02-07T12:00:00.000Z",
            "centerSquareType": "free",
            "isRandomized": false,
            "totalTasks": 25,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": ts,
            "updatedAt": ts,
            "version": 1,
            "isDeleted": m.isDeleted,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func toBoardTask(_ m: MiniBoardTask) -> BoardTask {
        BoardTask(
            id: "bt-\(m.taskId)-\(m.boardId)",
            boardId: m.boardId,
            taskId: m.taskId,
            row: 0,
            col: 0,
            isCenter: false,
            createdAt: ts,
            updatedAt: ts,
            version: 1
        )
    }

    func testBuildSharedCounterGroupsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            let groups = buildSharedCounterGroups(
                tasks: v.tasks.map(toTask),
                boardTasks: v.boardTasks.map(toBoardTask),
                boards: v.boards.map(toBoard)
            )

            XCTAssertEqual(groups.count, v.expected.count, "Vector '\(v.name)' group count")
            for (i, g) in groups.enumerated() where i < v.expected.count {
                let exp = v.expected[i]
                XCTAssertEqual(g.counterId, exp.counterId, "Vector '\(v.name)' group[\(i)].counterId")
                XCTAssertEqual(g.name, exp.name, "Vector '\(v.name)' group[\(i)].name")
                XCTAssertEqual(g.lifetime, exp.lifetime, "Vector '\(v.name)' group[\(i)].lifetime")
                XCTAssertEqual(g.taskCount, exp.taskCount, "Vector '\(v.name)' group[\(i)].taskCount")
                XCTAssertEqual(g.boardCount, exp.boardCount, "Vector '\(v.name)' group[\(i)].boardCount")
                XCTAssertEqual(g.activeTaskCount, exp.activeTaskCount, "Vector '\(v.name)' group[\(i)].activeTaskCount")
                XCTAssertEqual(g.tasks.count, exp.tasks.count, "Vector '\(v.name)' group[\(i)].tasks.count")
                for (j, m) in g.tasks.enumerated() where j < exp.tasks.count {
                    let expMember = exp.tasks[j]
                    XCTAssertEqual(m.taskId, expMember.taskId, "Vector '\(v.name)' [\(i)][\(j)].taskId")
                    XCTAssertEqual(m.isSource, expMember.isSource, "Vector '\(v.name)' [\(i)][\(j)].isSource")
                    XCTAssertEqual(m.boardId, expMember.boardId, "Vector '\(v.name)' [\(i)][\(j)].boardId")
                    XCTAssertEqual(m.boardName, expMember.boardName, "Vector '\(v.name)' [\(i)][\(j)].boardName")
                    XCTAssertEqual(m.goal, expMember.goal, "Vector '\(v.name)' [\(i)][\(j)].goal")
                    XCTAssertEqual(m.logged, expMember.logged, "Vector '\(v.name)' [\(i)][\(j)].logged")
                    XCTAssertEqual(m.met, expMember.met, "Vector '\(v.name)' [\(i)][\(j)].met")
                    XCTAssertEqual(m.over, expMember.over, "Vector '\(v.name)' [\(i)][\(j)].over")
                    XCTAssertEqual(m.isActive, expMember.isActive, "Vector '\(v.name)' [\(i)][\(j)].isActive")
                }
            }
        }
    }
}
