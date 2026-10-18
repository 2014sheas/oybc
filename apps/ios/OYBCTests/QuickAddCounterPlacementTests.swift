import XCTest
import GRDB
@testable import OYBC

/// The quick-add / Board Edit picker's counter rows (docs/SHARED_COUNTER_SETTINGS.md §2):
/// which tasks are counter roots, the placement parameter a root's window goal
/// rides as (slice 3b: no copy is minted), and the pure models behind the
/// sheet's Template / Defaults fields.
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

    /// Owner bug report 2026-10-13: a search returns the COUNTER for every
    /// counter root — a plain counting task other tasks link to included.
    func testLinkedToRootIsACounterRoot() {
        var plain = counting(id: "p")
        plain.maxCount = 12
        let copy = counting(id: "c", sharedCounterId: "p")
        let ids = QuickAddCounterPlacement.counterRootIds(in: [plain, copy])
        XCTAssertTrue(QuickAddCounterPlacement.isSharedCounterRoot(plain, linkedRootIds: ids))
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(copy, linkedRootIds: ids))
        XCTAssertFalse(QuickAddCounterPlacement.isSharedCounterRoot(plain))
    }

    /// Owner bug report 2026-10-14: a counter root born in a June board's wizard
    /// carries June's window, yet it is the counter — the Tasks tab and the
    /// Library sheet keep listing it while hiding ordinary expired rows.
    func testExpiredForBrowse_exemptsCounterRoots() {
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        func june(_ t: Task) -> Task {
            var t = t
            t.timeframe = .monthly
            t.startDate = "2026-06-01T00:00:00.000"
            t.endDate = "2026-06-30T23:59:59.999"
            return t
        }
        XCTAssertFalse(QuickAddCounterPlacement.isExpiredForBrowse(june(counting(isCounter: true)), linkedRootIds: [], now: now))
        XCTAssertFalse(QuickAddCounterPlacement.isExpiredForBrowse(
            june(counting(goals: CounterTimeframeGoals(daily: 100))), linkedRootIds: [], now: now
        ))
        var plain = june(counting(id: "p"))
        plain.maxCount = 100
        let copy = june(counting(id: "c", sharedCounterId: "p"))
        let ids = QuickAddCounterPlacement.counterRootIds(in: [plain, copy])
        XCTAssertFalse(QuickAddCounterPlacement.isExpiredForBrowse(plain, linkedRootIds: ids, now: now)) // linked-to → a root
        XCTAssertTrue(QuickAddCounterPlacement.isExpiredForBrowse(plain, linkedRootIds: [], now: now))
        XCTAssertTrue(QuickAddCounterPlacement.isExpiredForBrowse(copy, linkedRootIds: ids, now: now))
        var normal = june(counting())
        normal.type = .normal
        XCTAssertTrue(QuickAddCounterPlacement.isExpiredForBrowse(normal, linkedRootIds: [], now: now))
        // In its window, or without an endDate: never expired.
        let inWindow = ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z")!
        XCTAssertFalse(QuickAddCounterPlacement.isExpiredForBrowse(plain, linkedRootIds: [], now: inWindow))
        XCTAssertFalse(QuickAddCounterPlacement.isExpiredForBrowse(counting(), linkedRootIds: [], now: now))
    }

    /// The compound editor's sub-task search lists every counter root as the
    /// counter (with or without its own goal), after the eligible tasks.
    func testCompoundSubCandidatesListEveryCounter() {
        var hubGoal = counting(id: "hubGoal", isCounter: true)
        hubGoal.maxCount = 12
        let hub = counting(id: "hub", isCounter: true)
        let defaults = counting(id: "defaults", goals: CounterTimeframeGoals(weekly: 2))
        var plain = counting(id: "plain")
        plain.maxCount = 5
        let library = [hub, hubGoal, defaults, plain]
        let result = QuickAddCounterPlacement.compoundSubCandidates(
            parentId: "P", eligible: [hubGoal, plain], library: library, lookup: library
        )
        XCTAssertEqual(result.counterIds, ["hub", "hubGoal", "defaults"])
        XCTAssertEqual(result.candidates.map(\.id), ["plain", "hub", "hubGoal", "defaults"])
        // A compound counting toward a counter never lists it.
        var parent = counting(id: "P")
        parent.type = .compound
        parent.countsTowardCounterId = "hubGoal"
        let towards = QuickAddCounterPlacement.compoundSubCandidates(
            parentId: "P", eligible: [hubGoal, plain], library: library, lookup: library + [parent]
        )
        XCTAssertEqual(towards.candidates.map(\.id), ["plain", "hub", "defaults"])
    }

    /// Owner rule 2026-10-13: one tap on a counter appends a complete linked
    /// Counting sub-task filled from it, the goal at the window's default; the
    /// counter is then not offered again in THIS compound.
    func testOneTapCounterSubAndPerCompoundExclusion() {
        var root = counting(id: "r", isCounter: true, goals: CounterTimeframeGoals(weekly: 3))
        root.currentCount = 9
        var draft = TaskEditPatch(title: "C")
        RisoCompoundEditFieldsView.appendCounterSub(root, window: .init(timeframe: .weekly), to: &draft)
        XCTAssertEqual(draft.children.count, 1)
        let child = draft.children[0]
        XCTAssertTrue(child.isCounting)
        XCTAssertEqual(child.action, "Read")
        XCTAssertEqual(child.unit, "books")
        XCTAssertEqual(child.goal, "3")
        XCTAssertEqual(child.title, "Read 3 books")
        XCTAssertEqual(child.sharedCounterId, "r")
        XCTAssertEqual(child.baseline, 9)

        let result = QuickAddCounterPlacement.compoundSubCandidates(
            parentId: "P", eligible: [root], library: [root], lookup: [root], draft: draft
        )
        XCTAssertFalse(result.counterIds.contains("r"), "already a sub-task of this compound")
        XCTAssertFalse(result.candidates.contains { $0.id == "r" }, "never offered as a plain task either")
        // Another compound (an empty draft) still offers it.
        XCTAssertTrue(QuickAddCounterPlacement.compoundSubCandidates(
            parentId: "Q", eligible: [], library: [root], lookup: [root], draft: TaskEditPatch(title: "D")
        ).counterIds.contains("r"))

        // A saved child whose task links to the counter counts too; a deleted one frees it.
        let saved = counting(id: "saved", sharedCounterId: "r")
        var savedDraft = TaskEditPatch(title: "C")
        savedDraft.children = [ChildPatch(id: "saved", childTaskId: "saved", title: "Read 3 books", isCounting: true)]
        XCTAssertEqual(QuickAddCounterPlacement.countersInDraft(savedDraft, all: [root, saved]), ["saved", "r"])
        savedDraft.children[0].markedDeleted = true
        XCTAssertTrue(QuickAddCounterPlacement.countersInDraft(savedDraft, all: [root, saved]).isEmpty)

        // Compound create: the linked new sub, and the per-compound exclusion set.
        let sub = RisoCompoundFieldsView.counterSub(root, goal: 3, kind: .discrete)
        XCTAssertEqual(RisoCompoundFieldsView.countersInSubs([sub, .newNormal(title: "x")]), ["r"])
    }

    /// Owner bug report 2026-10-12: a brand-new hub counter (no `maxCount`,
    /// no defaults) is browsable and found by its name, and placing it on any
    /// core board resolves the kind fallback — no Goal entry.
    func testHubCounterIsBrowsableAndResolvesTheKindFallback() {
        let hub = counting(id: "c1", isCounter: true)
        let browsable = BrowsableTasks.computeBrowsableTasks(tasks: [hub], boardTasks: [], boardStatusById: [:])
        XCTAssertEqual(browsable.map(\.id), ["c1"])
        let matches = CounterPlacement.rankedTaskMatches(browsable, query: "read", rootsById: [:])
        XCTAssertTrue(matches.contains { $0.id == "c1" }, "found by its name")
        let source = CounterPlacement.placementGoalSource(.init(task: hub), timeframe: .weekly)
        XCTAssertEqual(source, CounterPlacement.PlacementGoalSource(goal: 7, fromTimeframe: true))
        XCTAssertNil(
            CounterPlacement.placementGoalSource(.init(task: hub), timeframe: .custom),
            "a CUSTOM board without dates still asks for a goal"
        )
    }

    // MARK: - Placement parameters (slice 3b)

    func testForCounterGoalIsAnOverrideOnlyWhenItDiffersFromTheRootsGoal() {
        var root = counting(isCounter: true, kind: .duration)
        root.maxCount = 30
        XCTAssertNil(PlacementParamsDraft.forCounterGoal(30, root: root), "the plain root")
        XCTAssertNil(PlacementParamsDraft.forCounterGoal(0, root: root))
        let p = PlacementParamsDraft.forCounterGoal(90, root: root)
        XCTAssertEqual(p?.targetOverride, 90)
        XCTAssertEqual(p?.targetKind, .duration)
        XCTAssertNil(p?.titleOverride)
    }

    func testApplyReadsThePlacementGoalAndRendersTheTitleThroughTheRootsTemplates() {
        var root = counting(isCounter: true)
        root.maxCount = 4
        root.title = "Read 4 books"   // the auto title; a custom name would be carried verbatim
        root.titleTemplatePlural = "Read #N novels"
        let p = PlacementParamsDraft.forCounterGoal(12, root: root)!
        let shown = p.apply(to: root, root: root)
        XCTAssertEqual(shown.maxCount, 12)
        XCTAssertEqual(shown.title, "Read 12 novels")
        XCTAssertEqual(shown.id, "root")
    }

    func testOverlayWinsOverThePlannersFieldsAndKeepsItsChildTargets() {
        let planned = BoardSources.PlannedPlacement(
            taskId: "t", targetOverride: 5, targetKind: .discrete,
            childTargets: [PlacementChildTarget(childId: "c", target: 2)], titleOverride: "Planned"
        )
        let out = PlacementParamsDraft(targetOverride: 9, targetKind: .discrete).overlaying(planned)
        XCTAssertEqual(out.targetOverride, 9)
        XCTAssertEqual(out.titleOverride, "Planned")
        XCTAssertEqual(out.childTargets?.count, 1)
    }

    /// An active save: the root is placed as itself with the wizard's override
    /// on the row, and NO task row is created or enqueued.
    func testSaveWizardBoard_rootPlacementCarriesTheWizardParameter_andMintsNothing() throws {
        typealias K = LinkedWindowKit
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var rootTask = K.task("root", maxCount: nil, currentCount: 40)
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        let start = "2026-09-01T00:00:00.000Z", end = "2026-09-30T00:00:00.000Z"
        var board = K.board(id: "b1", startDate: start, endDate: end, size: 1)
        board.status = .active
        let tasksBefore = try db.read { try Task.fetchCount($0) }

        try db.saveWizardBoard(
            board: board, boardTasks: [K.placement(id: "bt", boardId: "b1", taskId: "root")],
            pendingTasks: [], isUpdate: false, manualTaskIds: ["root"],
            placementParams: ["root": PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)], now: start
        )

        let rows = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(rows.map(\.taskId), ["root"])
        XCTAssertEqual(rows.first?.targetOverride, 5)
        XCTAssertEqual(rows.first?.targetKind, .discrete)
        XCTAssertEqual(try db.read { try Task.fetchCount($0) }, tasksBefore, "no task row minted")
        XCTAssertNil(try K.fetchTask(db, BoardSources.derivedTaskId(boardId: "b1", rootTaskId: "root")))
        XCTAssertTrue(try K.queue(db, type: "tasks", id: "root").isEmpty, "the counter itself is not written")
    }

    /// A draft save places the original id with no parameters.
    func testSaveWizardBoard_draft_writesNoParameters() throws {
        typealias K = LinkedWindowKit
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        var rootTask = K.task("root", maxCount: nil, currentCount: 40)
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        let start = "2026-09-01T00:00:00.000Z", end = "2026-09-30T00:00:00.000Z"
        var board = K.board(id: "b1", startDate: start, endDate: end, size: 1)
        board.status = .draft
        try db.saveWizardBoard(
            board: board, boardTasks: [K.placement(id: "bt", boardId: "b1", taskId: "root")],
            pendingTasks: [], isUpdate: false, manualTaskIds: ["root"],
            placementParams: ["root": PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)], now: start
        )
        let row = try db.fetchBoardTasks(boardId: "b1").first
        XCTAssertEqual(row?.taskId, "root")
        XCTAssertNil(row?.targetOverride)
    }

    /// A typed goal on a hand-added counter row of a REPEATING wizard lands on the template.
    @MainActor func testRecurringPersist_typedGoalLandsAsManualTaskTargets() throws {
        typealias K = LinkedWindowKit
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("root", maxCount: 30))
        let vm = BoardWizardViewModel(preferences: .defaults, startRecurring: true, userId: K.userId, database: db)
        vm.name = "Weekly"
        vm.updateTimeframe(.weekly)
        vm.updateSize(1)
        vm.updateCenterType(.none)
        vm.toggleTaskSelection("root")
        vm.setPlacementParams(taskId: "root", PlacementParamsDraft(targetOverride: 9, targetKind: .discrete))

        let tasks = [ "root": try XCTUnwrap(K.fetchTask(db, "root")) ]
        let frozen = frozenManualTaskTargets(manualTaskIds: Array(vm.manualTaskIds), params: vm.placementParams, tasksById: tasks)
        XCTAssertEqual(frozen, ["root": ManualTaskTarget(target: 9, kind: .discrete, title: nil)])
        XCTAssertTrue(frozenManualTaskTargets(manualTaskIds: [], params: vm.placementParams, tasksById: tasks).isEmpty,
                      "only hand-added members freeze")

        let exp = expectation(description: "persist")
        var outcome: RecurringTemplatePersistOutcome?
        persistRecurringTemplate(
            controller: vm, userId: K.userId, database: db,
            onSuccess: { outcome = $0; exp.fulfill() }, onError: { XCTFail($0); exp.fulfill() }
        )
        wait(for: [exp], timeout: 10)
        XCTAssertNotNil(outcome)
        let stored = try db.read { try RecurringBoardTemplate.fetchAll($0) }
        XCTAssertEqual(stored.first?.manualTaskTargets?["root"]?.target, 9)
    }

    func testDraftBlobCarriesPlacementParams_andOmitsThemWhenEmpty() {
        let with = RecurringDraftMixPayload(
            poolIds: [], manualTaskIds: ["root"], removedTaskIds: [], sources: [],
            placementParams: ["root": PlacementParamsDraft(targetOverride: 5, targetKind: .discrete)]
        )
        let round = RecurringDraftMixPayload.decoded(from: with.encoded())
        XCTAssertEqual(round.placementParams["root"]?.targetOverride, 5)
        let empty = RecurringDraftMixPayload(poolIds: [], manualTaskIds: [], removedTaskIds: [], sources: [])
        XCTAssertFalse(empty.encoded()?.contains("placementParams") ?? true)
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
