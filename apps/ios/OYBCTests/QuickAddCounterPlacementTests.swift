import XCTest
import GRDB
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

    func testPendingLinkedTaskCarriesTheHostBoardWindow_andIsALinkedPendingPayload() {
        let root = counting(isCounter: true)
        let payload = QuickAddCounterPlacement.pendingLinkedTask(
            root: root, goal: 3, userId: "u1", now: "n",
            timeframe: .weekly, startDate: "2026-10-05T00:00:00.000", endDate: "2026-10-11T23:59:59.999"
        )
        XCTAssertEqual(payload.task.timeframe, .weekly)
        XCTAssertEqual(payload.task.startDate, "2026-10-05T00:00:00.000")
        XCTAssertEqual(payload.task.endDate, "2026-10-11T23:59:59.999")
        XCTAssertTrue(QuickAddCounterPlacement.isLinkedPendingPayload(payload))
        var plain = payload.task
        plain.sharedCounterId = nil
        XCTAssertFalse(QuickAddCounterPlacement.isLinkedPendingPayload(
            PendingTaskPayload(task: plain, childTasks: [], childLinks: [])
        ))
    }

    // MARK: - Persist seam: a replaced linked pending row is never written

    /// An active one-off save with a hand-added linked pending row: the board
    /// places `derivedTaskId(board, root)` at the typed goal, and the pending
    /// row — written only so the planner could read it — leaves the
    /// transaction unwritten and unenqueued (no orphan member on Counter Detail).
    func testSaveWizardBoard_replacedLinkedPendingRow_isNeverPersistedOrEnqueued() throws {
        typealias K = LinkedWindowKit
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var rootTask = K.task("root", maxCount: nil, currentCount: 40)
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        let start = "2026-09-01T00:00:00.000Z", end = "2026-09-30T00:00:00.000Z"
        var board = K.board(id: "b1", startDate: start, endDate: end, size: 1)
        board.status = .active
        let pending = QuickAddCounterPlacement.pendingLinkedTask(
            root: rootTask, goal: 5, userId: K.userId, now: start,
            timeframe: .monthly, startDate: start, endDate: end
        )
        let row = K.placement(id: "bt", boardId: "b1", taskId: pending.task.id)

        try db.saveWizardBoard(
            board: board, boardTasks: [row], pendingTasks: [pending],
            isUpdate: false, manualTaskIds: [pending.task.id], now: start
        )

        let copyId = BoardSources.derivedTaskId(boardId: "b1", rootTaskId: "root")
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").map(\.taskId), [copyId])
        XCTAssertEqual(try K.fetchTask(db, copyId)?.maxCount, 5)
        XCTAssertNil(try K.fetchTask(db, pending.task.id), "the replaced pending row is not written")
        XCTAssertTrue(try K.queue(db, type: "tasks", id: pending.task.id).isEmpty, "…and not enqueued")
        XCTAssertFalse(try K.queue(db, type: "tasks", id: copyId).isEmpty, "the copy is")
        let linked = try db.read { try Task.filter(Column("sharedCounterId") == "root").fetchAll($0).map(\.id) }
        XCTAssertEqual(linked, [copyId], "exactly one row links to the root — no ghost member")
    }

    /// A draft save keeps the pending row (the draft's placement references it) and mints nothing.
    func testSaveWizardBoard_draft_keepsTheLinkedPendingRow() throws {
        typealias K = LinkedWindowKit
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var rootTask = K.task("root", maxCount: nil, currentCount: 40)
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        let start = "2026-09-01T00:00:00.000Z", end = "2026-09-30T00:00:00.000Z"
        var board = K.board(id: "b1", startDate: start, endDate: end, size: 1)
        board.status = .draft
        let pending = QuickAddCounterPlacement.pendingLinkedTask(
            root: rootTask, goal: 5, userId: K.userId, now: start,
            timeframe: .monthly, startDate: start, endDate: end
        )
        try db.saveWizardBoard(
            board: board, boardTasks: [K.placement(id: "bt", boardId: "b1", taskId: pending.task.id)],
            pendingTasks: [pending], isUpdate: false, manualTaskIds: [pending.task.id], now: start
        )
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").map(\.taskId), [pending.task.id])
        XCTAssertNotNil(try K.fetchTask(db, pending.task.id))
        XCTAssertNil(try K.fetchTask(db, BoardSources.derivedTaskId(boardId: "b1", rootTaskId: "root")))
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
