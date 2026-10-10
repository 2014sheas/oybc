import XCTest
@testable import OYBC

/// The quick-add / Board Edit picker's counter rows (docs/SHARED_COUNTER_SETTINGS.md §2):
/// which tasks are counter roots, the pending LINKED task a goal-less root is
/// placed as, and the pure models behind the sheet's Template / Defaults fields.
final class QuickAddCounterPlacementTests: XCTestCase {

    private func counting(
        id: String = "root", sharedCounterId: String? = nil, isCounter: Bool = false,
        goals: CounterTimeframeGoals? = nil, kind: CountKind? = nil
    ) -> Task {
        var t = Task(
            id: id, userId: "u1", title: "Read books", type: .counting, action: "Read", unit: "books",
            totalCompletions: 0, totalInstances: 0, currentCount: 7,
            createdAt: "2026-10-10T00:00:00.000", updatedAt: "2026-10-10T00:00:00.000",
            version: 1, isDeleted: false, sharedCounterId: sharedCounterId, isCounter: isCounter
        )
        t.timeframeGoals = goals
        t.countKind = kind
        return t
    }

    func testSharedCounterRootDetection() {
        XCTAssertTrue(QuickAddCounterPlacement.isSharedCounterRoot(counting(isCounter: true)))
        XCTAssertTrue(QuickAddCounterPlacement.isSharedCounterRoot(counting(goals: CounterTimeframeGoals(weekly: 2))))
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(counting()))
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(counting(goals: CounterTimeframeGoals())))
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(counting(sharedCounterId: "x", isCounter: true)))
        var normal = counting(isCounter: true)
        normal.type = .normal
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(normal))
    }

    func testPendingLinkedTaskIsALinkedRowWithoutAWindow() {
        var root = counting(isCounter: true)
        root.titleTemplatePlural = "Read #N novels"
        let payload = QuickAddCounterPlacement.pendingLinkedTask(
            root: root, goal: 12, userId: "u2", now: "2026-10-10T10:00:00.000"
        )
        let t = payload.task
        XCTAssertNotEqual(t.id, root.id)
        XCTAssertEqual(t.userId, "u2")
        XCTAssertEqual(t.type, .counting)
        XCTAssertEqual(t.action, "Read")
        XCTAssertEqual(t.unit, "books")
        XCTAssertEqual(t.maxCount, 12)
        XCTAssertEqual(t.sharedCounterId, "root")
        XCTAssertEqual(t.baseline, 7)
        XCTAssertEqual(t.title, "Read 12 novels")
        XCTAssertTrue(t.createdInWizard)
        XCTAssertFalse(t.isCounter)
        XCTAssertNil(t.countKind)
        XCTAssertNil(t.timeframe)
        XCTAssertNil(t.startDate)
        XCTAssertNil(t.endDate)
        XCTAssertTrue(payload.childTasks.isEmpty)
        XCTAssertTrue(payload.childLinks.isEmpty)
    }

    func testPendingLinkedTaskKeepsANonDiscreteKindAndZeroBaseline() {
        var root = counting(isCounter: true, kind: .duration)
        root.currentCount = nil
        let t = QuickAddCounterPlacement.pendingLinkedTask(root: root, goal: 90, userId: "u1", now: "n").task
        XCTAssertEqual(t.countKind, .duration)
        XCTAssertEqual(t.baseline, 0)
        XCTAssertEqual(t.title, "Read 1h 30m")
    }

    func testTemplateFieldExampleCountsAndRendering() {
        XCTAssertEqual(TemplateFieldModel.exampleCount(plural: false, kind: .duration), 1)
        XCTAssertEqual(TemplateFieldModel.exampleCount(plural: true, kind: .discrete), 12)
        XCTAssertEqual(TemplateFieldModel.exampleCount(plural: true, kind: .continuous), 2.5)
        XCTAssertEqual(TemplateFieldModel.exampleCount(plural: true, kind: .duration), 90)
        XCTAssertEqual(TemplateFieldModel.rendered(typed: "", derived: "Read #N books", count: 12, kind: .discrete), "Read 12 books")
        XCTAssertEqual(TemplateFieldModel.rendered(typed: " Read #N novels ", derived: "x", count: 1, kind: .discrete), "Read 1 novels")
        XCTAssertEqual(TemplateFieldModel.rendered(typed: "Book club", derived: "", count: 12, kind: .discrete), "Book club")
        XCTAssertEqual(TemplateFieldModel.rendered(typed: "", derived: "Practice #N", count: 90, kind: .duration), "Practice 1h 30m")
        XCTAssertEqual(TemplateFieldModel.rendered(typed: "", derived: "", count: 1, kind: .discrete), "")
    }

    func testDefaultsRowCellsAndValidation() {
        let derived = DefaultsRowModel.cell(entered: nil, derived: 43, kind: .discrete)
        XCTAssertEqual(derived.text, "43")
        XCTAssertTrue(derived.dim)
        let solid = DefaultsRowModel.cell(entered: "5", derived: 43, kind: .discrete)
        XCTAssertEqual(solid.text, "5")
        XCTAssertFalse(solid.dim)
        let empty = DefaultsRowModel.cell(entered: "  ", derived: nil, kind: .discrete)
        XCTAssertEqual(empty.text, "")
        XCTAssertTrue(empty.dim)

        let texts: [CounterSettings.GoalTimeframe: String] = [.daily: "2", .weekly: "", .monthly: "x", .yearly: "0"]
        XCTAssertEqual(DefaultsRowModel.goals(from: texts, kind: .discrete), [.daily: 2])
        XCTAssertEqual(DefaultsRowModel.invalid(texts, kind: .discrete), [.monthly, .yearly])
        XCTAssertEqual(DefaultsRowModel.texts(from: [.weekly: 2.5], kind: .continuous), [.weekly: "2.5"])
    }
}
