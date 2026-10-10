import XCTest
import GRDB
@testable import OYBC

/// Shared counter settings PR 1 (docs/SHARED_COUNTER_SETTINGS.md §1) on iOS —
/// data + logic only (the sheet UI follows the design handoff): the GRDB v42
/// columns, the save through `applyTaskEditPatch` with `counterSettings`
/// (incl. the NULL-clear the nil-skipping encoder can't do), root → copy
/// propagation of a name / template edit, create with settings, and the
/// display-name read. Web twin: `counterEditModel.test.ts` (saveTaskEdit).
@MainActor
final class CounterSettingsEditTests: XCTestCase {
    private typealias K = LinkedWindowKit

    private func root() -> Task {
        var r = K.task("root", maxCount: nil, currentCount: 12, title: "Run miles")
        r.isCounter = true
        r.countKind = .discrete
        return r
    }

    /// A counter-root patch: the root's own fields, plus the post-edit settings.
    private func patch(_ r: Task, title: String, settings: CounterSettings.Stored?) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: "", action: r.action ?? "", unit: r.unit ?? "", maxCountStr: "",
            trigger: .bingo, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            counterSettings: settings
        )
    }

    func test_v42_columnsRoundTrip_timeframeGoalsAsJSON() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var r = root()
        r.counterName = "Running"
        r.titleTemplateSingular = "Run #N mile"
        r.titleTemplatePlural = "Run #N miles!"
        r.timeframeGoals = CounterTimeframeGoals(daily: 2, yearly: 500)
        try db.saveTask(r)
        let raw = try db.read { try String.fetchOne($0, sql: "SELECT timeframeGoals FROM tasks WHERE id = 'root'") }
        XCTAssertEqual(raw, #"{"daily":2,"yearly":500}"#)
        let back = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(back.counterName, "Running")
        XCTAssertEqual(back.titleTemplateSingular, "Run #N mile")
        XCTAssertEqual(back.titleTemplatePlural, "Run #N miles!")
        XCTAssertEqual(back.timeframeGoals, CounterTimeframeGoals(daily: 2, yearly: 500))
    }

    func test_untouchedRow_decodesAllFourAsNil() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(root())
        let back = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertNil(back.counterName)
        XCTAssertNil(back.titleTemplateSingular)
        XCTAssertNil(back.titleTemplatePlural)
        XCTAssertNil(back.timeframeGoals)
    }

    func test_save_settingsReachRoot_rerenderAutoCopies_keepCustom_thenClearToAbsent() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        let r = root()
        try db.saveTask(r)
        try db.saveTask(K.task("copy", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles"))
        try db.saveTask(K.task("one", maxCount: 1, sharedCounterId: "root", title: "Run 1 miles"))
        try db.saveTask(K.task("custom", maxCount: 10, sharedCounterId: "root", title: "Morning run"))

        let settings = CounterSettings.Stored(
            counterName: "Running", titleTemplateSingular: "Jog #N mile", titleTemplatePlural: "Jog #N miles",
            timeframeGoals: CounterTimeframeGoals(weekly: 20)
        )
        try db.applyTaskEditPatch(taskId: "root", patch: patch(r, title: "Running", settings: settings))
        let saved = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(saved.counterName, "Running")
        XCTAssertEqual(saved.titleTemplatePlural, "Jog #N miles")
        XCTAssertEqual(saved.timeframeGoals, CounterTimeframeGoals(weekly: 20))
        XCTAssertEqual(saved.title, "Running")
        XCTAssertEqual(CounterSettings.counterDisplayName(saved), "Running")
        XCTAssertEqual(try K.fetchTask(db, "copy")?.title, "Jog 10 miles")
        XCTAssertEqual(try K.fetchTask(db, "one")?.title, "Jog 1 mile")
        XCTAssertEqual(try K.fetchTask(db, "custom")?.title, "Morning run")

        try db.applyTaskEditPatch(taskId: "root", patch: patch(saved, title: "Run miles", settings: .init()))
        let cleared = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertNil(cleared.counterName)
        XCTAssertNil(cleared.titleTemplateSingular)
        XCTAssertNil(cleared.titleTemplatePlural)
        XCTAssertNil(cleared.timeframeGoals)
        XCTAssertEqual(CounterSettings.counterDisplayName(cleared), "Run miles")
        XCTAssertEqual(try K.fetchTask(db, "copy")?.title, "Run 10 miles")
        // The queued payload omits the cleared keys, so the push deletes them (clearable fields).
        let payload = try XCTUnwrap(K.queue(db, type: "tasks", id: "root").last?.payload)
        XCTAssertFalse(payload.contains("counterName"))
        XCTAssertFalse(payload.contains("timeframeGoals"))
    }

    func test_patchWithoutSettings_leavesStoredSettings_andAutoCopiesFollowTheirTemplates() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var r = root()
        r.counterName = "Running"
        r.titleTemplatePlural = "Run #N miles!"
        try db.saveTask(r)
        try db.saveTask(K.task("copy", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles!"))
        // The sheet seeds the stored settings, so an untouched settings section writes nothing.
        var draft = CounterEditModel.seed(r)
        draft.verb = "Jog"
        XCTAssertNil(CounterEditModel.patch(root: r, draft: draft).counterSettings)
        try db.applyTaskEditPatch(taskId: "root", patch: CounterEditModel.patch(root: r, draft: draft))
        let saved = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(saved.counterName, "Running")
        XCTAssertEqual(saved.titleTemplatePlural, "Run #N miles!")
        let copy = try XCTUnwrap(K.fetchTask(db, "copy"))
        XCTAssertEqual(copy.action, "Jog")
        XCTAssertEqual(copy.title, "Run 10 miles!")
    }

    func test_create_storesOnlyGivenSettings_titleIsTheName() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        let t = try db.createCounterTask(
            userId: K.userId, action: "Read", unit: "books", startingCount: nil,
            settings: CounterSettings.Stored(counterName: "Books", titleTemplatePlural: "  "),
            now: "2026-10-09T00:00:00.000Z"
        )
        let saved = try XCTUnwrap(K.fetchTask(db, t.id))
        XCTAssertEqual(saved.title, "Books")
        XCTAssertEqual(saved.counterName, "Books")
        XCTAssertNil(saved.titleTemplatePlural)
        XCTAssertNil(saved.timeframeGoals)
    }

    func test_hubGroupName_readsCounterName() {
        var r = root()
        XCTAssertEqual(CounterSettings.counterDisplayName(r), "Run miles")
        r.counterName = "Running"
        XCTAssertEqual(CounterSettings.counterDisplayName(r), "Running")
    }
}
