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
        let currentCount: CountValue?
        let maxCount: CountValue?
        let sharedCounterId: String?
        let baseline: CountValue?
        let isDeleted: Bool
        /// P5 hub-born-counter flag. Optional in the JSON — absent/false on
        /// the core 11 vectors; extend with `decodeIfPresent ?? false` since
        /// the Swift `Task.isCounter` field is non-optional.
        let isCounter: Bool
        /// Window-stamped derived member fields — optional (Task 3 vectors).
        let startDate: String?
        let endDate: String?
        let createdInWizard: Bool
        let countKind: CountKind?
        /// Slice 2b — `"compound"` builds a parent compound; default counting.
        let type: String?

        private enum CodingKeys: String, CodingKey {
            case id, title, currentCount, maxCount, sharedCounterId, baseline, isDeleted, isCounter
            case startDate, endDate, createdInWizard, countKind, type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            currentCount = try container.decodeIfPresent(CountValue.self, forKey: .currentCount)
            maxCount = try container.decodeIfPresent(CountValue.self, forKey: .maxCount)
            sharedCounterId = try container.decodeIfPresent(String.self, forKey: .sharedCounterId)
            baseline = try container.decodeIfPresent(CountValue.self, forKey: .baseline)
            isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
            isCounter = try container.decodeIfPresent(Bool.self, forKey: .isCounter) ?? false
            startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
            endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
            createdInWizard = try container.decodeIfPresent(Bool.self, forKey: .createdInWizard) ?? false
            countKind = try container.decodeIfPresent(CountKind.self, forKey: .countKind)
            type = try container.decodeIfPresent(String.self, forKey: .type)
        }
    }

    private struct MiniBoard: Decodable {
        let id: String
        let name: String
        let status: String
        let isDeleted: Bool
        /// Optional — a sealed board's seal instant.
        let sealedAt: String?
        /// Optional own window (slice 0: a placed member reads its board's
        /// window). `hasEndDate` distinguishes an absent key (shared default)
        /// from an explicit `null` (open-ended).
        let startDate: String?
        let endDate: String?
        let hasEndDate: Bool

        private enum CodingKeys: String, CodingKey { case id, name, status, isDeleted, sealedAt, startDate, endDate }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            status = try c.decode(String.self, forKey: .status)
            isDeleted = try c.decode(Bool.self, forKey: .isDeleted)
            sealedAt = try c.decodeIfPresent(String.self, forKey: .sealedAt)
            startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
            hasEndDate = c.contains(.endDate)
            endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        }
    }

    private struct MiniBoardTask: Decodable {
        let taskId: String
        let boardId: String
        let isDeleted: Bool?
        /// Slice 2b — per-placement parameters; `id` overrides the converter's `bt-<taskId>-<boardId>`.
        let id: String?
        let targetOverride: CountValue?
        let targetKind: String?
        let childTargets: [MiniChildTarget]?
        let titleOverride: String?
    }

    private struct MiniChildTarget: Decodable {
        let childId: String
        let target: CountValue
    }

    private struct MiniCompoundChild: Decodable {
        let compoundTaskId: String
        let childTaskId: String
    }

    private struct MiniMemberTask: Decodable {
        let boardTaskId: String
        let taskId: String
        let isSource: Bool
        let boardId: String
        let boardName: String
        let viaCompoundId: String?
        let goal: CountValue
        let logged: CountValue
        let met: Bool
        let over: CountValue
        let isActive: Bool
    }

    private struct MiniGroup: Decodable {
        let counterId: String
        let name: String
        let lifetime: CountValue
        let countKind: CountKind?
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
        /// Optional — live compound links (slice 2b: a parent compound's placements are cards for its linked children).
        let compoundChildren: [MiniCompoundChild]?
        /// Optional — root id → increment events, passed through as `eventsByTaskId`.
        let eventsByTaskId: [String: [MiniEvent]]?
        let expected: [MiniGroup]
    }

    private struct MiniEvent: Decodable {
        let id: String
        let kind: String
        let delta: CountValue
        let occurredAt: String
        let isDeleted: Bool
    }

    private func toEvents(_ v: Vector) -> [String: [TaskEvent]]? {
        v.eventsByTaskId.map { map in
            map.reduce(into: [String: [TaskEvent]]()) { acc, kv in
                acc[kv.key] = kv.value.map { e in
                    TaskEvent(
                        id: e.id, userId: "u1", taskId: kv.key,
                        kind: TaskEventKind(rawValue: e.kind) ?? .increment,
                        delta: e.delta, occurredAt: e.occurredAt, boardId: nil,
                        createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
                        version: 1, isDeleted: e.isDeleted, deletedAt: nil
                    )
                }
            }
        }
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
            type: m.type == "compound" ? .compound : .counting,
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
            startDate: m.startDate,
            endDate: m.endDate,
            sharedCounterId: m.sharedCounterId,
            baseline: m.baseline,
            createdInWizard: m.createdInWizard,
            isCounter: m.isCounter,
            countKind: m.countKind
        )
    }

    private func toBoard(_ m: MiniBoard) -> Board {
        var dict: [String: Any] = [
            "id": m.id,
            "userId": "u1",
            "name": m.name,
            "status": m.status,
            "boardSize": 5,
            "timeframe": "weekly",
            "startDate": m.startDate ?? ts,
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
        // Absent key ⇒ the shared default; explicit `null` ⇒ open-ended (no key).
        if !m.hasEndDate { dict["endDate"] = "2026-02-07T12:00:00.000Z" } else if let end = m.endDate { dict["endDate"] = end }
        if let sealedAt = m.sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func toBoardTask(_ m: MiniBoardTask) -> BoardTask {
        BoardTask(
            id: m.id ?? "bt-\(m.taskId)-\(m.boardId)",
            boardId: m.boardId,
            taskId: m.taskId,
            row: 0,
            col: 0,
            isCenter: false,
            targetOverride: m.targetOverride,
            targetKind: m.targetKind.flatMap(CountKind.init(rawValue:)),
            childTargets: m.childTargets?.map { PlacementChildTarget(childId: $0.childId, target: $0.target) },
            titleOverride: m.titleOverride,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: m.isDeleted ?? false
        )
    }

    private func toCompoundChild(_ m: MiniCompoundChild, index: Int) -> CompoundChild {
        CompoundChild(
            id: "cc-\(m.compoundTaskId)-\(m.childTaskId)", compoundTaskId: m.compoundTaskId, childTaskId: m.childTaskId,
            childIndex: index, createdAt: ts, updatedAt: ts, version: 1, isDeleted: false
        )
    }

    func testBuildSharedCounterGroupsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
        for v in fixture.vectors {
            // Inside every vector board's window (`toBoard` ends them
            // 2026-02-07), so an ACTIVE vector board is "counting now"
            // whenever the suite runs — the TS runner pins the same instant.
            let vectorNow = ISO8601DateFormatter().date(from: "2026-02-03T12:00:00Z")!
            let groups = buildSharedCounterGroups(
                tasks: v.tasks.map(toTask),
                boardTasks: v.boardTasks.map(toBoardTask),
                boards: v.boards.map(toBoard),
                compoundChildren: (v.compoundChildren ?? []).enumerated().map { toCompoundChild($1, index: $0) },
                eventsByTaskId: toEvents(v),
                memberVisibility: SharedCounterMemberVisibility(showExpired: true, now: vectorNow)
            )

            XCTAssertEqual(groups.count, v.expected.count, "Vector '\(v.name)' group count")
            for (i, g) in groups.enumerated() where i < v.expected.count {
                let exp = v.expected[i]
                XCTAssertEqual(g.counterId, exp.counterId, "Vector '\(v.name)' group[\(i)].counterId")
                XCTAssertEqual(g.name, exp.name, "Vector '\(v.name)' group[\(i)].name")
                XCTAssertEqual(g.lifetime, exp.lifetime, "Vector '\(v.name)' group[\(i)].lifetime")
                if let k = exp.countKind { XCTAssertEqual(g.countKind, k, "Vector '\(v.name)' group[\(i)].countKind") }
                XCTAssertEqual(g.taskCount, exp.taskCount, "Vector '\(v.name)' group[\(i)].taskCount")
                XCTAssertEqual(g.boardCount, exp.boardCount, "Vector '\(v.name)' group[\(i)].boardCount")
                XCTAssertEqual(g.activeTaskCount, exp.activeTaskCount, "Vector '\(v.name)' group[\(i)].activeTaskCount")
                XCTAssertEqual(g.tasks.count, exp.tasks.count, "Vector '\(v.name)' group[\(i)].tasks.count")
                for (j, m) in g.tasks.enumerated() where j < exp.tasks.count {
                    let expMember = exp.tasks[j]
                    XCTAssertEqual(m.boardTaskId, expMember.boardTaskId, "Vector '\(v.name)' [\(i)][\(j)].boardTaskId")
                    XCTAssertEqual(m.viaCompoundId, expMember.viaCompoundId, "Vector '\(v.name)' [\(i)][\(j)].viaCompoundId")
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
