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
        XCTAssertEqual(d, CounterEditModel.Draft(verb: "Run", noun: "miles", kind: .continuous, settings: .init()))
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

    func test_patch_customTitleKept_boardBornGoalSwitches_noDoSubstitution() {
        // A blank verb is no longer rewritten to "Do" (the sheet requires one).
        XCTAssertEqual(CounterEditModel.patch(root: root(), draft: .init(verb: " ", noun: "push-ups", kind: .discrete)).action, "")
        XCTAssertEqual(
            CounterEditModel.patch(root: root(title: "Morning miles"), draft: .init(verb: "Jog", noun: "miles", kind: .discrete)).title,
            "Morning miles"
        )
        let bb = root(title: "Run 2.6 miles", kind: .continuous, maxCount: 2.6)
        XCTAssertEqual(CounterEditModel.patch(root: bb, draft: .init(verb: "Run", noun: "miles", kind: .discrete)).title, "Run 3 miles")
    }

    // MARK: - Settings in the patch (docs/SHARED_COUNTER_SETTINGS.md §1)

    func test_seed_carriesTheStoredSettingsAsTypedText() {
        var r = root()
        r.counterName = "Miles"
        r.titleTemplateSingular = "Run #N mile"
        r.timeframeGoals = CounterTimeframeGoals(weekly: 10)
        let d = CounterEditModel.seed(r)
        XCTAssertEqual(d.settings, CounterSettings.Draft(name: "Miles", singular: "Run #N mile", plural: "", goals: [.weekly: 10]))
    }

    func test_patch_settingsNilWhenUnchanged_presentWhenChanged() {
        var r = root()
        r.counterName = "Miles"
        r.timeframeGoals = CounterTimeframeGoals(weekly: 10)
        var d = CounterEditModel.seed(r)
        XCTAssertNil(CounterEditModel.patch(root: r, draft: d).counterSettings)

        // Typing a template's dimmed default back is still "unchanged": a plural
        // equal to the default is absent.
        d.settings.plural = "Run #N miles"
        XCTAssertNil(CounterEditModel.patch(root: r, draft: d).counterSettings)

        // A typed Defaults cell is stored AS TYPED — even one equal to its
        // derived value (dropping it would move a derived cell the user saw).
        d.settings.goals[.monthly] = 43
        XCTAssertEqual(
            CounterEditModel.patch(root: r, draft: d).counterSettings?.timeframeGoals,
            CounterTimeframeGoals(weekly: 10, monthly: 43)
        )

        d.settings.singular = "Run #N mile"
        d.settings.goals[.daily] = 3
        let after = CounterEditModel.patch(root: r, draft: d).counterSettings
        XCTAssertEqual(after?.counterName, "Miles")
        XCTAssertEqual(after?.titleTemplateSingular, "Run #N mile")
        XCTAssertNil(after?.titleTemplatePlural)
        XCTAssertEqual(after?.timeframeGoals, CounterTimeframeGoals(daily: 3, weekly: 10, monthly: 43))

        // Clearing a stored setting writes the nil.
        d = CounterEditModel.seed(r)
        d.settings.name = ""
        let cleared = CounterEditModel.patch(root: r, draft: d).counterSettings
        XCTAssertNotNil(cleared)
        XCTAssertNil(cleared?.counterName)
    }

    func test_patch_goalLessRootTitleFollowsTheNewName() {
        let r = root()
        var d = CounterEditModel.seed(r)
        d.settings.name = "Mileage"
        let p = CounterEditModel.patch(root: r, draft: d)
        XCTAssertEqual(p.title, "Mileage")
        XCTAssertEqual(p.counterSettings?.counterName, "Mileage")
    }

    func test_save_settingsReachTheRootAndItsCopies() throws {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        let r = root()
        try db.saveTask(r)
        var d = CounterEditModel.seed(r)
        d.settings.name = "Mileage"
        d.settings.plural = "Ran #N miles"
        d.settings.goals = [.weekly: 10]
        try db.applyTaskEditPatch(taskId: "root", patch: CounterEditModel.patch(root: r, draft: d))
        let saved = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(saved.counterName, "Mileage")
        XCTAssertEqual(saved.titleTemplatePlural, "Ran #N miles")
        XCTAssertEqual(saved.timeframeGoals, CounterTimeframeGoals(weekly: 10))
        XCTAssertEqual(saved.title, "Mileage")
    }

    func test_identityChanged_trimsVerbsWithoutDoFallback() {
        let r = root()
        XCTAssertTrue(CounterEditModel.identityChanged(root: r, draft: .init(verb: "", noun: "miles", kind: .discrete)))
        XCTAssertFalse(CounterEditModel.identityChanged(root: r, draft: .init(verb: " Run ", noun: "miles ", kind: .discrete)))
    }

    // MARK: - CounterSheetForm

    func test_form_requiredFieldsAndErrors() {
        var f = CounterSheetForm()
        XCTAssertFalse(f.requiredFilled(isEditing: false))
        XCTAssertNil(f.error(for: .noun, touched: [], isEditing: false))
        XCTAssertEqual(f.error(for: .noun, touched: [.noun], isEditing: false), "Enter what you're counting.")
        XCTAssertEqual(f.error(for: .verb, touched: [.verb], isEditing: false), "Enter a verb.")
        f.noun = "books"
        XCTAssertFalse(f.requiredFilled(isEditing: false))
        f.verb = "Read"
        XCTAssertTrue(f.requiredFilled(isEditing: false))
        XCTAssertNil(f.error(for: .noun, touched: [.noun], isEditing: false))
    }

    func test_form_durationNounOptionalOnlyInEdit() {
        var f = CounterSheetForm(verb: "Practice", kind: .duration)
        XCTAssertTrue(f.requiredFilled(isEditing: true))
        XCTAssertFalse(f.requiredFilled(isEditing: false))
        XCTAssertNil(f.error(for: .noun, touched: [.noun], isEditing: true))
        f.kind = .discrete
        XCTAssertFalse(f.requiredFilled(isEditing: true))
    }

    func test_form_defaultsAreLiveAndGated() {
        var f = CounterSheetForm(verb: "Read", noun: "books", goalTexts: [.weekly: "7"])
        XCTAssertEqual(f.defaults.name, "Read books")
        XCTAssertEqual(f.shownTemplateDefault(f.defaults.plural), "Read #N books")
        XCTAssertEqual(f.defaults.goals[.daily] ?? nil, 1)
        f.noun = ""
        XCTAssertEqual(f.shownTemplateDefault(f.defaults.plural), "")
        XCTAssertTrue(CounterSheetForm(verb: "Practice", kind: .duration).shownTemplateDefault("Practice #N") == "Practice #N")
    }

    func test_form_storedSettingsDropTextDefaults_keepTypedGoals_andFlagBadGoals() {
        var f = CounterSheetForm(verb: "Read", noun: "books", name: "Read books", plural: "Read #N novels")
        f.goalTexts = [.weekly: "2", .monthly: "9"]
        let s = f.storedSettings
        XCTAssertNil(s.counterName)
        XCTAssertEqual(s.titleTemplatePlural, "Read #N novels")
        // Goals are stored as typed — monthly 9 equals its derivation but was typed.
        XCTAssertEqual(s.timeframeGoals, CounterTimeframeGoals(weekly: 2, monthly: 9))
        XCTAssertFalse(f.goalsInvalid)
        f.goalTexts[.daily] = "abc"
        XCTAssertTrue(f.goalsInvalid)
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

    func test_boardEdit_durationOverrideKeepsTheRowsUnit() {
        var r = root(kind: .duration, maxCount: 60)
        r.action = "Practice"
        r.unit = "piano"
        let override = StagedTaskOverride(title: "", type: .counting, action: "Practice", unit: "piano", maxCount: 90)
        let updated = BoardPlayViewModel.applyingOverride(override, to: r)
        XCTAssertEqual(updated.unit, "piano")
        XCTAssertEqual(updated.title, "Practice 1h 30m")
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

    /// Late-mutation guard: an unknown answer (nil) shows a Counting task's
    /// type FIXED, and the sheets' first-frame value comes from a synchronous
    /// read in `init` — so the picker never shows then disappears.
    func test_firstFrame_isLockedForALinkedRoot() throws {
        var boardBorn = K.task("bb")
        boardBorn.isCounter = false
        XCTAssertFalse(TaskTypeSwitch.showsPicker(task: boardBorn, original: nil, hasLinkedCopies: nil))
        var simple = boardBorn
        simple.type = .normal
        XCTAssertTrue(TaskTypeSwitch.showsPicker(task: simple, original: nil, hasLinkedCopies: nil))

        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(boardBorn)
        XCTAssertFalse(TaskTypeSwitch.initialHasLinkedCopies(task: boardBorn, database: db))
        try db.saveTask(K.task("copy", sharedCounterId: "bb"))
        XCTAssertTrue(TaskTypeSwitch.initialHasLinkedCopies(task: boardBorn, database: db))
        XCTAssertFalse(TaskTypeSwitch.initialHasLinkedCopies(task: simple, database: db), "only a Counting task is read")
    }
}
