import XCTest
@testable import OYBC

/// Cross-platform enforcement for Board Sources §Member rules (B1,
/// docs/BOARD_SOURCES.md).
///
/// Runs the shared fixture (`Fixtures/memberRuleVectors.json`, byte-identical
/// to `packages/shared/tests/fixtures/memberRuleVectors.json`) through iOS's
/// `BoardSources` member-rule helpers (`Helpers/BoardSourceMemberRules.swift`).
/// The SAME fixture is exercised on the shared side by
/// `packages/shared/tests/algorithms/memberRules.test.ts` — both suites
/// passing against byte-identical vectors, with the identical seeded LCG, is
/// what proves the two hand-mirrored implementations agree (the
/// `BoardSourceVectorTests` precedent).
final class MemberRuleVectorTests: XCTestCase {

    /// Deterministic uniform [0,1) LCG — twin of bingo-core's
    /// `tests/seededRng.ts` `makeSeededRng`. Same seed ⇒ same sequence.
    private final class SeededRng {
        private var state: UInt32
        /// Number of samples actually taken — some vectors pin this.
        private(set) var calls = 0
        init(seed: UInt32) { state = seed }
        func next() -> Double {
            calls += 1
            state = state &* 1664525 &+ 1013904223
            return Double(state) / 4294967296.0
        }
    }

    // MARK: - Fixture decoding

    /// A `children` entry: EITHER a bare childTaskId string (childIndex = its
    /// array position) OR an explicit `{ childTaskId, childIndex }` object.
    /// The object form exists so a vector can put childIndex deliberately out
    /// of array order.
    private struct RawChild: Decodable {
        let childTaskId: String
        let childIndex: Int?

        private enum CodingKeys: String, CodingKey {
            case childTaskId, childIndex
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let id = try? single.decode(String.self) {
                childTaskId = id
                childIndex = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            childTaskId = try container.decode(String.self, forKey: .childTaskId)
            childIndex = try container.decode(Int.self, forKey: .childIndex)
        }
    }

    private struct WindowDaysVector: Decodable {
        let name: String
        let timeframe: String
        let startDate: String?
        let endDate: String?
        let expected: Int?
    }

    private struct AutoTargetVector: Decodable {
        let name: String
        let goal: Int
        let sourceDays: Int?
        let targetDays: Int?
        let expected: Int
    }

    private struct VaryRangeVector: Decodable {
        let name: String
        let t: Int
        let level: Int
        let goal: Int
        let expected: [Int]
    }

    private struct RollTargetVector: Decodable {
        let name: String
        let t: Int
        let level: Int
        let goal: Int
        let seed: UInt32?
        let expected: Int
    }

    private struct ApplyVector: Decodable {
        let name: String
        let supply: [String]
        let memberRules: [String: BoardSourceMemberRule]
        let expected: [String]
        let expectedPartOf: [String: String]
    }

    private struct ApplySection: Decodable {
        let tasks: [String: String]
        let children: [String: [RawChild]]
        let vectors: [ApplyVector]
    }

    private struct RawTask: Decodable {
        let type: String
        let title: String?
        let action: String?
        let unit: String?
        let maxCount: Int?
        let sharedCounterId: String?
        let startDate: String?
        let operatorType: String?
        let threshold: Int?

        private enum CodingKeys: String, CodingKey {
            case type, title, action, unit, maxCount, sharedCounterId, startDate, threshold
            case operatorType = "operator"
        }
    }

    private struct RawWindow: Decodable {
        let timeframe: String
        let startDate: String?
        let endDate: String?
    }

    private struct RawSupply: Decodable {
        let kind: String
        let supply: [String]
        let partOf: [String: String]?
        let memberRules: [String: BoardSourceMemberRule]
    }

    private struct ExpectedDerived: Decodable {
        let root: String
        let sourceMember: String
        let replaces: String
        let maxCount: Int
        let baseline: Int
        let title: String?
        let action: String?
        let unit: String?
    }

    private struct ExpectedChild: Decodable {
        let child: String
        let childIndex: Int
        let isDerived: Bool
    }

    private struct ExpectedCompound: Decodable {
        let source: String
        let replaces: String
        let title: String?
        let operatorType: String?
        let threshold: Int?
        let children: [ExpectedChild]

        private enum CodingKeys: String, CodingKey {
            case source, replaces, title, threshold, children
            case operatorType = "operator"
        }
    }

    private struct ExpectedPlan: Decodable {
        let placement: [String]
        let derived: [ExpectedDerived]
        let compounds: [ExpectedCompound]
    }

    private struct PlanVector: Decodable {
        let name: String
        let mode: String
        let selected: [String]
        let supplies: [RawSupply]
        let manual: [String]
        let manualTaskVary: [String: VaryLevel]
        let seed: UInt32
        let expectedRngCalls: Int?
        let expected: ExpectedPlan
    }

    private struct PlanSection: Decodable {
        let boardId: String
        let window: RawWindow
        let tasks: [String: RawTask]
        let children: [String: [RawChild]]
        let sourceWindows: [String: String]
        let baselines: [String: Int]
        let vectors: [PlanVector]
        let idPins: [String: String]
    }

    private struct Fixture: Decodable {
        let windowDays: [WindowDaysVector]
        let autoTarget: [AutoTargetVector]
        let varyRange: [VaryRangeVector]
        let rollTarget: [RollTargetVector]
        let applyMemberRules: ApplySection
        let planDerivedTasks: PlanSection
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: MemberRuleVectorTests.self).url(
            forResource: "memberRuleVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "memberRuleVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    // MARK: - Value builders

    private static let isoStamp = "2026-09-18T00:00:00.000Z"

    private func timeframe(_ raw: String) throws -> Timeframe {
        try XCTUnwrap(Timeframe(rawValue: raw), "unknown timeframe \(raw)")
    }

    private func varyLevel(_ raw: Int) throws -> VaryLevel {
        try XCTUnwrap(VaryLevel(rawValue: raw), "unknown vary level \(raw)")
    }

    private func makeTask(id: String, type: TaskType) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "",
            type: type,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: Self.isoStamp,
            updatedAt: Self.isoStamp,
            version: 1,
            isDeleted: false
        )
    }

    private func makeTask(id: String, raw: RawTask) throws -> Task {
        Task(
            id: id,
            userId: "u1",
            title: raw.title ?? "",
            type: try XCTUnwrap(TaskType(rawValue: raw.type), "unknown task type \(raw.type)"),
            action: raw.action,
            unit: raw.unit,
            maxCount: raw.maxCount,
            operatorType: raw.operatorType.flatMap { OperatorType(rawValue: $0) },
            threshold: raw.threshold,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: Self.isoStamp,
            updatedAt: Self.isoStamp,
            version: 1,
            isDeleted: false,
            startDate: raw.startDate,
            sharedCounterId: raw.sharedCounterId
        )
    }

    private func makeChildren(_ raw: [String: [RawChild]]) -> [String: [CompoundChild]] {
        raw.mapValues { kids in
            kids.enumerated().map { position, kid in
                CompoundChild(
                    id: "link-\(kid.childTaskId)-\(position)",
                    compoundTaskId: "",
                    childTaskId: kid.childTaskId,
                    childIndex: kid.childIndex ?? position,
                    createdAt: Self.isoStamp,
                    updatedAt: Self.isoStamp,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                )
            }
        }
    }

    private func makeSource(
        index: Int,
        kind: String,
        memberRules: [String: BoardSourceMemberRule]
    ) throws -> BoardSource {
        BoardSource(
            sourceId: "s\(index)",
            kind: try XCTUnwrap(BoardSource.Kind(rawValue: kind), "unknown source kind \(kind)"),
            min: 0,
            max: nil,
            excludedTaskIds: [],
            filter: .all,
            memberRules: memberRules.isEmpty ? nil : memberRules
        )
    }

    // MARK: - Pure arithmetic

    func testNominalWindowDays() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.windowDays.isEmpty)
        for v in fixture.windowDays {
            let actual = BoardSources.nominalWindowDays(
                try timeframe(v.timeframe),
                startDate: v.startDate,
                endDate: v.endDate
            )
            XCTAssertEqual(actual, v.expected, v.name)
        }
    }

    func testAutoTarget() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.autoTarget.isEmpty)
        for v in fixture.autoTarget {
            XCTAssertEqual(
                BoardSources.autoTarget(goal: v.goal, sourceDays: v.sourceDays, targetDays: v.targetDays),
                v.expected,
                v.name
            )
        }
    }

    func testVaryRange() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.varyRange.isEmpty)
        for v in fixture.varyRange {
            let range = BoardSources.varyRange(t: v.t, level: try varyLevel(v.level), goal: v.goal)
            XCTAssertEqual([range.lowerBound, range.upperBound], v.expected, v.name)
        }
    }

    func testRollTarget() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.rollTarget.isEmpty)
        for v in fixture.rollTarget {
            let rng: () -> Double
            if let seed = v.seed {
                let seeded = SeededRng(seed: seed)
                rng = { seeded.next() }
            } else {
                rng = {
                    XCTFail("rng must not be called — \(v.name)")
                    return 0
                }
            }
            XCTAssertEqual(
                BoardSources.rollTarget(t: v.t, level: try varyLevel(v.level), goal: v.goal, rng: rng),
                v.expected,
                v.name
            )
        }
    }

    // MARK: - applyMemberRules

    func testApplyMemberRules() throws {
        let fixture = try loadFixture()
        let section = fixture.applyMemberRules
        XCTAssertFalse(section.vectors.isEmpty)

        var tasksById: [String: Task] = [:]
        for (id, rawType) in section.tasks {
            tasksById[id] = makeTask(
                id: id,
                type: try XCTUnwrap(TaskType(rawValue: rawType), "unknown task type \(rawType)")
            )
        }
        let childrenByCompoundId = makeChildren(section.children)

        for v in section.vectors {
            let supply = BoardSources.Supply(
                source: try makeSource(index: 1, kind: "board", memberRules: v.memberRules),
                supplyTaskIds: v.supply
            )
            let out = BoardSources.applyMemberRules(
                [supply],
                childrenByCompoundId: childrenByCompoundId,
                tasksById: tasksById
            )
            XCTAssertEqual(out.count, 1, v.name)
            XCTAssertEqual(out[0].supplyTaskIds, v.expected, v.name)
            XCTAssertEqual(out[0].partOf, v.expectedPartOf, v.name)
            XCTAssertEqual(out[0].source.sourceId, "s1", v.name)
            XCTAssertEqual(out[0].asSupply.supplyTaskIds, v.expected, v.name)
        }
    }

    // MARK: - planDerivedTasks

    /// The cross-platform proof that Swift's `UUIDv5` + the name formats
    /// agree with TS: every pinned literal must be reproducible here.
    func testIdNamespacesMatchPins() throws {
        let plan = try loadFixture().planDerivedTasks
        let board = plan.boardId
        let pins = plan.idPins

        for root in ["r1", "r2", "c1", "c3", "a1"] {
            XCTAssertEqual(
                BoardSources.derivedTaskId(boardId: board, rootTaskId: root),
                pins["derived:\(root)"],
                "derived:\(root)"
            )
        }
        let compoundC = try XCTUnwrap(pins["derivedCompound:C"])
        let compoundC2 = try XCTUnwrap(pins["derivedCompound:C2"])
        XCTAssertEqual(BoardSources.derivedCompoundId(boardId: board, compoundId: "C"), compoundC)
        XCTAssertEqual(BoardSources.derivedCompoundId(boardId: board, compoundId: "C2"), compoundC2)

        XCTAssertEqual(
            BoardSources.derivedLinkId(
                derivedCompoundId: compoundC2,
                childId: try XCTUnwrap(pins["derived:c3"])
            ),
            pins["link:derivedCompound:C2:derived:c3"]
        )
        XCTAssertEqual(
            BoardSources.derivedLinkId(
                derivedCompoundId: compoundC2,
                childId: try XCTUnwrap(pins["derived:c1"])
            ),
            pins["link:derivedCompound:C2:derived:c1"]
        )
        XCTAssertEqual(
            BoardSources.derivedLinkId(
                derivedCompoundId: compoundC,
                childId: try XCTUnwrap(pins["derived:c1"])
            ),
            pins["link:derivedCompound:C:derived:c1"]
        )
        XCTAssertEqual(
            BoardSources.derivedLinkId(derivedCompoundId: compoundC, childId: "c2"),
            pins["link:derivedCompound:C:c2"]
        )

        // Shape check — a real RFC 4122 v5 uuid, not a hand-typed string.
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        let derivedR1 = try XCTUnwrap(pins["derived:r1"])
        XCTAssertNotNil(
            derivedR1.range(of: pattern, options: .regularExpression),
            "derived:r1 pin is not a v5 uuid: \(derivedR1)"
        )
    }

    func testPlanDerivedTasks() throws {
        let fixture = try loadFixture()
        let plan = fixture.planDerivedTasks
        XCTAssertFalse(plan.vectors.isEmpty)

        var tasksById: [String: Task] = [:]
        for (id, raw) in plan.tasks {
            tasksById[id] = try makeTask(id: id, raw: raw)
        }
        let childrenByCompoundId = makeChildren(plan.children)
        var sourceWindowByTaskId: [String: BoardSources.BoardWindow] = [:]
        for (id, rawTimeframe) in plan.sourceWindows {
            sourceWindowByTaskId[id] = BoardSources.BoardWindow(
                timeframe: try timeframe(rawTimeframe),
                startDate: nil,
                endDate: nil
            )
        }
        let window = BoardSources.BoardWindow(
            timeframe: try timeframe(plan.window.timeframe),
            startDate: plan.window.startDate,
            endDate: plan.window.endDate
        )
        /// `derived:x` / `derivedCompound:C` → the pinned literal; anything
        /// else is already a plain task id.
        func resolveId(_ token: String) -> String {
            guard token.hasPrefix("derived:") || token.hasPrefix("derivedCompound:") else {
                return token
            }
            return plan.idPins[token] ?? token
        }
        /// Pinned id → its fixture token, so a link id can be looked up by token.
        var tokenOfId: [String: String] = [:]
        for (token, id) in plan.idPins { tokenOfId[id] = token }

        for v in plan.vectors {
            let supplies = try v.supplies.enumerated().map { index, raw in
                BoardSources.ExpandedSupply(
                    source: try makeSource(
                        index: index + 1,
                        kind: raw.kind,
                        memberRules: raw.memberRules
                    ),
                    supplyTaskIds: raw.supply,
                    partOf: raw.partOf ?? [:]
                )
            }
            let seeded = SeededRng(seed: v.seed)
            let out = BoardSources.planDerivedTasks(
                selectedIds: v.selected,
                supplies: supplies,
                manualTaskIds: v.manual,
                manualTaskVary: v.manualTaskVary,
                boardId: plan.boardId,
                window: window,
                mode: v.mode == "recurring" ? .recurring : .oneOff,
                tasksById: tasksById,
                childrenByCompoundId: childrenByCompoundId,
                sourceWindowByTaskId: sourceWindowByTaskId,
                baselineByRootId: plan.baselines,
                rng: { seeded.next() }
            )

            if let expectedCalls = v.expectedRngCalls {
                XCTAssertEqual(seeded.calls, expectedCalls, "\(v.name): rng sample count")
            }
            XCTAssertEqual(out.placementIds, v.expected.placement.map(resolveId), v.name)

            // The (root, sourceMember, replaces, maxCount, baseline) tuples, IN ORDER.
            XCTAssertEqual(
                out.derivedTasks.map { [$0.rootTaskId, $0.sourceMemberId, $0.replacesId] },
                v.expected.derived.map { [$0.root, $0.sourceMember, $0.replaces] },
                "\(v.name): derived identity tuples"
            )
            XCTAssertEqual(
                out.derivedTasks.map { [$0.maxCount, $0.baseline] },
                v.expected.derived.map { [$0.maxCount, $0.baseline] },
                "\(v.name): derived (maxCount, baseline)"
            )
            for derived in out.derivedTasks {
                XCTAssertEqual(
                    derived.id,
                    plan.idPins["derived:\(derived.rootTaskId)"],
                    "\(v.name): derived id for root \(derived.rootTaskId)"
                )
                XCTAssertEqual(derived.timeframe, window.timeframe, v.name)
                XCTAssertEqual(derived.startDate, window.startDate, v.name)
                XCTAssertEqual(derived.endDate, window.endDate, v.name)
            }
            for titled in v.expected.derived where titled.title != nil {
                let derived = try XCTUnwrap(
                    out.derivedTasks.first { $0.rootTaskId == titled.root },
                    "\(v.name): no derived draft for root \(titled.root)"
                )
                XCTAssertEqual(derived.title, titled.title, v.name)
                XCTAssertEqual(derived.action, titled.action, v.name)
                XCTAssertEqual(derived.unit, titled.unit, v.name)
            }

            XCTAssertEqual(
                out.derivedCompounds.map { [$0.sourceCompoundId, $0.replacesId] },
                v.expected.compounds.map { [$0.source, $0.replaces] },
                "\(v.name): derived compound identity"
            )
            XCTAssertEqual(
                out.derivedCompounds.map { compound in
                    compound.children.map { "\($0.childTaskId)|\($0.childIndex)|\($0.isDerived)" }
                },
                v.expected.compounds.map { compound in
                    compound.children.map { "\(resolveId($0.child))|\($0.childIndex)|\($0.isDerived)" }
                },
                "\(v.name): derived compound children"
            )
            for compound in out.derivedCompounds {
                XCTAssertEqual(
                    compound.id,
                    plan.idPins["derivedCompound:\(compound.sourceCompoundId)"],
                    "\(v.name): derived compound id"
                )
                for child in compound.children {
                    let childToken = tokenOfId[child.childTaskId] ?? child.childTaskId
                    XCTAssertEqual(
                        child.linkId,
                        plan.idPins["link:derivedCompound:\(compound.sourceCompoundId):\(childToken)"],
                        "\(v.name): link id for \(childToken)"
                    )
                }
            }
            for titled in v.expected.compounds where titled.title != nil {
                let compound = try XCTUnwrap(
                    out.derivedCompounds.first { $0.sourceCompoundId == titled.source },
                    "\(v.name): no derived compound for \(titled.source)"
                )
                XCTAssertEqual(compound.title, titled.title, v.name)
                XCTAssertEqual(compound.operatorType?.rawValue, titled.operatorType, v.name)
                XCTAssertEqual(compound.threshold, titled.threshold, v.name)
            }
        }
    }
}
