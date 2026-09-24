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
    ///
    /// A counting reference wrapper around the production value-type
    /// ``OYBC/SeededRng`` (B3 RC6 promoted the recurrence into the app
    /// target); the call tally stays here because only these vectors pin it.
    private final class SeededRng {
        private var rng: OYBC.SeededRng
        /// Number of samples actually taken — some vectors pin this.
        private(set) var calls = 0
        init(seed: UInt32) { rng = OYBC.SeededRng(seed: seed) }
        func next() -> Double {
            calls += 1
            return rng.next()
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
        /// B2 — the window every derived compound is stamped with (copied
        /// from the board being assembled, the same one its parts carry).
        let timeframe: String
        let startDate: String?
        let endDate: String?
        let children: [ExpectedChild]

        private enum CodingKeys: String, CodingKey {
            case source, replaces, title, threshold, children
            case timeframe, startDate, endDate
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

    // MARK: - B2 fixture decoding (windowBaseline + derivedRows)

    /// A loosely-typed JSON value, so an `expected` row can be subset-matched
    /// against the produced row field-by-field (the Swift analogue of Jest's
    /// `toMatchObject`) without a hand-written comparison per field.
    private enum FixtureValue: Decodable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case double(Double)
        case null
        case array([FixtureValue])
        case object([String: FixtureValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            // Bool BEFORE Int — `JSONDecoder` would otherwise reject, and the
            // ordering documents the intent either way.
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Int.self) { self = .int(value); return }
            if let value = try? container.decode(Double.self) { self = .double(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([FixtureValue].self) { self = .array(value); return }
            self = .object(try container.decode([String: FixtureValue].self))
        }
    }

    private struct RawBaselineEvent: Decodable {
        let taskId: String
        let kind: String
        let delta: Int?
        let occurredAt: String
        let isDeleted: Bool
    }

    private struct FrozenRowTask: Decodable {
        let sharedCounterId: String?
        let startDate: String?
        let endDate: String?
        let createdInWizard: Bool
    }

    private struct FrozenRowVector: Decodable {
        let name: String
        let task: FrozenRowTask
        let now: String
        let expected: Bool
    }

    private struct FrozenReachedVector: Decodable {
        let name: String
        let task: FrozenRowTask
        let occurredAt: String
        let now: String
        let expected: Bool
    }

    private struct BaselineVector: Decodable {
        let name: String
        let root: String
        let boundary: String
        let events: [RawBaselineEvent]
        let expected: Int
    }

    private struct RawRoot: Decodable {
        let currentCount: Int
        let action: String?
        let unit: String?
    }

    private struct RawSourceCompound: Decodable {
        let operatorType: String?
        let threshold: Int?
        let title: String?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case threshold, title, description
            case operatorType = "operator"
        }
    }

    private struct RawDerivedTaskDraft: Decodable {
        let id: String
        let rootTaskId: String
        let sourceMemberId: String
        let replacesId: String
        let maxCount: Int
        let baseline: Int
        let title: String
        let action: String
        let unit: String
        let timeframe: String
        let startDate: String?
        let endDate: String?
    }

    private struct RawDerivedChildDraft: Decodable {
        let linkId: String
        let childTaskId: String
        let childIndex: Int
        let isDerived: Bool
    }

    private struct RawDerivedCompoundDraft: Decodable {
        let id: String
        let sourceCompoundId: String
        let replacesId: String
        let title: String
        let operatorType: String?
        let threshold: Int?
        let timeframe: String
        let startDate: String?
        let endDate: String?
        let children: [RawDerivedChildDraft]

        private enum CodingKeys: String, CodingKey {
            case id, sourceCompoundId, replacesId, title, threshold
            case timeframe, startDate, endDate, children
            case operatorType = "operator"
        }
    }

    private struct RawDrafts: Decodable {
        let placementIds: [String]
        let derivedTasks: [RawDerivedTaskDraft]
        let derivedCompounds: [RawDerivedCompoundDraft]
    }

    private struct ExpectedRows: Decodable {
        let tasks: [[String: FixtureValue]]
        let links: [[String: FixtureValue]]
    }

    private struct DerivedRowsVector: Decodable {
        let name: String
        let drafts: RawDrafts
        let expected: ExpectedRows
    }

    private struct DerivedRowsSection: Decodable {
        let boardId: String
        let userId: String
        let now: String
        let ids: [String: String]
        let roots: [String: RawRoot]
        let compounds: [String: RawSourceCompound]
        let vectors: [DerivedRowsVector]
    }


    // MARK: - B3 fixture decoding (display + rule editing)

    private struct EffectiveTargetVector: Decodable {
        let name: String
        let goal: Int
        let explicit: Int?
        let mode: String
        let fromBoard: Bool
        /// Bare timeframe string; the harness wraps it into a `BoardWindow`
        /// with nil dates (fixture note `windows`). Absent = no source window.
        let sourceWindow: String?
        let targetWindow: String
        let expected: Int
    }

    private struct VaryRangeLabelVector: Decodable {
        let name: String
        let t: Int
        let level: Int
        let goal: Int
        let unit: String
        /// JSON `null` at vary level 0 — decodes straight to nil.
        let expected: String?
    }

    private struct SplitSquaresNoteVector: Decodable {
        let name: String
        let excludedPartIds: [String]
        let partIds: [String]
        let expected: String
    }

    private struct RemainingTargetVector: Decodable {
        let name: String
        let goal: Int
        let windowCount: Int
        let expected: Int
    }

    private struct PrefilledOneOffTargetVector: Decodable {
        let name: String
        let goal: Int
        let windowCount: Int
        /// Bare timeframe string; absent = no source window (fixture note
        /// `windows`). `sourceWindowDates` / `targetWindowDates` carry the
        /// `[start, end]` bounds a CUSTOM window needs — a one-element array
        /// means the end bound is MISSING.
        let sourceWindow: String?
        let sourceWindowDates: [String]?
        let targetWindow: String
        let targetWindowDates: [String]?
        let expected: Int
    }

    private struct MemberRuleForVector: Decodable {
        let name: String
        let memberRules: [String: BoardSourceMemberRule]?
        let taskId: String
        let expected: BoardSourceMemberRule
    }

    private struct PartRuleForVector: Decodable {
        let name: String
        let rule: BoardSourceMemberRule
        let childId: String
        let expected: BoardSourcePartRule
    }

    /// The fixture's `{ set: {...}, clear: [names] }` patch shape. The split
    /// exists precisely so a Swift decoder can tell "field absent from the
    /// patch, leave alone" from "field explicitly cleared" without relying on
    /// JSON `null` (fixture note `swiftPatchDecoding`) — `.keep` is NEVER
    /// inferred from an absent `clear` entry.
    private struct RawPatch: Decodable {
        struct RawSet: Decodable {
            let target: Int?
            let vary: Int?
            let split: Bool?
            let excluded: Bool?
        }
        let set: RawSet?
        let clear: [String]?
    }

    private struct RawPatchStep: Decodable {
        let taskId: String
        let childId: String?
        let patch: RawPatch
    }

    private struct WithRuleVector: Decodable {
        let name: String
        let startMemberRules: [String: BoardSourceMemberRule]?
        let steps: [RawPatchStep]
        let expectedMemberRules: [String: BoardSourceMemberRule]?
    }

    private struct ImmutabilityVector: Decodable {
        let name: String
        /// `"member"` or `"part"` — which setter the chain drives.
        let kind: String
        let startMemberRules: [String: BoardSourceMemberRule]?
        let steps: [RawPatchStep]
    }

    private struct MemberSummaryExpected: Decodable {
        let text: String
        let varying: Bool
    }

    private struct CountingSummaryVector: Decodable {
        let name: String
        let target: Int
        let level: Int
        let goal: Int
        let unit: String
        /// Nullable: a counting chip is SUPPRESSED when it would only
        /// restate the row's own auto-generated title. `CompoundSummaryVector`
        /// keeps a non-optional `expected` on purpose — a compound chip is
        /// never suppressed, and the type says so.
        let expected: MemberSummaryExpected?
    }

    private struct CompoundSummaryVector: Decodable {
        let name: String
        let split: Bool
        let partIds: [String]
        let excludedPartIds: [String]
        let level: Int
        let expected: MemberSummaryExpected
    }

    /// The two task fields `seededTargetsForSource` reads — the fixture's
    /// `tasks` map (TS twin: `Pick<Task, 'type' | 'maxCount'>`).
    private struct SeededTaskSpec: Decodable {
        let type: String
        let maxCount: Int?
    }

    private struct SeededTargetsVector: Decodable {
        let name: String
        let supplyTaskIds: [String]
        let tasks: [String: SeededTaskSpec]
        let windowCountByTaskId: [String: Int]
        /// Bare timeframe string; absent = no source window (fixture note
        /// `windows`) — the unknowable-span branch.
        let sourceWindow: String?
        let targetWindow: String
        let expected: [String: Int]
    }

    private struct DisplaySection: Decodable {
        let effectiveMemberTarget: [EffectiveTargetVector]
        let varyRangeLabel: [VaryRangeLabelVector]
        let splitSquaresNote: [SplitSquaresNoteVector]
        let remainingTarget: [RemainingTargetVector]
        let prefilledOneOffTarget: [PrefilledOneOffTargetVector]
        let seededTargetsForSource: [SeededTargetsVector]
        let memberRuleFor: [MemberRuleForVector]
        let partRuleFor: [PartRuleForVector]
        let withMemberRule: [WithRuleVector]
        let withPartRule: [WithRuleVector]
        let immutability: [ImmutabilityVector]
        let countingSummary: [CountingSummaryVector]
        let compoundSummary: [CompoundSummaryVector]
    }

    private struct Fixture: Decodable {
        let windowDays: [WindowDaysVector]
        let autoTarget: [AutoTargetVector]
        let varyRange: [VaryRangeVector]
        let rollTarget: [RollTargetVector]
        let windowBaseline: [BaselineVector]
        let frozenDerivedRow: [FrozenRowVector]
        let frozenRowReachedByEvent: [FrozenReachedVector]
        let derivedRows: DerivedRowsSection
        let applyMemberRules: ApplySection
        let planDerivedTasks: PlanSection
        let display: DisplaySection
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
            // B2 — every derived compound carries the board's window, so it
            // expires with its parts rather than outliving them.
            XCTAssertEqual(
                out.derivedCompounds.map {
                    "\($0.timeframe.rawValue)|\($0.startDate ?? "-")|\($0.endDate ?? "-")"
                },
                v.expected.compounds.map {
                    "\($0.timeframe)|\($0.startDate ?? "-")|\($0.endDate ?? "-")"
                },
                "\(v.name): derived compound window stamp"
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

    // MARK: - Propagation freeze: isFrozenDerivedRow

    func testIsFrozenDerivedRow() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.frozenDerivedRow.count, 4)
        for v in fixture.frozenDerivedRow {
            var task = makeTask(id: "d1", type: .counting)
            task.sharedCounterId = v.task.sharedCounterId
            task.startDate = v.task.startDate
            task.endDate = v.task.endDate
            task.createdInWizard = v.task.createdInWizard
            XCTAssertEqual(BoardSources.isFrozenDerivedRow(task, now: v.now), v.expected, v.name)
        }
    }

    func testIsFrozenRowReachedByEvent() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.frozenRowReachedByEvent.count, 5)
        for v in fixture.frozenRowReachedByEvent {
            var task = makeTask(id: "d1", type: .counting)
            task.sharedCounterId = v.task.sharedCounterId
            task.startDate = v.task.startDate
            task.endDate = v.task.endDate
            task.createdInWizard = v.task.createdInWizard
            XCTAssertEqual(
                BoardSources.isFrozenRowReachedByEvent(task, occurredAt: v.occurredAt, now: v.now),
                v.expected, v.name
            )
        }
    }

    // MARK: - B2: computeWindowBaseline

    func testComputeWindowBaseline() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.windowBaseline.isEmpty)
        for v in fixture.windowBaseline {
            let events = v.events.enumerated().map { index, raw in
                TaskEvent(
                    id: "e\(index)",
                    userId: "u1",
                    taskId: raw.taskId,
                    kind: TaskEventKind(rawValue: raw.kind) ?? .completion,
                    delta: raw.delta,
                    occurredAt: raw.occurredAt,
                    boardId: nil,
                    createdAt: Self.isoStamp,
                    updatedAt: Self.isoStamp,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: raw.isDeleted,
                    deletedAt: raw.isDeleted ? Self.isoStamp : nil
                )
            }
            XCTAssertEqual(
                BoardSources.computeWindowBaseline(
                    rootTaskId: v.root,
                    events: events,
                    boundary: v.boundary
                ),
                v.expected,
                v.name
            )
        }
    }

    // MARK: - B2: isWindowStampedDerived (the STORED-row predicate)

    /// Mirrors the TS twin's five cases 1:1. All three marks are required —
    /// each on its own is ordinary user data.
    func testIsWindowStampedDerived() {
        func row(
            sharedCounterId: String? = "11111111-0000-4000-8000-000000000001",
            startDate: String? = "2026-09-18",
            createdInWizard: Bool = true
        ) -> Task {
            Task(
                id: "t1",
                userId: "u1",
                title: "T",
                type: .counting,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: Self.isoStamp,
                updatedAt: Self.isoStamp,
                version: 1,
                isDeleted: false,
                startDate: startDate,
                sharedCounterId: sharedCounterId,
                createdInWizard: createdInWizard
            )
        }
        XCTAssertTrue(BoardSources.isWindowStampedDerived(row()))
        XCTAssertFalse(
            BoardSources.isWindowStampedDerived(row(sharedCounterId: nil)),
            "no sharedCounterId → a plain window-scoped counting task"
        )
        XCTAssertFalse(
            BoardSources.isWindowStampedDerived(row(startDate: nil)),
            "no startDate → an ordinary linked counter, not window-stamped"
        )
        XCTAssertFalse(
            BoardSources.isWindowStampedDerived(row(createdInWizard: false)),
            "not wizard-born → a hand-made linked + timeboxed counter"
        )
        // Swift's `createdInWizard` is a non-optional Bool, so the TS twin's
        // "absent" and "explicitly false" cases collapse into the one above —
        // the empty-string shapes are what stand in for the other degenerate
        // inputs a decoded row can actually carry.
        XCTAssertFalse(BoardSources.isWindowStampedDerived(row(sharedCounterId: "")))
        XCTAssertFalse(BoardSources.isWindowStampedDerived(row(startDate: "")))
    }

    // MARK: - B2: buildDerivedRows

    /// Fixture id token → its uuid; anything that isn't a token passes through.
    private func resolver(_ section: DerivedRowsSection) -> (String) -> String {
        { token in section.ids[token] ?? token }
    }

    /// Encode a row and read it back as loose JSON, so `expected`'s listed
    /// fields can be compared one by one and `expectedAbsent`'s can be
    /// asserted missing. `Task`/`CompoundChild` encode optionals with
    /// `encodeIfPresent`, so a nil field is genuinely absent from the dict.
    private func encodedFields<T: Encodable>(_ value: T) throws -> [String: FixtureValue] {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode([String: FixtureValue].self, from: data)
    }

    /// Subset match: every listed field must be present and equal; the
    /// `expectedAbsent` list must be absent entirely.
    private func assertSubset(
        _ actual: [String: FixtureValue],
        matches expected: [String: FixtureValue],
        label: String
    ) {
        for (key, value) in expected {
            if key == "expectedAbsent" {
                guard case .array(let absent) = value else {
                    XCTFail("\(label): expectedAbsent is not an array")
                    continue
                }
                for entry in absent {
                    guard case .string(let field) = entry else { continue }
                    XCTAssertNil(actual[field], "\(label): expected \(field) to be absent")
                }
                continue
            }
            XCTAssertEqual(actual[key], value, "\(label): field \(key)")
        }
    }

    /// The cross-platform proof that this section's own literals reproduce
    /// here — the same shape as `testIdNamespacesMatchPins` for the plan
    /// section, over the uuid-shaped ids `buildDerivedRows` needs.
    func testDerivedRowsIdPins() throws {
        let section = try loadFixture().derivedRows
        let id = resolver(section)
        XCTAssertEqual(
            BoardSources.derivedTaskId(boardId: section.boardId, rootTaskId: id("R1")),
            section.ids["derived:R1"]
        )
        XCTAssertEqual(
            BoardSources.derivedTaskId(boardId: section.boardId, rootTaskId: id("R2")),
            section.ids["derived:R2"]
        )
        XCTAssertEqual(
            BoardSources.derivedCompoundId(boardId: section.boardId, compoundId: id("C")),
            section.ids["derivedCompound:C"]
        )
        XCTAssertEqual(
            BoardSources.derivedLinkId(
                derivedCompoundId: try XCTUnwrap(section.ids["derivedCompound:C"]),
                childId: try XCTUnwrap(section.ids["derived:R1"])
            ),
            section.ids["link:derivedCompound:C:derived:R1"]
        )
        XCTAssertEqual(
            BoardSources.derivedLinkId(
                derivedCompoundId: try XCTUnwrap(section.ids["derivedCompound:C"]),
                childId: id("K2")
            ),
            section.ids["link:derivedCompound:C:K2"]
        )
    }

    func testBuildDerivedRows() throws {
        let section = try loadFixture().derivedRows
        XCTAssertFalse(section.vectors.isEmpty)
        let id = resolver(section)

        var rootsById: [String: Task] = [:]
        for (token, raw) in section.roots {
            rootsById[id(token)] = Task(
                id: id(token),
                userId: section.userId,
                title: "root \(token)",
                type: .counting,
                action: raw.action,
                unit: raw.unit,
                totalCompletions: 0,
                totalInstances: 0,
                currentCount: raw.currentCount,
                createdAt: Self.isoStamp,
                updatedAt: Self.isoStamp,
                version: 1,
                isDeleted: false
            )
        }
        var compoundsById: [String: Task] = [:]
        for (token, raw) in section.compounds {
            compoundsById[id(token)] = Task(
                id: id(token),
                userId: section.userId,
                title: raw.title ?? "",
                description: raw.description,
                type: .compound,
                operatorType: raw.operatorType.flatMap { OperatorType(rawValue: $0) },
                threshold: raw.threshold,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: Self.isoStamp,
                updatedAt: Self.isoStamp,
                version: 1,
                isDeleted: false
            )
        }

        for v in section.vectors {
            let drafts = BoardSources.PlanDerivedTasksResult(
                placementIds: v.drafts.placementIds.map(id),
                derivedTasks: try v.drafts.derivedTasks.map { raw in
                    BoardSources.DerivedTaskDraft(
                        id: id(raw.id),
                        rootTaskId: id(raw.rootTaskId),
                        sourceMemberId: id(raw.sourceMemberId),
                        replacesId: id(raw.replacesId),
                        maxCount: raw.maxCount,
                        baseline: raw.baseline,
                        title: raw.title,
                        action: raw.action,
                        unit: raw.unit,
                        timeframe: try timeframe(raw.timeframe),
                        startDate: raw.startDate,
                        endDate: raw.endDate
                    )
                },
                derivedCompounds: try v.drafts.derivedCompounds.map { raw in
                    BoardSources.DerivedCompoundDraft(
                        id: id(raw.id),
                        sourceCompoundId: id(raw.sourceCompoundId),
                        replacesId: id(raw.replacesId),
                        title: raw.title,
                        operatorType: raw.operatorType.flatMap { OperatorType(rawValue: $0) },
                        threshold: raw.threshold,
                        timeframe: try timeframe(raw.timeframe),
                        startDate: raw.startDate,
                        endDate: raw.endDate,
                        children: raw.children.map { child in
                            BoardSources.DerivedCompoundChildDraft(
                                linkId: id(child.linkId),
                                childTaskId: id(child.childTaskId),
                                childIndex: child.childIndex,
                                isDerived: child.isDerived
                            )
                        }
                    )
                }
            )

            let out = BoardSources.buildDerivedRows(
                drafts: drafts,
                userId: section.userId,
                now: section.now,
                rootsById: rootsById,
                compoundsById: compoundsById
            )

            // Order + length in full: derived counters in draft order, then
            // the derived compounds.
            XCTAssertEqual(
                out.tasks.map { $0.id },
                v.expected.tasks.map { fields -> String in
                    guard case .string(let value)? = fields["id"] else { return "<missing>" }
                    return id(value)
                },
                "\(v.name): task ids + order"
            )
            XCTAssertEqual(
                out.links.map { $0.id },
                v.expected.links.map { fields -> String in
                    guard case .string(let value)? = fields["id"] else { return "<missing>" }
                    return id(value)
                },
                "\(v.name): link ids + order"
            )

            for (index, row) in out.tasks.enumerated() where index < v.expected.tasks.count {
                var expected: [String: FixtureValue] = [:]
                for (key, value) in v.expected.tasks[index] {
                    // Ids inside the expectation are tokens too.
                    if case .string(let raw) = value { expected[key] = .string(id(raw)) }
                    else { expected[key] = value }
                }
                assertSubset(
                    try encodedFields(row),
                    matches: expected,
                    label: "\(v.name): task[\(index)]"
                )
            }
            for (index, link) in out.links.enumerated() where index < v.expected.links.count {
                var expected: [String: FixtureValue] = [:]
                for (key, value) in v.expected.links[index] {
                    if case .string(let raw) = value { expected[key] = .string(id(raw)) }
                    else { expected[key] = value }
                }
                assertSubset(
                    try encodedFields(link),
                    matches: expected,
                    label: "\(v.name): link[\(index)]"
                )
            }

            // The derived counters keep the draft ids verbatim (the
            // deterministic uuidv5 minted by planDerivedTasks IS the row id —
            // never re-minted here).
            XCTAssertEqual(
                Array(out.tasks.prefix(drafts.derivedTasks.count)).map { $0.id },
                drafts.derivedTasks.map { $0.id },
                "\(v.name): derived counter ids are the draft ids"
            )
            for link in out.links {
                let parent = out.tasks.first { $0.id == link.compoundTaskId }
                XCTAssertEqual(parent?.type, .compound, "\(v.name): link parent is a compound")
                XCTAssertEqual([link.createdAt, link.updatedAt], [section.now, section.now], v.name)
            }

            // Completeness — the iOS analogue of the TS suite's Zod pass: a
            // forgotten required field / an FK-violating shape fails on the
            // real schema rather than passing silently.
            try assertRowsPersist(out, section: section)
        }
    }

    /// Every built row must `save(db)` cleanly into a fresh migrated database
    /// (`foreign_keys = ON`), tasks before links.
    private func assertRowsPersist(
        _ rows: BoardSources.DerivedRows,
        section: DerivedRowsSection
    ) throws {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: section.userId,
                email: "t@e.com",
                displayName: "T",
                photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: section.now,
                updatedAt: section.now,
                lastSyncedAt: nil,
                version: 1
            ).save(db)
            for row in rows.tasks { try row.save(db) }
            // A link may point at an ORIGINAL child (the un-derived half of a
            // One-square compound), which the builder never produces — stub it
            // so the FK is satisfiable and the link itself is what's under test.
            let produced = Set(rows.tasks.map { $0.id })
            for link in rows.links where !produced.contains(link.childTaskId) {
                try Task(
                    id: link.childTaskId,
                    userId: section.userId,
                    title: "original child",
                    type: .normal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: section.now,
                    updatedAt: section.now,
                    version: 1,
                    isDeleted: false
                ).save(db)
            }
            for link in rows.links { try link.save(db) }
            XCTAssertEqual(try Task.fetchCount(db), rows.tasks.count + (
                Set(rows.links.map { $0.childTaskId }).subtracting(produced).count
            ))
            XCTAssertEqual(try CompoundChild.fetchCount(db), rows.links.count)
        }
    }
    // MARK: - B3 display + rule editing

    /// A minimal `BoardSource` for the display vectors — `memberRules`
    /// omitted unless the vector supplies one.
    private func displaySource(_ memberRules: [String: BoardSourceMemberRule]?) -> BoardSource {
        BoardSource(
            sourceId: "s1", kind: .board, min: 0, max: nil,
            excludedTaskIds: [], filter: .all, memberRules: memberRules
        )
    }

    private func planMode(_ raw: String) throws -> BoardSources.PlanMode {
        switch raw {
        case "oneOff": return .oneOff
        case "recurring": return .recurring
        default:
            XCTFail("unknown plan mode \(raw)")
            throw XCTSkip("bad mode")
        }
    }

    /// Wraps a bare timeframe string into a `BoardWindow` (nil dates).
    private func window(_ raw: String) throws -> BoardSources.BoardWindow {
        BoardSources.BoardWindow(timeframe: try timeframe(raw))
    }

    /// Same, but with the optional `[start, end]` bounds a CUSTOM vector
    /// carries. A one-element array leaves the end bound nil — the fixture's
    /// way of pinning the unknowable-span branch.
    private func window(_ raw: String, _ dates: [String]?) throws -> BoardSources.BoardWindow {
        BoardSources.BoardWindow(
            timeframe: try timeframe(raw),
            startDate: dates?.first,
            endDate: (dates?.count ?? 0) > 1 ? dates?[1] : nil
        )
    }

    private func memberPatch(_ raw: RawPatch) throws -> BoardSources.MemberRulePatch {
        var patch = BoardSources.MemberRulePatch()
        if let value = raw.set?.target { patch.target = .set(value) }
        if let value = raw.set?.vary { patch.vary = .set(try varyLevel(value)) }
        if let value = raw.set?.split { patch.split = .set(value) }
        for key in raw.clear ?? [] {
            switch key {
            case "target": patch.target = .clear
            case "vary": patch.vary = .clear
            case "split": patch.split = .clear
            case "parts": patch.parts = .clear
            default: XCTFail("unknown member-rule field \(key)")
            }
        }
        return patch
    }

    private func partPatch(_ raw: RawPatch) throws -> BoardSources.PartRulePatch {
        var patch = BoardSources.PartRulePatch()
        if let value = raw.set?.target { patch.target = .set(value) }
        if let value = raw.set?.vary { patch.vary = .set(try varyLevel(value)) }
        if let value = raw.set?.excluded { patch.excluded = .set(value) }
        for key in raw.clear ?? [] {
            switch key {
            case "target": patch.target = .clear
            case "vary": patch.vary = .clear
            case "excluded": patch.excluded = .clear
            default: XCTFail("unknown part-rule field \(key)")
            }
        }
        return patch
    }

    /// `expectedMemberRules: null` asserts the result carries NO rules at all
    /// — nil in memory AND no `memberRules` key once encoded.
    private func assertMemberRules(
        _ source: BoardSource,
        _ expected: [String: BoardSourceMemberRule]?,
        _ name: String
    ) throws {
        if let expected {
            XCTAssertEqual(source.memberRules, expected, name)
        } else {
            XCTAssertNil(source.memberRules, name)
            let encoded = try XCTUnwrap(
                String(data: try JSONEncoder().encode(source), encoding: .utf8), name
            )
            XCTAssertFalse(encoded.contains("memberRules"),
                           "\(name): a rule-less source must encode without the key")
        }
    }

    func testEffectiveMemberTarget() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.effectiveMemberTarget.isEmpty)
        for v in section.effectiveMemberTarget {
            XCTAssertEqual(
                BoardSources.effectiveMemberTarget(
                    goal: v.goal,
                    explicit: v.explicit,
                    mode: try planMode(v.mode),
                    fromBoard: v.fromBoard,
                    sourceWindow: try v.sourceWindow.map { try window($0) },
                    targetWindow: try window(v.targetWindow)
                ),
                v.expected,
                v.name
            )
        }
    }

    func testVaryRangeLabel() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.varyRangeLabel.isEmpty)
        for v in section.varyRangeLabel {
            XCTAssertEqual(
                BoardSources.varyRangeLabel(
                    t: v.t, level: try varyLevel(v.level), goal: v.goal, unit: v.unit
                ),
                v.expected,
                v.name
            )
        }
    }

    func testSplitSquaresNote() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.splitSquaresNote.isEmpty)
        for v in section.splitSquaresNote {
            XCTAssertEqual(
                BoardSources.splitSquaresNote(
                    partIds: v.partIds, excludedPartIds: Set(v.excludedPartIds)
                ),
                v.expected,
                v.name
            )
        }
    }

    func testCountingSummaryVectors() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.countingSummary.isEmpty)
        for v in section.countingSummary {
            let summary = BoardSources.countingSummary(
                target: v.target, level: try varyLevel(v.level), goal: v.goal, unit: v.unit
            )
            guard let expected = v.expected else {
                XCTAssertNil(summary, v.name)
                continue
            }
            XCTAssertEqual(summary?.text, expected.text, v.name)
            XCTAssertEqual(summary?.varying, expected.varying, v.name)
        }
    }

    func testCompoundSummaryVectors() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.compoundSummary.isEmpty)
        for v in section.compoundSummary {
            let summary = BoardSources.compoundSummary(
                split: v.split,
                partIds: v.partIds,
                excludedPartIds: Set(v.excludedPartIds),
                level: try varyLevel(v.level)
            )
            XCTAssertEqual(summary.text, v.expected.text, v.name)
            XCTAssertEqual(summary.varying, v.expected.varying, v.name)
        }
    }

    func testRemainingTarget() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.remainingTarget.isEmpty)
        for v in section.remainingTarget {
            XCTAssertEqual(
                BoardSources.remainingTarget(goal: v.goal, windowCount: v.windowCount),
                v.expected,
                v.name
            )
        }
    }

    func testPrefilledOneOffTarget() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.prefilledOneOffTarget.isEmpty)
        for v in section.prefilledOneOffTarget {
            XCTAssertEqual(
                BoardSources.prefilledOneOffTarget(
                    goal: v.goal,
                    windowCount: v.windowCount,
                    sourceWindow: try v.sourceWindow.map { try window($0, v.sourceWindowDates) },
                    targetWindow: try window(v.targetWindow, v.targetWindowDates)
                ),
                v.expected,
                v.name
            )
        }
    }

    /// The safety property the 2026-09-21 ruling rests on, asserted directly:
    /// when the source and target windows are the same nominal length the
    /// ratio is 1, so the prefill is the remaining amount VERBATIM. Each
    /// expectation is the hand-computed `goal - windowCount` (23 = 35 - 12),
    /// never a second call to the function under test.
    func testPrefilledOneOffTargetSameTimeframeIsUnchanged() {
        for tf in [Timeframe.daily, .weekly, .monthly, .yearly] {
            XCTAssertEqual(
                BoardSources.prefilledOneOffTarget(
                    goal: 35,
                    windowCount: 12,
                    sourceWindow: BoardSources.BoardWindow(timeframe: tf),
                    targetWindow: BoardSources.BoardWindow(timeframe: tf)
                ),
                23,
                "\(tf) source to \(tf) target must not pro-rate"
            )
        }
    }

    /// The seed map the remove-confirm recomputes at removal time (amended
    /// ruling 2026-09-23) — same vectors as the TS twin, so the two
    /// hand-mirrored loops can't disagree about which members get seeded.
    func testSeededTargetsForSource() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.seededTargetsForSource.isEmpty)
        for v in section.seededTargetsForSource {
            var tasksById: [String: BoardSources.SeededTargetTask] = [:]
            for (id, spec) in v.tasks {
                let type = try XCTUnwrap(TaskType(rawValue: spec.type), v.name)
                tasksById[id] = BoardSources.SeededTargetTask(type: type, maxCount: spec.maxCount)
            }
            XCTAssertEqual(
                BoardSources.seededTargetsForSource(
                    supplyTaskIds: v.supplyTaskIds,
                    tasksById: tasksById,
                    windowCountByTaskId: v.windowCountByTaskId,
                    sourceWindow: try v.sourceWindow.map { try window($0) },
                    targetWindow: try window(v.targetWindow)
                ),
                v.expected,
                v.name
            )
        }
    }

    func testMemberRuleFor() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.memberRuleFor.isEmpty)
        for v in section.memberRuleFor {
            XCTAssertEqual(
                BoardSources.memberRule(for: v.taskId, in: displaySource(v.memberRules)),
                v.expected,
                v.name
            )
        }
    }

    func testPartRuleFor() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.partRuleFor.isEmpty)
        for v in section.partRuleFor {
            XCTAssertEqual(
                BoardSources.partRule(for: v.childId, in: v.rule),
                v.expected,
                v.name
            )
        }
    }

    func testWithMemberRule() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.withMemberRule.isEmpty)
        for v in section.withMemberRule {
            var source = displaySource(v.startMemberRules)
            for step in v.steps {
                source = BoardSources.withMemberRule(
                    source, taskId: step.taskId, patch: try memberPatch(step.patch)
                )
            }
            try assertMemberRules(source, v.expectedMemberRules, v.name)
        }
    }

    func testWithPartRule() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.withPartRule.isEmpty)
        for v in section.withPartRule {
            var source = displaySource(v.startMemberRules)
            for step in v.steps {
                source = BoardSources.withPartRule(
                    source,
                    taskId: step.taskId,
                    childId: try XCTUnwrap(step.childId, v.name),
                    patch: try partPatch(step.patch)
                )
            }
            try assertMemberRules(source, v.expectedMemberRules, v.name)
        }
    }

    /// The TS twin freezes its input and asserts the setters don't throw;
    /// Swift has no analogue, because `BoardSource` is a value type taken by
    /// value — an "did the input mutate?" assertion is true by construction.
    /// So this test asserts two things that CAN fail: (a) the input's encoded
    /// bytes are unchanged even after the RESULT is mutated (the value-copy
    /// claim, stated in a form a future reader can trust rather than assume),
    /// and (b) the step SEMANTICS of each chain — the first step writes the
    /// field, the second (a clear) takes it away again — so the vectors pin
    /// behaviour, not the language.
    func testWithRuleSettersNeverMutateTheirInput() throws {
        let section = try loadFixture().display
        XCTAssertFalse(section.immutability.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for v in section.immutability {
            XCTAssertEqual(v.steps.count, 2, "\(v.name): expects a set-then-clear chain")
            let original = displaySource(v.startMemberRules)
            let before = try encoder.encode(original)

            var chain: [BoardSource] = []
            var current = original
            for step in v.steps {
                current = v.kind == "member"
                    ? BoardSources.withMemberRule(
                        current, taskId: step.taskId, patch: try memberPatch(step.patch)
                    )
                    : BoardSources.withPartRule(
                        current,
                        taskId: step.taskId,
                        childId: try XCTUnwrap(step.childId, v.name),
                        patch: try partPatch(step.patch)
                    )
                chain.append(current)
            }

            // Mutate the RESULT as hard as the type allows; the input must be
            // untouched afterwards.
            var mutated = try XCTUnwrap(chain.last, v.name)
            mutated.memberRules = ["mutated": BoardSourceMemberRule(target: 99)]
            mutated.excludedTaskIds.append("mutated")
            mutated.min = 99
            XCTAssertEqual(try encoder.encode(original), before,
                           "\(v.name): the source the chain started from is untouched")

            // Step semantics: written by step 1, gone after step 2.
            let step = v.steps[0]
            XCTAssertFalse(hasWrittenField(original, step), "\(v.name): not present to begin with")
            XCTAssertTrue(hasWrittenField(chain[0], step), "\(v.name): step 1 writes the field")
            XCTAssertFalse(hasWrittenField(chain[1], step), "\(v.name): step 2 clears it again")
        }
    }

    /// Whether the rule (or part rule) the step addresses carries ANY field.
    private func hasWrittenField(_ source: BoardSource, _ step: RawPatchStep) -> Bool {
        let rule = BoardSources.memberRule(for: step.taskId, in: source)
        guard let childId = step.childId else {
            return rule.target != nil || rule.vary != nil || rule.split != nil
        }
        let part = BoardSources.partRule(for: childId, in: rule)
        return part.target != nil || part.vary != nil || part.excluded != nil
    }
}
