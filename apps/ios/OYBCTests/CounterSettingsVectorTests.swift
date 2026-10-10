import XCTest
@testable import OYBC

/// Cross-platform vector pins for `CounterSettings` (Swift twin of
/// `packages/shared/src/algorithms/counterSettings.ts`) plus the
/// template-aware `TaskTitle.isAutoCounterTitle` / `counterCopyTitle`, driven
/// by the checked-in copy of `counterSettingsVectors.json` — the same fixture
/// `packages/shared/tests/algorithms/counterSettings.test.ts` runs
/// (docs/SHARED_COUNTER_SETTINGS.md §1).
final class CounterSettingsVectorTests: XCTestCase {

    private struct Goals: Decodable {
        let daily: Double?
        let weekly: Double?
        let monthly: Double?
        let yearly: Double?

        var value: CounterTimeframeGoals {
            CounterTimeframeGoals(daily: daily, weekly: weekly, monthly: monthly, yearly: yearly)
        }
    }

    private struct Root: Decodable {
        let title: String?
        let action: String?
        let unit: String?
        let maxCount: Double?
        let countKind: CountKind?
        let counterName: String?
        let titleTemplateSingular: String?
        let titleTemplatePlural: String?
        let timeframeGoals: Goals?

        var fields: CounterSettings.Fields {
            CounterSettings.Fields(
                title: title, action: action, unit: unit, maxCount: maxCount, countKind: countKind,
                counterName: counterName, titleTemplateSingular: titleTemplateSingular,
                titleTemplatePlural: titleTemplatePlural, timeframeGoals: timeframeGoals?.value
            )
        }

        var settings: CounterSettings.TitleSettings {
            CounterSettings.TitleSettings(
                counterName: counterName, titleTemplateSingular: titleTemplateSingular,
                titleTemplatePlural: titleTemplatePlural
            )
        }
    }

    private struct Pair: Decodable, Equatable {
        let singular: String
        let plural: String
    }

    private struct TemplatesVector: Decodable { let name: String; let root: Root; let expected: Pair }
    private struct RenderVector: Decodable { let name: String; let root: Root; let goal: Double?; let expected: String }
    private struct NameVector: Decodable { let name: String; let root: Root; let expected: String }
    private struct DerivedVector: Decodable { let name: String; let root: Root; let expected: Goals }
    private struct ResolveVector: Decodable {
        let name: String; let root: Root; let timeframe: String; let expected: Double?
    }
    private struct AutoVector: Decodable {
        let name: String; let title: String; let root: Root; let goal: Double?; let expected: Bool
    }
    private struct CopyVector: Decodable { let name: String; let member: Root; let newMaxCount: Double; let expected: String }

    private struct Context: Decodable {
        let action: String?, unit: String?, countKind: CountKind?
        var fields: CounterSettings.Fields { .init(action: action, unit: unit, countKind: countKind) }
    }
    private struct DraftJSON: Decodable {
        let name: String, singular: String, plural: String
        let goals: [String: Double?]
        var value: CounterSettings.Draft {
            var g: [CounterSettings.GoalTimeframe: CountValue] = [:]
            for (k, v) in goals { if let t = CounterSettings.GoalTimeframe(rawValue: k), let v { g[t] = v } }
            return .init(name: name, singular: singular, plural: plural, goals: g)
        }
    }
    private struct DefaultsExpected: Decodable {
        let name: String, singular: String, plural: String
        let goals: [String: Double?]
    }
    private struct DefaultsVector: Decodable {
        let name: String; let context: Context; let draft: DraftJSON; let expected: DefaultsExpected
    }
    private struct StoredExpected: Decodable {
        let counterName: String?, titleTemplateSingular: String?, titleTemplatePlural: String?
        let timeframeGoals: Goals?
    }
    private struct StoredVector: Decodable {
        let name: String; let context: Context; let draft: DraftJSON; let expected: StoredExpected
    }

    private struct Fixture: Decodable {
        let counterSettingsDefaults: [DefaultsVector]
        let storedCounterSettingsFromDraft: [StoredVector]
        let defaultTitleTemplates: [TemplatesVector]
        let effectiveTitleTemplates: [TemplatesVector]
        let renderCounterTitle: [RenderVector]
        let counterDisplayName: [NameVector]
        let derivedTimeframeGoals: [DerivedVector]
        let resolveCounterDefaultGoal: [ResolveVector]
        let isAutoCounterTitle: [AutoVector]
        let counterCopyTitle: [CopyVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CounterSettingsVectorTests.self).url(
            forResource: "counterSettingsVectors", withExtension: "json"
        ) else {
            XCTFail("counterSettingsVectors.json not found in test bundle — re-run xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    func testDefaultAndEffectiveTemplates() throws {
        let f = try loadFixture()
        for v in f.defaultTitleTemplates {
            let t = CounterSettings.defaultTitleTemplates(v.root.fields)
            XCTAssertEqual(Pair(singular: t.singular, plural: t.plural), v.expected, v.name)
        }
        for v in f.effectiveTitleTemplates {
            let t = CounterSettings.effectiveTitleTemplates(v.root.fields)
            XCTAssertEqual(Pair(singular: t.singular, plural: t.plural), v.expected, v.name)
        }
    }

    func testCounterSettingsDefaults() throws {
        let vectors = try loadFixture().counterSettingsDefaults
        XCTAssertFalse(vectors.isEmpty)
        for v in vectors {
            let d = CounterSettings.defaults(v.context.fields, draft: v.draft.value)
            XCTAssertEqual(d.name, v.expected.name, v.name)
            XCTAssertEqual(d.singular, v.expected.singular, v.name)
            XCTAssertEqual(d.plural, v.expected.plural, v.name)
            for t in CounterSettings.GoalTimeframe.allCases {
                XCTAssertEqual(d.goals[t] ?? nil, (v.expected.goals[t.rawValue] ?? nil), "\(v.name) \(t)")
            }
        }
    }

    func testStoredCounterSettingsFromDraft() throws {
        let vectors = try loadFixture().storedCounterSettingsFromDraft
        XCTAssertFalse(vectors.isEmpty)
        for v in vectors {
            let s = CounterSettings.stored(fromDraft: v.draft.value, context: v.context.fields)
            XCTAssertEqual(s.counterName, v.expected.counterName, v.name)
            XCTAssertEqual(s.titleTemplateSingular, v.expected.titleTemplateSingular, v.name)
            XCTAssertEqual(s.titleTemplatePlural, v.expected.titleTemplatePlural, v.name)
            XCTAssertEqual(s.timeframeGoals, v.expected.timeframeGoals?.value, v.name)
        }
    }

    func testDraftFromRootRoundTripsStored() {
        let root = CounterSettings.Fields(
            counterName: " Books ", titleTemplatePlural: "", timeframeGoals: CounterTimeframeGoals(weekly: 2, monthly: 0)
        )
        let draft = CounterSettings.draft(from: root)
        XCTAssertEqual(draft, .init(name: "Books", singular: "", plural: "", goals: [.weekly: 2]))
        XCTAssertEqual(CounterSettings.stored(root), CounterSettings.Stored(counterName: "Books", timeframeGoals: CounterTimeframeGoals(weekly: 2)))
    }

    func testRenderCounterTitle() throws {
        for v in try loadFixture().renderCounterTitle {
            XCTAssertEqual(CounterSettings.renderCounterTitle(v.root.fields, goal: v.goal), v.expected, v.name)
        }
    }

    func testCounterDisplayName() throws {
        for v in try loadFixture().counterDisplayName {
            XCTAssertEqual(CounterSettings.counterDisplayName(v.root.fields), v.expected, v.name)
        }
    }

    func testDerivedTimeframeGoals() throws {
        for v in try loadFixture().derivedTimeframeGoals {
            let d = CounterSettings.derivedTimeframeGoals(v.root.fields)
            XCTAssertEqual(d[.daily] ?? nil, v.expected.daily, "\(v.name) daily")
            XCTAssertEqual(d[.weekly] ?? nil, v.expected.weekly, "\(v.name) weekly")
            XCTAssertEqual(d[.monthly] ?? nil, v.expected.monthly, "\(v.name) monthly")
            XCTAssertEqual(d[.yearly] ?? nil, v.expected.yearly, "\(v.name) yearly")
        }
    }

    func testResolveCounterDefaultGoal() throws {
        for v in try loadFixture().resolveCounterDefaultGoal {
            let tf = try XCTUnwrap(Timeframe(rawValue: v.timeframe), v.name)
            XCTAssertEqual(CounterSettings.resolveCounterDefaultGoal(v.root.fields, timeframe: tf), v.expected, v.name)
        }
    }

    func testTemplateAwareIsAutoCounterTitle() throws {
        let vectors = try loadFixture().isAutoCounterTitle
        XCTAssertEqual(Set(vectors.map(\.expected)), [true, false])
        for v in vectors {
            XCTAssertEqual(
                TaskTitle.isAutoCounterTitle(
                    title: v.title, action: v.root.action ?? "", maxCount: v.goal, unit: v.root.unit ?? "",
                    countKind: v.root.countKind ?? .discrete, settings: v.root.settings
                ),
                v.expected, v.name
            )
        }
    }

    func testCounterCopyTitleWithRootTemplates() throws {
        for v in try loadFixture().counterCopyTitle {
            let m = v.member
            var task = Task(
                id: "m", userId: "u1", title: m.title ?? "", type: .counting, action: m.action, unit: m.unit,
                maxCount: m.maxCount, totalCompletions: 0, totalInstances: 0,
                createdAt: "2026-10-09T00:00:00.000Z", updatedAt: "2026-10-09T00:00:00.000Z", version: 1,
                isDeleted: false, countKind: m.countKind
            )
            task.titleTemplateSingular = m.titleTemplateSingular
            task.titleTemplatePlural = m.titleTemplatePlural
            task.counterName = m.counterName
            XCTAssertEqual(TaskTitle.counterCopyTitle(member: task, newMaxCount: v.newMaxCount), v.expected, v.name)
        }
    }

    /// Inert for untouched counters: every pre-existing generator vector
    /// renders identically through the template path when no template is
    /// stored (expected strings are the taskTitle fixture's).
    func testUntouchedCountersRenderLikeTheLegacyGenerator() throws {
        struct G: Decodable {
            let name: String; let action: String; let maxCount: Double?; let unit: String
            let providedTitle: String?; let countKind: CountKind?; let expected: String
        }
        struct F: Decodable { let generateCounterTaskTitle: [G] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "taskTitleVectors", withExtension: "json"))
        let f = try JSONDecoder().decode(F.self, from: Data(contentsOf: url))
        for v in f.generateCounterTaskTitle where (v.providedTitle ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = CounterSettings.Fields(action: v.action, unit: v.unit, countKind: v.countKind ?? .discrete)
            XCTAssertEqual(CounterSettings.renderCounterTitle(fields, goal: v.maxCount), v.expected, v.name)
        }
    }
}
