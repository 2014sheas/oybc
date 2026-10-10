import XCTest
import GRDB
@testable import OYBC

/// "Counts toward" PR 4 (iOS half) — the Counter Detail section's data, the
/// editors' write path (`setCountsToward(db:…)`, `applyTaskEditPatch`, Board
/// Edit's staged override), the create form, the credited-boards reader and the
/// completion-moment toast. Web twins: `countsTowardSection.test.ts`,
/// `taskEditCountsToward.test.ts`, `boardEditCommit.countsToward.test.ts`.
@MainActor
final class CountsTowardUITests: XCTestCase {

    private let user = "user-1"
    private let t0 = "2026-01-01T00:00:00.000Z"
    private let root = "00000000-0000-4000-8000-0000000000a1"
    private let root2 = "00000000-0000-4000-8000-0000000000a2"
    private let copy = "00000000-0000-4000-8000-0000000000a3"
    private let simple = "00000000-0000-4000-8000-0000000000b1"
    private let loose = "00000000-0000-4000-8000-0000000000b2"
    private let boxId = "00000000-0000-4000-8000-0000000000d1"
    private let kid = "00000000-0000-4000-8000-0000000000c1"
    private let bA = "00000000-0000-4000-8000-0000000000e1"
    private let bB = "00000000-0000-4000-8000-0000000000e2"
    private let bC = "00000000-0000-4000-8000-0000000000e3"
    private let start = "2026-10-12T00:00:00.000Z"
    private let end = "2099-12-31T23:59:59.999Z"
    private let now = "2026-10-14T09:00:00.000Z"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.saveUser(User(
            id: user, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func task(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil, sharedCounterId: String? = nil,
        isCounter: Bool = false, countKind: CountKind? = nil, title: String? = nil, forked: String? = nil,
        countsToward: String? = nil, amount: Int? = nil
    ) -> Task {
        Task(
            id: id, userId: user, title: title ?? id, type: type,
            action: type == .counting ? "Read" : nil, unit: type == .counting ? "books" : nil,
            maxCount: maxCount, operatorType: type == .compound ? .and : nil, totalCompletions: 0, totalInstances: 0,
            currentCount: type == .counting ? 0 : nil, createdAt: t0, updatedAt: t0, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: sharedCounterId == nil ? nil : 0,
            isCounter: isCounter, countKind: countKind, forkedFromTaskId: forked,
            countsTowardCounterId: countsToward, countsTowardAmount: amount,
            countsTowardSince: countsToward == nil ? nil : t0
        )
    }

    private func board(_ id: String, timeframe: Timeframe = .weekly, status: BoardStatus = .active, sealedAt: String? = nil) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": user, "name": "Board \(id.suffix(2))", "status": status.rawValue, "boardSize": 3,
            "timeframe": timeframe.rawValue, "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt; dict["sealedCompletedCells"] = "[]" }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func placement(_ id: String, _ boardId: String, _ taskId: String, col: Int = 0) -> BoardTask {
        BoardTask(id: id, boardId: boardId, taskId: taskId, row: 0, col: col, isCenter: false,
                  createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1)
    }

    private func completion(_ id: String, _ taskId: String, _ at: String) -> TaskEvent {
        TaskEvent(id: id, userId: user, taskId: taskId, kind: .completion, delta: nil, occurredAt: at, boardId: nil,
                  createdAt: at, updatedAt: at, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil)
    }

    private func fetch(_ db: AppDatabase, _ id: String) throws -> Task {
        try XCTUnwrap(try db.fetchTask(id: id))
    }

    private func queueCount(_ db: AppDatabase, _ id: String) throws -> Int {
        try db.read { try SyncQueueItem.filter(Column("entityId") == id).fetchCount($0) }
    }

    /// Root counter "Read" + a done Simple on board A + an unplaced Simple.
    private func seedSection(_ db: AppDatabase) throws {
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple, title: "Read Dune", countsToward: root).save(d)
            try task(loose, title: "Read Emma", countsToward: root, amount: 2).save(d)
            try board(bA, timeframe: .yearly).save(d)
            try placement("bt-simple", bA, simple).save(d)
            try completion("c-simple", simple, "2026-10-13T10:00:00.000Z").insert(d)
        }
    }

    // MARK: - C1 section data

    func test_section_rowsTitlesBoardsAndHandoffOrder() throws {
        let db = try makeDb()
        try seedSection(db)
        let data = try XCTUnwrap(try db.fetchCountsTowardSection(counterId: root))
        XCTAssertEqual(data.counterName, CounterSettings.counterDisplayName(try fetch(db, root)))
        // Done first, then Not started (the unplaced lifetime state).
        XCTAssertEqual(data.rows.map(\.taskId), [simple, loose])
        XCTAssertEqual(data.rows.map(\.status), [.done, .notStarted])
        XCTAssertEqual(data.rows[0].boardId, bA)
        XCTAssertNil(data.rows[1].boardId)
        XCTAssertEqual(data.rows[1].amount, 2)
        XCTAssertEqual(data.taskById[simple]?.title, "Read Dune")
        XCTAssertEqual(data.boardById[bA]?.timeframe, .yearly)
    }

    func test_section_emptyForACounterNothingCountsToward() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let data = try XCTUnwrap(try db.fetchCountsTowardSection(counterId: root))
        XCTAssertTrue(data.rows.isEmpty)
    }

    func test_section_hiddenForNonDiscreteAndMissingCounters() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true, countKind: .continuous))
        XCTAssertNil(try db.fetchCountsTowardSection(counterId: root))
        XCTAssertNil(try db.fetchCountsTowardSection(counterId: "missing"))
    }

    func test_counterDetailSnapshot_carriesTheSection() throws {
        let db = try makeDb()
        try seedSection(db)
        let snap = CounterDetailView.loadSnapshot(
            database: db, userId: user, counterId: root, showExpired: true, now: AppDatabase.currentTimestamp()
        )
        XCTAssertEqual(snap.countsToward?.rows.count, 2)
    }

    func test_sectionCopy() {
        XCTAssertEqual(CountsTowardSectionView.heading(count: 0), "Counts toward")
        XCTAssertEqual(CountsTowardSectionView.heading(count: 1), "Counts toward · 1 task")
        XCTAssertEqual(CountsTowardSectionView.heading(count: 6), "Counts toward · 6 tasks")
        XCTAssertNil(CountsTowardSectionView.creditMark(1))
        XCTAssertEqual(CountsTowardSectionView.creditMark(3), "\u{00D7} 3")
        XCTAssertNil(CountsTowardSectionView.amountMark(1))
        XCTAssertEqual(CountsTowardSectionView.amountMark(2), "+2")
    }

    // MARK: - Single write path

    func test_dbTwin_behavesLikeTheInstanceCall() throws {
        let a = try makeDb(), b = try makeDb()
        for db in [a, b] {
            try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
            try db.saveTask(task(simple))
        }
        try a.setCountsToward(taskId: simple, counterId: root, amount: 3, now: now)
        try b.write { d in try AppDatabase.setCountsToward(db: d, taskId: simple, counterId: root, amount: 3, now: now) }
        let (x, y) = (try fetch(a, simple), try fetch(b, simple))
        XCTAssertEqual(x.countsTowardCounterId, y.countsTowardCounterId)
        XCTAssertEqual(x.countsTowardAmount, 3)
        XCTAssertEqual(y.countsTowardAmount, 3)
        XCTAssertEqual(x.countsTowardSince, now)
        XCTAssertEqual(y.countsTowardSince, now)
        XCTAssertEqual(x.version, y.version)
        XCTAssertEqual(try queueCount(a, simple), try queueCount(b, simple))
        // A clear NULLs all three columns through the same path.
        try b.write { d in try AppDatabase.setCountsToward(db: d, taskId: simple, counterId: nil, amount: nil, now: now) }
        let cleared = try fetch(b, simple)
        XCTAssertNil(cleared.countsTowardCounterId)
        XCTAssertNil(cleared.countsTowardSince)
    }

    func test_dbTwin_refusesLikeTheInstanceCall() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true, countKind: .continuous))
        try db.saveTask(task(simple))
        XCTAssertThrowsError(try db.write { d in
            try AppDatabase.setCountsToward(db: d, taskId: self.simple, counterId: self.root, amount: 1, now: self.now)
        }) { XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.targetNotDiscrete)) }
        XCTAssertNil(try fetch(db, simple).countsTowardCounterId)
    }

    // MARK: - C2 global editor

    private func patch(_ t: Task, countsToward: CountsTowardPatch?, compound: TaskEditPatch? = nil) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: t.title, description: "", action: t.action ?? "", unit: t.unit ?? "", maxCountStr: "",
            trigger: .greenlog, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            compound: compound, countsToward: countsToward
        )
    }

    func test_globalEditor_setRepointAndClear() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(root2, type: .counting, maxCount: 5, isCounter: true, title: "Novels").save(d)
            try task(simple).save(d)
        }
        let t = try fetch(db, simple)
        try db.applyTaskEditPatch(taskId: simple, patch: patch(t, countsToward: CountsTowardPatch(counterId: root, amount: 2)), now: now)
        var saved = try fetch(db, simple)
        XCTAssertEqual(saved.countsTowardCounterId, root)
        XCTAssertEqual(saved.countsTowardAmount, 2)
        XCTAssertEqual(saved.countsTowardSince, now)

        try db.applyTaskEditPatch(taskId: simple, patch: patch(saved, countsToward: CountsTowardPatch(counterId: root2, amount: 2)), now: "2026-10-15T09:00:00.000Z")
        saved = try fetch(db, simple)
        XCTAssertEqual(saved.countsTowardCounterId, root2)
        XCTAssertEqual(saved.countsTowardSince, "2026-10-15T09:00:00.000Z")

        try db.applyTaskEditPatch(taskId: simple, patch: patch(saved, countsToward: CountsTowardPatch(counterId: nil, amount: nil)), now: now)
        saved = try fetch(db, simple)
        XCTAssertNil(saved.countsTowardCounterId)
        XCTAssertNil(saved.countsTowardAmount)
    }

    func test_globalEditor_nilPatchLeavesTheFlagUntouched() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple, countsToward: root, amount: 2).save(d)
        }
        var t = try fetch(db, simple)
        t.title = "Renamed"
        try db.applyTaskEditPatch(taskId: simple, patch: patch(t, countsToward: nil), now: now)
        let saved = try fetch(db, simple)
        XCTAssertEqual(saved.title, "Renamed")
        XCTAssertEqual(saved.countsTowardCounterId, root)
        XCTAssertEqual(saved.countsTowardAmount, 2)
    }

    func test_globalEditor_refusalSurfacesTheLabel() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true, countKind: .continuous).save(d)
            try task(simple).save(d)
        }
        let t = try fetch(db, simple)
        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: simple, patch: patch(t, countsToward: CountsTowardPatch(counterId: root, amount: 1)), now: now
        )) { XCTAssertEqual(AppDatabase.taskEditErrorMessage($0), "Pick a Discrete counter.") }
        XCTAssertNil(try fetch(db, simple).countsTowardCounterId)
    }

    func test_globalEditor_clearOnAnEmptyCompoundIsRefusedBeforeAnythingIsWritten() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(boxId, type: .compound, countsToward: root).save(d)
        }
        let t = try fetch(db, boxId)
        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: boxId, patch: patch(t, countsToward: CountsTowardPatch(counterId: nil, amount: nil)), now: now
        )) { XCTAssertEqual(AppDatabase.taskEditErrorMessage($0), "A compound task needs a sub-task.") }
        XCTAssertEqual(try fetch(db, boxId).countsTowardCounterId, root)
    }

    func test_kindSwitchRefusalLine() {
        XCTAssertEqual(
            AppDatabase.taskEditErrorMessage(CountKindSwitchError.hasContributors),
            CountKindSwitchError.countsTowardMessage
        )
    }

    // MARK: - Field rules

    func test_fieldCandidatesVisibilityAndPatch() {
        let counter = task(root, type: .counting, maxCount: 12, isCounter: true, title: "Books")
        let continuous = task(root2, type: .counting, maxCount: 5, isCounter: true, countKind: .continuous)
        let plain = task(simple, type: .counting, maxCount: 3)
        let linked = task(copy, type: .counting, maxCount: 1, sharedCounterId: root)
        let all = [counter, continuous, plain, linked]
        XCTAssertEqual(CountsTowardFieldView.candidates(tasks: all, editedTaskId: nil).map(\.id), [root])
        XCTAssertTrue(CountsTowardFieldView.candidates(tasks: all, editedTaskId: root).isEmpty)

        XCTAssertTrue(CountsTowardFieldView.isVisible(task: task(loose), selectedType: .normal, tasks: all))
        XCTAssertFalse(CountsTowardFieldView.isVisible(task: counter, selectedType: .counting, tasks: all))
        XCTAssertFalse(CountsTowardFieldView.isVisible(task: linked, selectedType: .counting, tasks: all))
        XCTAssertFalse(CountsTowardFieldView.isVisible(task: task(loose, type: .achievement), selectedType: .achievement, tasks: all))
        XCTAssertFalse(CountsTowardFieldView.isVisible(task: task(loose), selectedType: .achievement, tasks: all))

        // Patch only when changed; amount edit alone is a change; a clear is a patch.
        XCTAssertNil(CountsTowardFieldView.patch(selection: .init(counterId: nil), storedCounterId: nil, storedAmount: nil))
        XCTAssertNil(CountsTowardFieldView.patch(selection: .init(counterId: root, amount: 1), storedCounterId: root, storedAmount: nil))
        XCTAssertEqual(
            CountsTowardFieldView.patch(selection: .init(counterId: root, amount: 2), storedCounterId: root, storedAmount: 1),
            CountsTowardPatch(counterId: root, amount: 2)
        )
        XCTAssertEqual(
            CountsTowardFieldView.patch(selection: .init(counterId: nil), storedCounterId: root, storedAmount: 2),
            CountsTowardPatch(counterId: nil, amount: nil)
        )
    }

    func test_refusalLabels() {
        let labels = [
            CountsToward.Problem.selfTarget: "Not itself.",
            .contributorIsCounter: "A counter can't count toward a counter.",
            .contributorIsLinked: "A linked counter can't count toward a counter.",
            .contributorIsAchievement: "An achievement can't count toward a counter.",
            .targetNotCounter: "Pick a shared counter.",
            .targetNotDiscrete: "Pick a Discrete counter.",
            .invalidAmount: "Amount must be a whole number, 1 or more.",
            .cycle: "That counter already feeds this task.",
        ]
        for (problem, text) in labels { XCTAssertEqual(problem.label, text) }
    }

    // MARK: - C2 Board Edit

    private func commit(_ db: AppDatabase, stagedId: String, boardTaskId: String, _ ov: StagedTaskOverride) throws {
        let mapTask = try db.fetchTask(id: stagedId)
        let cell = BoardPlayViewModel.StagedCellRef(boardTaskId: boardTaskId, isNew: false, row: 0, col: 0, stagedTaskId: stagedId)
        try db.write { d in
            try BoardPlayViewModel.applyStagedOverrides(
                db: d, boardId: self.bA, overrides: [.init(stagedId: stagedId, override: ov, mapTask: mapTask)],
                cells: [cell], now: "2026-10-14T12:00:00.000Z"
            )
        }
    }

    private func staged(_ title: String, countsToward: CountsTowardPatch?) -> StagedTaskOverride {
        StagedTaskOverride(title: title, type: .normal, action: nil, unit: nil, maxCount: nil, compound: nil, countsToward: countsToward)
    }

    func test_boardEdit_flagsInPlaceWhenPlacedOnlyHere() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple).save(d)
            try board(bA).save(d)
            try placement("bt1", bA, simple).save(d)
        }
        try commit(db, stagedId: simple, boardTaskId: "bt1", staged(simple, countsToward: CountsTowardPatch(counterId: root, amount: 2)))
        let saved = try fetch(db, simple)
        XCTAssertEqual(saved.countsTowardCounterId, root)
        XCTAssertEqual(saved.countsTowardAmount, 2)
        XCTAssertNotNil(saved.countsTowardSince)
    }

    func test_boardEdit_forksFirstAndFlagsOnlyTheFork() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple).save(d)
            try board(bA).save(d)
            try board(bB).save(d)
            try placement("bt1", bA, simple).save(d)
            try placement("bt2", bB, simple).save(d)
        }
        try commit(db, stagedId: simple, boardTaskId: "bt1", staged(simple, countsToward: CountsTowardPatch(counterId: root, amount: 1)))
        let forkId = BoardScopedFork.forkTaskId(boardId: bA, taskId: simple)
        let fork = try fetch(db, forkId)
        XCTAssertEqual(fork.countsTowardCounterId, root)
        XCTAssertNil(try fetch(db, simple).countsTowardCounterId, "the original's flag is untouched")
    }

    func test_boardEdit_stagedClearClears() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple, countsToward: root).save(d)
            try board(bA).save(d)
            try placement("bt1", bA, simple).save(d)
        }
        try commit(db, stagedId: simple, boardTaskId: "bt1", staged(simple, countsToward: CountsTowardPatch(counterId: nil, amount: nil)))
        XCTAssertNil(try fetch(db, simple).countsTowardCounterId)
    }

    func test_boardEdit_displayMergeFollowsTheStagedValue() {
        let base = task(simple)
        let merged = BoardPlayViewModel.applyingOverride(
            staged(simple, countsToward: CountsTowardPatch(counterId: root, amount: 3)), to: base
        )
        XCTAssertEqual(merged.countsTowardCounterId, root)
        XCTAssertEqual(merged.countsTowardAmount, 3)
        let unmerged = BoardPlayViewModel.applyingOverride(
            staged(simple, countsToward: CountsTowardPatch(counterId: root, amount: 3)), to: base, mergesCountsToward: false
        )
        XCTAssertNil(unmerged.countsTowardCounterId)
    }

    // MARK: - Create form

    func test_createForm_normalFlagsAfterCreate() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let form = CreateFormViewModel(database: db)
        form.taskType = .normal
        form.title = "Read Dune"
        form.countsToward = CountsTowardSelection(counterId: root, amount: 2)
        let created = expectation(description: "created")
        form.handleCreateAndAddToPool(userId: user, onTaskCreated: { _, _, _ in created.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [created], timeout: 5)
        let made = try XCTUnwrap(try db.fetchTasks(userId: user).first { $0.title == "Read Dune" })
        XCTAssertEqual(made.countsTowardCounterId, root)
        XCTAssertEqual(made.countsTowardAmount, 2)
        XCTAssertNotNil(made.countsTowardSince)
    }

    func test_createForm_refusalShowsTheLabelAndCreatesNothing() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true, countKind: .continuous))
        let form = CreateFormViewModel(database: db)
        form.taskType = .normal
        form.title = "Read Dune"
        form.countsToward = CountsTowardSelection(counterId: root)
        form.handleCreateAndAddToPool(userId: user, onTaskCreated: { _, _, _ in XCTFail("must not create") }, onLibraryReloadRequested: {})
        XCTAssertEqual(form.errorMessage, "Pick a Discrete counter.")
        XCTAssertNil(try db.fetchTasks(userId: user).first { $0.title == "Read Dune" })
    }

    func test_createForm_compoundFlaggedMayHaveNoSubTasks() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let form = CreateFormViewModel(database: db)
        form.countsToward = CountsTowardSelection(counterId: root, amount: 1)
        let created = expectation(description: "created")
        form.handleCreateCompoundAndAddToPool(
            userId: user, title: "Weekly reads", rule: CreateFormViewModel.CompoundRule.allOf, subs: [],
            onTaskCreated: { _, _, _ in created.fulfill() }, onLibraryReloadRequested: {}
        )
        wait(for: [created], timeout: 5)
        let made = try XCTUnwrap(try db.fetchTasks(userId: user).first { $0.title == "Weekly reads" })
        XCTAssertEqual(made.countsTowardCounterId, root)
        XCTAssertNotNil(made.countsTowardSince)
    }

    func test_createForm_compoundWithNoFlagStillNeedsASubTask() throws {
        let db = try makeDb()
        let form = CreateFormViewModel(database: db)
        form.handleCreateCompoundAndAddToPool(
            userId: user, title: "Empty", rule: CreateFormViewModel.CompoundRule.allOf, subs: [],
            onTaskCreated: { _, _, _ in XCTFail("must not create") }, onLibraryReloadRequested: {}
        )
        XCTAssertNil(try db.fetchTasks(userId: user).first { $0.title == "Empty" })
    }

    // MARK: - C3 / C4

    func test_sharedCounterMarkFollowsTheFlag() throws {
        let db = try makeDb()
        let vm = BoardPlayViewModel(boardId: bA, userId: user, database: db)
        XCTAssertTrue(vm.showsSharedCounterMark(for: task(simple, countsToward: root)))
        XCTAssertTrue(vm.showsSharedCounterMark(for: task(boxId, type: .compound, countsToward: root)))
        XCTAssertFalse(vm.showsSharedCounterMark(for: task(simple)))
        XCTAssertFalse(vm.showsSharedCounterMark(for: nil))
    }

    func test_creditedBoards_excludeTheCurrentBoardAndAnyUncreditable() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(copy, type: .counting, maxCount: 1, sharedCounterId: root).save(d)
            try task(simple, countsToward: root).save(d)
            try board(bA).save(d)                    // current
            try board(bB).save(d)                    // credited (places the root)
            try board(bC, sealedAt: "2026-10-13T00:00:00.000Z").save(d) // sealed: not creditable
            try placement("bt1", bA, simple).save(d)
            try placement("bt2", bB, root).save(d)
            try placement("bt3", bC, copy).save(d)
        }
        let boards = try db.creditedBoards(forCounterRoot: root, excludingBoardId: bA, now: now)
        XCTAssertEqual(boards.map(\.boardId), [bB])
    }

    func test_completionToast_carriesAnUncompleteUndo_andIsAbsentWithoutOtherBoards() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true, title: "Books").save(d)
            try task(simple, countsToward: root, amount: 2).save(d)
            try board(bA).save(d)
            try board(bB).save(d)
            try placement("bt1", bA, simple).save(d)
        }
        // No other board places the counter yet: no toast.
        XCTAssertNil(BoardPlayViewModel.countsTowardCreditToast(
            database: db, taskId: simple, intent: .setCompleted(true), boardTaskId: "bt1", currentBoardId: bA
        ))
        try db.write { d in try self.placement("bt2", self.bB, self.root).save(d) }
        let payload = try XCTUnwrap(BoardPlayViewModel.countsTowardCreditToast(
            database: db, taskId: simple, intent: .setCompleted(true), boardTaskId: "bt1", currentBoardId: bA
        ))
        XCTAssertEqual(payload.undo, .uncomplete(taskId: simple, boardTaskId: "bt1"))
        XCTAssertEqual(payload.sourceTaskId, root)
        XCTAssertEqual(payload.amount, 2)
        XCTAssertTrue(payload.message.contains("also counted on Board e2"), payload.message)
        // Un-completing never toasts; an unflagged task never toasts.
        XCTAssertNil(BoardPlayViewModel.countsTowardCreditToast(
            database: db, taskId: simple, intent: .setCompleted(false), boardTaskId: "bt1", currentBoardId: bA
        ))
        XCTAssertNil(BoardPlayViewModel.countsTowardCreditToast(
            database: db, taskId: root, intent: .setCompleted(true), boardTaskId: nil, currentBoardId: bA
        ))
    }
}
