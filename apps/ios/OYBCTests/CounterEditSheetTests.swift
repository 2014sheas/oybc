import XCTest
import GRDB
@testable import OYBC

/// A counter is edited through the COUNTER sheet (`NewCounterSheetView` in
/// edit mode), never the task editor (owner rule 2026-10-09): the sheet's
/// pure model (`CounterEditModel`) prefills from the root and builds the
/// `applyTaskEditPatch` patch — the Task Detail write — so #575 + D5 apply
/// unchanged. Also: a shared counter's TYPE is fixed in every task editor,
/// including a board-born root other boards link to. Web twins:
/// `counterEditModel.test.ts`, `CreateCounterSheet.test.ts`,
/// `boardEditTaskSheetModel.test.ts` (typeLockedForEdit).
@MainActor
final class CounterEditSheetTests: XCTestCase {
    private typealias K = LinkedWindowKit

    private func root(title: String = "Run miles", kind: CountKind = .discrete, maxCount: CountValue? = nil) -> Task {
        var r = K.task("root", maxCount: maxCount, currentCount: 12, title: title)
        r.isCounter = maxCount == nil
        r.countKind = kind
        return r
    }

    // MARK: - CounterEditModel

    func test_seed_prefillsVerbNounKind() {
        let d = CounterEditModel.seed(root(kind: .continuous))
        XCTAssertEqual(d, CounterEditModel.Draft(verb: "Run", noun: "miles", kind: .continuous))
    }

    func test_patch_autoTitleFollows_kindOnlyWhenChanged_noGoalOrType() {
        var r = root()
        r.description = "keep me"
        let p = CounterEditModel.patch(root: r, draft: .init(verb: "Jog", noun: "km", kind: .discrete))
        XCTAssertEqual(p.title, "Jog km")
        XCTAssertEqual(p.action, "Jog")
        XCTAssertEqual(p.unit, "km")
        XCTAssertNil(p.countKind)
        XCTAssertNil(p.type)
        XCTAssertNil(p.compound)
        XCTAssertEqual(p.maxCountStr, "")
        XCTAssertEqual(p.description, "keep me")

        let k = CounterEditModel.patch(root: r, draft: .init(verb: "Run", noun: "miles", kind: .continuous))
        XCTAssertEqual(k.countKind, .continuous)
    }

    func test_patch_blankVerbIsDo_customTitleKept_boardBornGoalSwitches() {
        XCTAssertEqual(CounterEditModel.patch(root: root(), draft: .init(verb: " ", noun: "push-ups", kind: .discrete)).title, "Push-ups")
        XCTAssertEqual(CounterEditModel.patch(root: root(), draft: .init(verb: " ", noun: "push-ups", kind: .discrete)).action, "Do")
        XCTAssertEqual(
            CounterEditModel.patch(root: root(title: "Morning miles"), draft: .init(verb: "Jog", noun: "miles", kind: .discrete)).title,
            "Morning miles"
        )
        let bb = root(title: "Run 2.6 miles", kind: .continuous, maxCount: 2.6)
        XCTAssertEqual(CounterEditModel.patch(root: bb, draft: .init(verb: "Run", noun: "miles", kind: .discrete)).title, "Run 3 miles")
    }

    func test_identityChanged_andDedupePool_dropTheFamily() {
        let r = root()
        XCTAssertFalse(CounterEditModel.identityChanged(root: r, draft: .init(verb: "Run", noun: "miles", kind: .continuous)))
        XCTAssertTrue(CounterEditModel.identityChanged(root: r, draft: .init(verb: "Run", noun: "km", kind: .discrete)))
        let copy = K.task("copy", sharedCounterId: "root")
        var other = K.task("other")
        other.unit = "push-ups"
        XCTAssertEqual(CounterEditModel.dedupePool(root: r, tasks: [r, copy, other]).map(\.id), ["other"])
    }

    // MARK: - Save = applyTaskEditPatch (the Task Detail write)

    func test_save_renameAndKindSwitch_reachRootAndLiveCopy() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        let r = root()
        try db.saveTask(r)
        var copy = K.task("copy", maxCount: 10, sharedCounterId: "root", title: "Run 10 miles")
        copy.countKind = .discrete
        try db.saveTask(copy)

        try db.applyTaskEditPatch(
            taskId: "root",
            patch: CounterEditModel.patch(root: r, draft: .init(verb: "Jog", noun: "miles", kind: .continuous))
        )

        let savedRoot = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(savedRoot.title, "Jog miles")
        XCTAssertEqual(savedRoot.action, "Jog")
        XCTAssertEqual(savedRoot.countKind, .continuous)
        XCTAssertEqual(savedRoot.type, .counting)
        let savedCopy = try XCTUnwrap(K.fetchTask(db, "copy"))
        XCTAssertEqual(savedCopy.countKind, .continuous)
        XCTAssertEqual(savedCopy.action, "Jog")
        XCTAssertEqual(savedCopy.title, "Jog 10 miles")
    }

    func test_save_durationCounterKeepsItsNoun() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var r = root(kind: .duration)
        r.action = "Practice"
        r.unit = "piano"
        r.title = "Practice piano"
        try db.saveTask(r)
        try db.applyTaskEditPatch(
            taskId: "root",
            patch: CounterEditModel.patch(root: r, draft: .init(verb: "Play", noun: "piano", kind: .duration))
        )
        let saved = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(saved.unit, "piano")
        XCTAssertEqual(saved.title, "Play piano")
    }

    // MARK: - Counter Detail opens the counter sheet

    func test_counterDetail_editSheet_isTheCounterSheetInEditMode() {
        let sheet = CounterDetailView.editSheet(
            root: root(), userId: K.userId, tasks: [], database: .shared,
            onNavigateToCounter: { _ in }, onSaved: {}
        )
        XCTAssertEqual(sheet.root?.id, "root")
    }

    // MARK: - Type is fixed for any shared counter

    func test_showsPicker_falseForABoardBornRootWithLinkedCopies() {
        var boardBorn = K.task("bb")
        boardBorn.isCounter = false
        XCTAssertTrue(TaskTypeSwitch.showsPicker(task: boardBorn, original: nil))
        XCTAssertTrue(TaskTypeSwitch.showsPicker(task: boardBorn, original: nil, hasLinkedCopies: false))
        XCTAssertFalse(TaskTypeSwitch.showsPicker(task: boardBorn, original: nil, hasLinkedCopies: true))
        var simple = boardBorn
        simple.type = .normal
        XCTAssertTrue(TaskTypeSwitch.showsPicker(task: simple, original: nil, hasLinkedCopies: true),
                      "only a Counting task can be a counter root")
        XCTAssertFalse(SquareEditTaskSheet.showsTypePicker(task: boardBorn, original: nil, hasLinkedCopies: true))
    }
}
