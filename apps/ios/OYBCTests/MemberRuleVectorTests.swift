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
        let goal: CountValue
        let sourceDays: Int?
        let targetDays: Int?
        /// Absent = discrete (every pre-counter-kinds vector).
        let countKind: CountKind?
        let expected: CountValue
    }

    private struct VaryRangeVector: Decodable {
        let name: String
        let t: CountValue
        let level: Int
        let goal: CountValue
        let countKind: CountKind?
        let expected: [CountValue]
    }

    private struct RollTargetVector: Decodable {
        let name: String
        let t: CountValue
        let level: Int
        let goal: CountValue
        let seed: UInt32?
        let countKind: CountKind?
        let expected: CountValue
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
        let maxCount: CountValue?
        let sharedCounterId: String?
        let startDate: String?
        let operatorType: String?
        let threshold: Int?
        let countKind: CountKind?
        let createdInWizard: Bool?

        private enum CodingKeys: String, CodingKey {
            case type, title, action, unit, maxCount, sharedCounterId, startDate, threshold, countKind, createdInWizard
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
        /// Slice 3a — the board source's effective goal per supplied member.
        let goalByTaskId: [String: CountValue]?
    }

    /// One planned placement, as the fixture spells it and as the planner
    /// returns it (`targetKind` as its raw string) — compared whole.
    private struct ExpectedPlacement: Decodable, Equatable {
        struct Child: Decodable, Equatable {
            let childId: String
            let target: CountValue
        }
        let taskId: String
        var targetOverride: CountValue?
        var targetKind: String?
        var childTargets: [Child]?
        var titleOverride: String?
    }

    private struct ExpectedPlan: Decodable {
        let placements: [ExpectedPlacement]
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
        /// Overrides the section's board window when present.
        let window: RawWindow?
        let expected: ExpectedPlan
    }

    private struct PlanSection: Decodable {
        let boardId: String
        let window: RawWindow
        let tasks: [String: RawTask]
        let children: [String: [RawChild]]
        let sourceWindows: [String: String]
        let vectors: [PlanVector]
    }

    // MARK: - B3 fixture decoding (display + rule editing)

    private struct EffectiveTargetVector: Decodable {
        let name: String
        let goal: CountValue
        let explicit: CountValue?
        let mode: String
        let fromBoard: Bool
        /// Bare timeframe string; the harness wraps it into a `BoardWindow`
        /// with nil dates (fixture note `windows`). Absent = no source window.
        let sourceWindow: String?
        let targetWindow: String
        let countKind: CountKind?
        let expected: CountValue
    }

    private struct VaryRangeLabelVector: Decodable {
        let name: String
        let t: CountValue
        let level: Int
        let goal: CountValue
        let unit: String
        let countKind: CountKind?
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
        let goal: CountValue
        let windowCount: CountValue
        let countKind: CountKind?
        let expected: CountValue
    }

    private struct PrefilledOneOffTargetVector: Decodable {
        let name: String
        let goal: CountValue
        let windowCount: CountValue
        /// Bare timeframe string; absent = no source window (fixture note
        /// `windows`). `sourceWindowDates` / `targetWindowDates` carry the
        /// `[start, end]` bounds a CUSTOM window needs — a one-element array
        /// means the end bound is MISSING.
        let sourceWindow: String?
        let sourceWindowDates: [String]?
        let targetWindow: String
        let targetWindowDates: [String]?
        let countKind: CountKind?
        let expected: CountValue
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
            let target: CountValue?
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
        /// Fixture note `keepVaryOff`: absent = false (default pruning).
        let keepVaryOff: Bool?
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
        let target: CountValue
        let level: Int
        let goal: CountValue
        let unit: String
        let countKind: CountKind?
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
        let maxCount: CountValue?
        let countKind: CountKind?
    }

    private struct SeededTargetsVector: Decodable {
        let name: String
        let supplyTaskIds: [String]
        let tasks: [String: SeededTaskSpec]
        let windowCountByTaskId: [String: CountValue]
        /// Bare timeframe string; absent = no source window (fixture note
        /// `windows`) — the unknowable-span branch.
        let sourceWindow: String?
        let targetWindow: String
        let expected: [String: CountValue]
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

    // MARK: - Pool-level defaults fixture decoding (2026-10-06)

    /// The fixture's `pool` shape (note `shapes`): a MISSING `memberVary` key
    /// is the absent field, which `Pool` reads as an empty map.
    private struct RawPool: Decodable {
        let id: String
        let taskIds: [String]
        let memberVary: [String: Int]?
    }

    private struct RawSource: Decodable {
        let sourceId: String
        let kind: String
        let memberRules: [String: BoardSourceMemberRule]?
    }

    private struct PruneMemberVaryVector: Decodable {
        let name: String
        let memberVary: [String: Int]?
        let expected: [String: Int]
    }

    private struct EffectiveRulesVector: Decodable {
        let name: String
        let source: RawSource
        let pool: RawPool?
        let expected: [String: BoardSourceMemberRule]
        let unchangedSource: Bool
    }

    private struct ShouldKeepVaryOffVector: Decodable {
        let name: String
        let pool: RawPool?
        let taskId: String
        let expected: Bool
    }

    private struct PoolDefaultsSection: Decodable {
        let prunePoolMemberVary: [PruneMemberVaryVector]
        let effectiveMemberRules: [EffectiveRulesVector]
        let shouldKeepVaryOff: [ShouldKeepVaryOffVector]
    }

    private struct Fixture: Decodable {
        let windowDays: [WindowDaysVector]
        let autoTarget: [AutoTargetVector]
        let varyRange: [VaryRangeVector]
        let rollTarget: [RollTargetVector]
        let applyMemberRules: ApplySection
        let planDerivedTasks: PlanSection
        let display: DisplaySection
        let poolDefaults: PoolDefaultsSection
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
            sharedCounterId: raw.sharedCounterId,
            createdInWizard: raw.createdInWizard ?? false,
            countKind: raw.countKind
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
                BoardSources.autoTarget(
                    goal: v.goal, sourceDays: v.sourceDays, targetDays: v.targetDays,
                    kind: v.countKind ?? .discrete
                ),
                v.expected,
                v.name
            )
        }
    }

    func testVaryRange() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.varyRange.isEmpty)
        for v in fixture.varyRange {
            let range = BoardSources.varyRange(
                t: v.t, level: try varyLevel(v.level), goal: v.goal, kind: v.countKind ?? .discrete
            )
            XCTAssertEqual([range.lowerBound, range.upperBound], v.expected, v.name)
        }
    }

    func testRollTarget() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.rollTarget.isEmpty)
        for v in fixture.rollTarget {
            let rng: () -> Double
            var seededRng: SeededRng?
            if let seed = v.seed {
                let seeded = SeededRng(seed: seed)
                seededRng = seeded
                rng = { seeded.next() }
            } else {
                rng = {
                    XCTFail("rng must not be called — \(v.name)")
                    return 0
                }
            }
            XCTAssertEqual(
                BoardSources.rollTarget(
                    t: v.t, level: try varyLevel(v.level), goal: v.goal, rng: rng,
                    kind: v.countKind ?? .discrete
                ),
                v.expected,
                v.name
            )
            // Exactly one sample on a real roll (TS twin asserts the same).
            if let seededRng { XCTAssertEqual(seededRng.calls, 1, "\(v.name): rng sample count") }
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
        for v in plan.vectors {
            let boardWindow = try v.window.map {
                BoardSources.BoardWindow(
                    timeframe: try timeframe($0.timeframe), startDate: $0.startDate, endDate: $0.endDate
                )
            } ?? window
            let supplies = try v.supplies.enumerated().map { index, raw in
                BoardSources.ExpandedSupply(
                    source: try makeSource(
                        index: index + 1,
                        kind: raw.kind,
                        memberRules: raw.memberRules
                    ),
                    supplyTaskIds: raw.supply,
                    partOf: raw.partOf ?? [:],
                    goalByTaskId: raw.goalByTaskId
                )
            }
            let seeded = SeededRng(seed: v.seed)
            let out = BoardSources.planDerivedTasks(
                selectedIds: v.selected,
                supplies: supplies,
                manualTaskIds: v.manual,
                manualTaskVary: v.manualTaskVary,
                window: boardWindow,
                mode: v.mode == "recurring" ? .recurring : .oneOff,
                tasksById: tasksById,
                childrenByCompoundId: childrenByCompoundId,
                sourceWindowByTaskId: sourceWindowByTaskId,
                rng: { seeded.next() }
            )

            if let expectedCalls = v.expectedRngCalls {
                XCTAssertEqual(seeded.calls, expectedCalls, "\(v.name): rng sample count")
            }
            // The whole placement list, IN ORDER — the planner emits parameters, never rows.
            XCTAssertEqual(out.placements.map(Self.expectedShape), v.expected.placements, v.name)
        }
    }

    private static func expectedShape(_ p: BoardSources.PlannedPlacement) -> ExpectedPlacement {
        ExpectedPlacement(
            taskId: p.taskId,
            targetOverride: p.targetOverride,
            targetKind: p.targetKind?.rawValue,
            childTargets: p.childTargets.map { $0.map { .init(childId: $0.childId, target: $0.target) } },
            titleOverride: p.titleOverride
        )
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
                    targetWindow: try window(v.targetWindow),
                    kind: v.countKind ?? .discrete
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
                    t: v.t, level: try varyLevel(v.level), goal: v.goal, unit: v.unit,
                    kind: v.countKind ?? .discrete
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
                target: v.target, level: try varyLevel(v.level), goal: v.goal, unit: v.unit,
                kind: v.countKind ?? .discrete
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
                BoardSources.remainingTarget(
                    goal: v.goal, windowCount: v.windowCount, kind: v.countKind ?? .discrete
                ),
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
                    targetWindow: try window(v.targetWindow, v.targetWindowDates),
                    kind: v.countKind ?? .discrete
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
                tasksById[id] = BoardSources.SeededTargetTask(
                    type: type, maxCount: spec.maxCount, countKind: spec.countKind ?? .discrete
                )
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
                    source, taskId: step.taskId, patch: try memberPatch(step.patch),
                    keepVaryOff: step.keepVaryOff ?? false
                )
            }
            try assertMemberRules(source, v.expectedMemberRules, v.name)
        }
        let modes = Set(section.withMemberRule.flatMap { $0.steps.map { $0.keepVaryOff ?? false } })
        XCTAssertEqual(modes, [true, false], "the fixture pins both pruning modes")
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

    // MARK: - Pool-level defaults (docs/BOARD_SOURCES.md §Member rules → Pool-level defaults, 2026-10-06)

    private func varyMap(_ raw: [String: Int]?) throws -> [String: VaryLevel]? {
        guard let raw else { return nil }
        var out: [String: VaryLevel] = [:]
        for (k, v) in raw { out[k] = try varyLevel(v) }
        return out
    }

    /// A full `Pool` from the fixture's three fields — every other field is
    /// neutral (the helpers never read them).
    private func pool(_ raw: RawPool?) throws -> Pool? {
        guard let raw else { return nil }
        return Pool(
            id: raw.id, userId: "u1", name: "P", taskIds: raw.taskIds,
            memberVary: try varyMap(raw.memberVary) ?? [:],
            createdAt: Self.isoStamp, updatedAt: Self.isoStamp
        )
    }

    private func source(_ raw: RawSource) throws -> BoardSource {
        BoardSource(
            sourceId: raw.sourceId,
            kind: try XCTUnwrap(BoardSource.Kind(rawValue: raw.kind), "unknown kind \(raw.kind)"),
            min: 0, max: nil, excludedTaskIds: [], filter: .all, memberRules: raw.memberRules
        )
    }

    func testPrunePoolMemberVary() throws {
        let section = try loadFixture().poolDefaults
        XCTAssertFalse(section.prunePoolMemberVary.isEmpty)
        for v in section.prunePoolMemberVary {
            XCTAssertEqual(
                BoardSources.prunePoolMemberVary(try varyMap(v.memberVary)),
                try XCTUnwrap(try varyMap(v.expected)),
                v.name
            )
        }
    }

    func testShouldKeepVaryOff() throws {
        let section = try loadFixture().poolDefaults
        XCTAssertFalse(section.shouldKeepVaryOff.isEmpty)
        for v in section.shouldKeepVaryOff {
            XCTAssertEqual(
                BoardSources.shouldKeepVaryOff(pool: try pool(v.pool), taskId: v.taskId),
                v.expected,
                v.name
            )
        }
    }

    /// `effectiveMemberRules` pins the map; `withEffectiveMemberRules` pins
    /// that an un-inherited source comes back EQUAL (a rule-less source keeps
    /// `memberRules == nil`, never gains `[:]`) and an inherited one carries
    /// exactly the expected map with every other field untouched.
    func testEffectiveMemberRules() throws {
        let section = try loadFixture().poolDefaults
        XCTAssertFalse(section.effectiveMemberRules.isEmpty)
        XCTAssertEqual(Set(section.effectiveMemberRules.map(\.unchangedSource)), [true, false],
                       "the fixture pins both outcomes of unchangedSource")
        for v in section.effectiveMemberRules {
            let src = try source(v.source)
            let p = try pool(v.pool)
            XCTAssertEqual(BoardSources.effectiveMemberRules(source: src, pool: p), v.expected, v.name)

            let result = BoardSources.withEffectiveMemberRules(source: src, pool: p)
            if v.unchangedSource {
                XCTAssertEqual(result, src, v.name)
                XCTAssertEqual(result.memberRules, src.memberRules, v.name)
            } else {
                XCTAssertNotEqual(result, src, v.name)
                XCTAssertEqual(result.memberRules, v.expected, v.name)
                var stripped = result
                stripped.memberRules = src.memberRules
                XCTAssertEqual(stripped, src, "\(v.name): every other field rides along untouched")
            }
        }
    }
}
