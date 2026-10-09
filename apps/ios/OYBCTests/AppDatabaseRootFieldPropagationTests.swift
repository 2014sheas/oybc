import XCTest
import GRDB
@testable import OYBC

/// Board-scoped task edits PR 3 (docs/BOARD_SCOPED_TASK_EDITS.md §6): a hub
/// root's Task Detail edit (`applyTaskEditPatch`) propagates title / action /
/// unit to its LIVE per-board copies — never the goal, never a frozen /
/// deleted / sealed-board copy — with one authored write (version bump +
/// enqueue) per changed copy. Web twin: `saveTaskEdit.rootPropagation.test.ts`.
@MainActor
final class AppDatabaseRootFieldPropagationTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let now = "2026-10-08T12:00:00.000Z"
    // The live window outlasts the real clock too: the kind switch freezes on `Date()`.
    private let liveStart = "2026-10-05T00:00:00.000Z", liveEnd = "2099-12-31T23:59:59.999Z"
    private let endedStart = "2026-09-28T00:00:00.000Z", endedEnd = "2026-10-04T23:59:59.999Z"

    private func copy(_ id: String, goal: CountValue, start: String, end: String) -> Task {
        var row = K.task(id, maxCount: goal, sharedCounterId: "root", startDate: start, endDate: end,
                         createdInWizard: true, baseline: 0)
        row.title = TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: goal, unit: "miles")
        row.version = 4
        return row
    }

    /// Root + live / frozen / deleted / sealed-board copies, each placed on its own board.
    private func seedFamily(
        rootKind: CountKind? = nil, rootGoal: CountValue = 26, rootTitle: String = "Run 26 miles",
        liveGoal: CountValue = 10, liveTitle: String? = nil
    ) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var root = K.task("root", maxCount: rootGoal, title: rootTitle)
        root.countKind = rootKind
        root.isCounter = true
        try db.saveTask(root)
        var live = copy("c-live", goal: liveGoal, start: liveStart, end: liveEnd)
        live.countKind = rootKind
        live.title = liveTitle ?? TaskTitle.generateCounterTaskTitle(
            action: "Run", maxCount: liveGoal, unit: "miles", countKind: resolveCountKind(rootKind)
        )
        try db.saveTask(live)
        try db.saveTask(copy("c-frozen", goal: 8, start: endedStart, end: endedEnd))
        var deleted = copy("c-deleted", goal: 9, start: liveStart, end: liveEnd)
        deleted.isDeleted = true
        try db.saveTask(deleted)
        try db.saveTask(copy("c-sealed", goal: 7, start: liveStart, end: liveEnd))
        try db.saveBoard(K.board(id: "b-live", startDate: liveStart, endDate: liveEnd, timeframe: .weekly))
        try db.saveBoard(K.board(id: "b-frozen", startDate: endedStart, endDate: endedEnd, timeframe: .weekly))
        try db.saveBoard(K.board(id: "b-sealed", startDate: liveStart, endDate: liveEnd, timeframe: .weekly,
                                 sealedAt: "2026-10-07T12:00:00.000Z"))
        try db.saveBoardTask(K.placement(id: "bt-live", boardId: "b-live", taskId: "c-live"))
        try db.saveBoardTask(K.placement(id: "bt-frozen", boardId: "b-frozen", taskId: "c-frozen"))
        try db.saveBoardTask(K.placement(id: "bt-sealed", boardId: "b-sealed", taskId: "c-sealed"))
        try db.write { try SyncQueueItem.deleteAll($0) }
        return db
    }

    private func patch(
        title: String, action: String = "", unit: String = "", goal: String = "", countKind: CountKind? = nil
    ) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: "", action: action, unit: unit, maxCountStr: goal,
            trigger: .bingo, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            countKind: countKind
        )
    }

    private func queuedTaskIds(_ db: AppDatabase) throws -> [String] {
        try db.fetchPendingSyncItems().filter { $0.entityType == "tasks" }.map(\.entityId).sorted()
    }

    private func assertUntouched(_ db: AppDatabase, _ id: String, title: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(K.fetchTask(db, id), file: file, line: line)
        XCTAssertEqual(row.title, title, file: file, line: line)
        XCTAssertEqual(row.action, "Run", file: file, line: line)
        XCTAssertEqual(row.unit, "miles", file: file, line: line)
        XCTAssertEqual(row.version, 4, file: file, line: line)
    }

    func test_actionChange_regeneratesLiveAutoTitleFromItsOwnGoal_goalAndOtherCopiesUntouched() throws {
        let db = try seedFamily()
        try db.applyTaskEditPatch(
            taskId: "root", patch: patch(title: "Jog 30 miles", action: "Jog", unit: "miles", goal: "30"), now: now
        )

        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.title, "Jog 30 miles")
        XCTAssertEqual(root.maxCount, 30)
        let live = try XCTUnwrap(K.fetchTask(db, "c-live"))
        XCTAssertEqual(live.title, "Jog 10 miles")
        XCTAssertEqual(live.action, "Jog")
        XCTAssertEqual(live.maxCount, 10)
        XCTAssertEqual(live.version, 5)
        try assertUntouched(db, "c-frozen", title: "Run 8 miles")
        try assertUntouched(db, "c-sealed", title: "Run 7 miles")
        XCTAssertEqual(try K.fetchTask(db, "c-deleted")?.version, 4)
        XCTAssertEqual(try queuedTaskIds(db), ["c-live", "root"])
    }

    func test_customRootRename_carriesVerbatimToLiveCopy() throws {
        let db = try seedFamily()
        try db.applyTaskEditPatch(taskId: "root", patch: patch(title: "Marathon block"), now: now)
        let live = try XCTUnwrap(K.fetchTask(db, "c-live"))
        XCTAssertEqual(live.title, "Marathon block")
        XCTAssertEqual(live.maxCount, 10)
        XCTAssertEqual(live.version, 5)
        try assertUntouched(db, "c-frozen", title: "Run 8 miles")
    }

    func test_customCopyTitleKept_whenRootTitleStaysAuto() throws {
        let db = try seedFamily(liveTitle: "Morning run")
        try db.applyTaskEditPatch(taskId: "root", patch: patch(title: "Run 26 km", unit: "km"), now: now)
        let live = try XCTUnwrap(K.fetchTask(db, "c-live"))
        XCTAssertEqual(live.title, "Morning run")
        XCTAssertEqual(live.unit, "km")
        XCTAssertEqual(live.version, 5)
    }

    func test_goalOnlyEdit_writesNoCopy() throws {
        let db = try seedFamily()
        try db.applyTaskEditPatch(taskId: "root", patch: patch(title: "Run 40 miles", goal: "40"), now: now)
        try assertUntouched(db, "c-live", title: "Run 10 miles")
        XCTAssertEqual(try queuedTaskIds(db), ["root"])
    }

    func test_editingACopy_propagatesNothing() throws {
        let db = try seedFamily()
        try db.applyTaskEditPatch(taskId: "c-live", patch: patch(title: "Jog 10 miles", action: "Jog"), now: now)
        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.title, "Run 26 miles")
        XCTAssertEqual(root.version, 1)
        try assertUntouched(db, "c-sealed", title: "Run 7 miles")
        XCTAssertEqual(try queuedTaskIds(db), ["c-live"])
    }

    func test_plainTaskEdit_propagatesNothing() throws {
        let db = try seedFamily()
        var plain = K.task("plain", maxCount: nil, title: "Read")
        plain.type = .normal
        try db.saveTask(plain)
        try db.write { try SyncQueueItem.deleteAll($0) }
        try db.applyTaskEditPatch(taskId: "plain", patch: patch(title: "Read more"), now: now)
        try assertUntouched(db, "c-live", title: "Run 10 miles")
        XCTAssertEqual(try queuedTaskIds(db), ["plain"])
    }

    func test_kindSwitchPlusActionChange_oneAuthoredWritePerCopyCarryingBoth() throws {
        let db = try seedFamily(rootKind: .continuous, rootGoal: 26.2, rootTitle: "Run 26.2 miles", liveGoal: 10.5)
        XCTAssertEqual(try K.fetchTask(db, "c-live")?.title, "Run 10.5 miles")

        try db.applyTaskEditPatch(
            taskId: "root",
            patch: patch(title: "Jog 26 miles", action: "Jog", unit: "miles", goal: "26", countKind: .discrete),
            now: now
        )

        let live = try XCTUnwrap(K.fetchTask(db, "c-live"))
        XCTAssertEqual(live.countKind, .discrete)
        XCTAssertEqual(live.maxCount, 11)
        XCTAssertEqual(live.title, "Jog 11 miles")
        XCTAssertEqual(live.action, "Jog")
        XCTAssertEqual(live.version, 5)
        let items = try K.queue(db, type: "tasks", id: "c-live")
        XCTAssertEqual(items.count, 1)
        let payload = try XCTUnwrap(items.first?.payload.data(using: .utf8))
        let queued = try JSONDecoder().decode(Task.self, from: payload)
        XCTAssertEqual(queued.title, "Jog 11 miles")
        XCTAssertEqual(queued.version, 5)
    }
}
