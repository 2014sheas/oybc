import XCTest
import GRDB
@testable import OYBC

/// "Counts toward" (iOS half) — the Counter Detail section's data, the create
/// form's "+ New" preset (the one UI write of the flag since the editor row was
/// retired on 2026-10-10), the loop re-check after a structure edit, fork
/// inheritance, the credited-boards reader and the completion-moment toast.
/// Web twin: `db/operations/__tests__/countsTowardUi.test.ts`.
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

    private func patch(_ t: Task, compound: TaskEditPatch? = nil) -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: t.title, description: "", action: t.action ?? "", unit: t.unit ?? "", maxCountStr: "",
            trigger: .greenlog, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            compound: compound
        )
    }

    func test_kindSwitchRefusalLine() {
        XCTAssertEqual(
            AppDatabase.taskEditErrorMessage(CountKindSwitchError.hasContributors),
            CountKindSwitchError.countsTowardMessage
        )
    }

    // MARK: - Field rules

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

    private func staged(_ title: String) -> StagedTaskOverride {
        StagedTaskOverride(title: title, type: .normal, action: nil, unit: nil, maxCount: nil, compound: nil)
    }

    func test_boardEdit_forkInheritsAnExistingFlag() throws {
        let db = try makeDb()
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple, countsToward: root, amount: 2).save(d)
            try board(bA).save(d)
            try board(bB).save(d)
            try placement("bt1", bA, simple).save(d)
            try placement("bt2", bB, simple).save(d)
        }
        try commit(db, stagedId: simple, boardTaskId: "bt1", staged("Renamed"))
        let forkId = BoardScopedFork.forkTaskId(boardId: bA, taskId: simple)
        let fork = try fetch(db, forkId)
        XCTAssertEqual(fork.countsTowardCounterId, root)
        XCTAssertEqual(fork.countsTowardAmount, 2)
        XCTAssertEqual(try fetch(db, simple).countsTowardCounterId, root, "the original keeps its flag")
    }

    // MARK: - Create form

    func test_createForm_normalFlagsAfterCreate() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let form = CreateFormViewModel(database: db)
        form.taskType = .normal
        form.title = "Read Dune"
        form.countsToward = CountsTowardSelection(counterId: root)
        let created = expectation(description: "created")
        form.handleCreateAndAddToPool(userId: user, onTaskCreated: { _, _, _ in created.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [created], timeout: 5)
        let made = try XCTUnwrap(try db.fetchTasks(userId: user).first { $0.title == "Read Dune" })
        XCTAssertEqual(made.countsTowardCounterId, root)
        XCTAssertNil(made.countsTowardAmount)
        XCTAssertNotNil(made.countsTowardSince)
    }

    func test_createForm_withoutPresetWritesNoFlag() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let form = CreateFormViewModel(database: db)
        form.taskType = .normal
        form.title = "Read Dune"
        let created = expectation(description: "created")
        form.handleCreateAndAddToPool(userId: user, onTaskCreated: { _, _, _ in created.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [created], timeout: 5)
        let made = try XCTUnwrap(try db.fetchTasks(userId: user).first { $0.title == "Read Dune" })
        XCTAssertNil(made.countsTowardCounterId)
        XCTAssertNil(made.countsTowardAmount)
        XCTAssertNil(made.countsTowardSince)
    }

    func test_createForm_presetWritesTheFlagWithNoAmount() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true))
        let form = CreateFormViewModel(database: db)
        form.taskType = .normal
        form.title = "Read Dune"
        form.countsToward = CountsTowardSelection(counterId: root)
        let created = expectation(description: "created")
        form.handleCreateAndAddToPool(userId: user, onTaskCreated: { _, _, _ in created.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [created], timeout: 5)
        let made = try XCTUnwrap(try db.fetchTasks(userId: user).first { $0.title == "Read Dune" })
        XCTAssertEqual(made.countsTowardCounterId, root)
        XCTAssertNil(made.countsTowardAmount)
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
        form.countsToward = CountsTowardSelection(counterId: root)
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

    // MARK: - Credited toast (diff of live credits)

    private func link(_ id: String, _ parent: String, _ child: String, _ idx: Int) -> CompoundChild {
        CompoundChild(id: id, compoundTaskId: parent, childTaskId: child, childIndex: idx,
                      createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil)
    }

    /// Root on board B (window open), contributor placed on board A.
    private func seedToast(_ db: AppDatabase, contributor: Task) throws {
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true, title: "Books").save(d)
            try contributor.save(d)
            try board(bA).save(d)
            try board(bB).save(d)
            try placement("bt1", bA, contributor.id).save(d)
            try placement("bt2", bB, root).save(d)
        }
    }

    private func complete(_ db: AppDatabase, _ taskId: String, intent: AppDatabase.CompletionIntent, at stamp: String? = nil) throws {
        let b = try XCTUnwrap(try db.read { try Board.fetchOne($0, key: self.bA) })
        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt1") })
        _ = try db.completeTaskOrchestrated(board: b, taskId: taskId, intent: intent, boardTask: bt, now: stamp ?? now)
    }

    private func toast(
        _ db: AppDatabase, written: String, before: CountsTowardCreditSnapshot?, undo: SharedCounterCreditToastPayload.UndoKind
    ) -> SharedCounterCreditToastPayload? {
        BoardPlayViewModel.countsTowardCreditToast(
            database: db, snapshot: before, currentBoardId: bA, writtenTaskId: written, undo: undo
        )
    }

    func test_toast_simpleCompletionCreditedOnAnotherBoard() throws {
        let db = try makeDb()
        try seedToast(db, contributor: task(simple, countsToward: root, amount: 2))
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: simple)
        try complete(db, simple, intent: .setCompleted(true))
        let payload = try XCTUnwrap(toast(db, written: simple, before: before, undo: .uncomplete(taskId: simple, boardTaskId: "bt1")))
        XCTAssertEqual(payload.undo, .uncomplete(taskId: simple, boardTaskId: "bt1"))
        XCTAssertEqual(payload.amount, 2)
        XCTAssertTrue(payload.message.contains("also counted on Board e2"), payload.message)
    }

    func test_toast_countingGoalReached_undoRestoresPreviousCount() throws {
        let db = try makeDb()
        try seedToast(db, contributor: task(loose, type: .counting, maxCount: 2, countsToward: root))
        // 1 of 2 → no credit yet.
        try complete(db, loose, intent: .setWindowedCount(1))
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: loose)
        try complete(db, loose, intent: .setWindowedCount(2))
        let undo = BoardPlayViewModel.creditUndo(intent: .setWindowedCount(2), taskId: loose, boardTaskId: "bt1", priorCount: 1)
        let payload = try XCTUnwrap(toast(db, written: loose, before: before, undo: undo))
        XCTAssertEqual(payload.undo, .restoreCount(taskId: loose, boardTaskId: "bt1", count: 1))
        // The Undo's write restores the count and withdraws the credit.
        try complete(db, loose, intent: .setWindowedCount(1))
        let after = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: loose)
        XCTAssertEqual(after?.liveIdsByRoot[root]?.count, 0)
    }

    func test_toast_compoundViaChildToggle_once() throws {
        let db = try makeDb()
        try seedToast(db, contributor: task(boxId, type: .compound, countsToward: root))
        try db.write { d in
            try self.task(self.kid).save(d)
            try self.link("l1", self.boxId, self.kid, 0).save(d)
        }
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: kid)
        _ = try db.toggleCompoundChildFallback(
            childTaskId: kid, desiredCompleted: true, windowStart: start, windowEnd: end, boardId: bA, now: now
        )
        let payload = try XCTUnwrap(toast(db, written: kid, before: before, undo: .uncomplete(taskId: kid, boardTaskId: nil)))
        XCTAssertEqual(payload.undo, .uncomplete(taskId: kid, boardTaskId: nil))
        // A second snapshot after the credit exists yields no further toast.
        let again = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: kid)
        XCTAssertNil(toast(db, written: kid, before: again, undo: .counterLog))
    }

    func test_toast_noneWhenNothingCredited() throws {
        // A late log stamped before `since` writes no credit.
        let db = try makeDb()
        var flagged = task(simple, countsToward: root)
        flagged.countsTowardSince = "2026-12-01T00:00:00.000Z"
        try seedToast(db, contributor: flagged)
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: simple)
        try complete(db, simple, intent: .setCompleted(true))
        XCTAssertNil(toast(db, written: simple, before: before, undo: .counterLog))

        // Unflagged: no snapshot, no toast.
        let db2 = try makeDb()
        try seedToast(db2, contributor: task(simple))
        XCTAssertNil(BoardPlayViewModel.countsTowardCreditSnapshot(database: db2, currentBoardId: bA, writtenTaskId: simple))
    }

    func test_toast_noneWhenNoOtherBoardWindowHoldsTheCredit() throws {
        let db = try makeDb()
        try seedToast(db, contributor: task(simple, countsToward: root))
        // Move board B's window to the past: it no longer holds today's credit.
        try db.write { d in
            try d.execute(sql: "UPDATE boards SET endDate = ? WHERE id = ?", arguments: ["2026-10-13T00:00:00.000Z", self.bB])
        }
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: simple)
        try complete(db, simple, intent: .setCompleted(true))
        XCTAssertNil(toast(db, written: simple, before: before, undo: .counterLog))
    }

    func test_toast_creditFromAnotherOnBoardContributorBetweenSnapshotsIsNotAttributed() throws {
        let db = try makeDb()
        try seedToast(db, contributor: task(simple, countsToward: root))
        try db.write { d in
            try self.task(self.loose, countsToward: self.root).save(d)
            try self.placement("bt-loose", self.bA, self.loose, col: 1).save(d)
        }
        let before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: simple)
        // A DIFFERENT on-board contributor is credited between the two snapshots (a pull / rapid tap).
        let b = try XCTUnwrap(try db.read { try Board.fetchOne($0, key: self.bA) })
        let other = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-loose") })
        _ = try db.completeTaskOrchestrated(board: b, taskId: loose, intent: .setCompleted(true), boardTask: other, now: now)
        // The written task (simple) produced nothing: no toast, so Undo can never revert the wrong square.
        XCTAssertNil(toast(db, written: simple, before: before, undo: .uncomplete(taskId: simple, boardTaskId: "bt1")))
    }

    func test_toast_sealedOtherBoardBoundsAtSealedAt() throws {
        // Sealed BEFORE the credit: not listed.
        let db = try makeDb()
        try seedToast(db, contributor: task(simple, countsToward: root))
        try db.write { d in try self.board(self.bB, sealedAt: "2026-10-13T00:00:00.000Z").save(d) }
        var before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db, currentBoardId: bA, writtenTaskId: simple)
        try complete(db, simple, intent: .setCompleted(true))
        XCTAssertNil(toast(db, written: simple, before: before, undo: .counterLog))

        // Sealed AFTER the credit: listed.
        let db2 = try makeDb()
        try seedToast(db2, contributor: task(simple, countsToward: root))
        before = BoardPlayViewModel.countsTowardCreditSnapshot(database: db2, currentBoardId: bA, writtenTaskId: simple)
        try complete(db2, simple, intent: .setCompleted(true))
        // (A seal whose window already holds the instant would suppress the credit itself, so seal after.)
        try db2.write { d in try self.board(self.bB, sealedAt: "2026-10-15T00:00:00.000Z").save(d) }
        XCTAssertNotNil(toast(db2, written: simple, before: before, undo: .counterLog))
    }

    func test_setCountsToward_clearOnChildlessCompoundThrowsCompoundNeedsChild() throws {
        let db = try makeDb()
        try db.write { d in
            try self.task(self.root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try self.task(self.boxId, type: .compound, countsToward: self.root).save(d)
        }
        XCTAssertThrowsError(try db.write { d in
            try AppDatabase.setCountsToward(db: d, taskId: self.boxId, counterId: nil, amount: nil, now: self.now)
        }) { XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .compoundNeedsChild) }
        XCTAssertEqual(try fetch(db, boxId).countsTowardCounterId, root)
        XCTAssertEqual(AppDatabase.CountsTowardError.compoundNeedsChild.label, "A compound task needs a sub-task.")
    }

    func test_undoCreditToast_countingGoalReached_restoresCountAndWithdrawsCredit() throws {
        let db = try makeDb()
        let dict: (String) -> Board = { id in
            var b = try! self.board(id)
            b.startDate = "2026-01-01T00:00:00.000Z"
            return b
        }
        try db.write { d in
            try self.task(self.root, type: .counting, maxCount: 12, isCounter: true, title: "Books").save(d)
            try self.task(self.loose, type: .counting, maxCount: 2, countsToward: self.root).save(d)
            try dict(self.bA).save(d)
            try dict(self.bB).save(d)
            try self.placement("bt1", self.bA, self.loose).save(d)
            try self.placement("bt2", self.bB, self.root).save(d)
        }
        let vm = BoardPlayViewModel(boardId: bA, userId: user, database: db)
        func wait(_ p: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while !p() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return p()
        }
        vm.reload()
        XCTAssertTrue(wait { vm.board != nil && !vm.boardTasks.isEmpty && vm.taskMap[self.loose] != nil })
        func tap() throws {
            let bt = try XCTUnwrap(vm.boardTasks.first)
            vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap[loose]), amount: 1)
            XCTAssertTrue(wait { !vm.isProcessing })
        }
        try tap()
        XCTAssertEqual(vm.windowedState(forTaskId: loose).count, 1)
        try tap()
        XCTAssertEqual(vm.windowedState(forTaskId: loose).count, 2)
        let payload = try XCTUnwrap(vm.flashEvent?.creditToast)
        XCTAssertEqual(payload.undo, .restoreCount(taskId: loose, boardTaskId: "bt1", count: 1))
        func liveCredits() throws -> Int {
            try db.read { try TaskEvent.filter(Column("taskId") == self.root && Column("isDeleted") == false).fetchCount($0) }
        }
        XCTAssertEqual(try liveCredits(), 1)

        vm.undoCreditToast(payload.undo, sourceTaskId: payload.sourceTaskId)
        XCTAssertTrue(wait { !vm.isProcessing && vm.windowedState(forTaskId: self.loose).count == 1 })
        XCTAssertEqual(try liveCredits(), 0, "the credit is tombstoned")
    }

    // MARK: - Create is one write

    func test_createTask_refusalPersistsNothing() throws {
        let db = try makeDb()
        try db.saveTask(task(root, type: .counting, maxCount: 12, isCounter: true, countKind: .continuous))
        XCTAssertThrowsError(try db.createTaskAndEnqueue(
            task("new-1", title: "Nope"), now: now, countsToward: CountsTowardPatch(counterId: root)
        ))
        XCTAssertNil(try db.fetchTask(id: "new-1"))
    }

    func test_createCompound_loopThroughAutoLinkedSubTaskIsRefusedAndNothingPersists() throws {
        let db = try makeDb()
        try db.write { d in
            try self.task(self.root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try self.task(self.copy, type: .counting, maxCount: 1, sharedCounterId: self.root).save(d)
        }
        let parent = task(boxId, type: .compound, title: "Loop")
        XCTAssertThrowsError(try db.createCompoundAndEnqueue(
            parent: parent, newChildTasks: [], childLinks: [link("l1", boxId, copy, 0)], now: now,
            countsToward: CountsTowardPatch(counterId: root)
        )) { XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.cycle)) }
        XCTAssertNil(try db.fetchTask(id: boxId))
        XCTAssertEqual(try db.read { try CompoundChild.fetchCount($0) }, 0)
    }

    func test_createCompound_alreadyDoneSubTaskCreditsAtCreate() throws {
        let db = try makeDb()
        try db.write { d in
            try self.task(self.root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try self.task(self.kid).save(d)
            try self.completion("c-kid", self.kid, "2026-10-14T10:00:00.000Z").insert(d)
        }
        try db.createCompoundAndEnqueue(
            parent: task(boxId, type: .compound), newChildTasks: [], childLinks: [link("l1", boxId, kid, 0)], now: now,
            countsToward: CountsTowardPatch(counterId: root)
        )
        let saved = try fetch(db, boxId)
        XCTAssertEqual(saved.countsTowardCounterId, root)
        let credits = try db.read {
            try TaskEvent.filter(Column("taskId") == self.root && Column("isDeleted") == false).fetchCount($0)
        }
        XCTAssertEqual(credits, 1)
    }

    // MARK: - Loop closed by the same Save's structure edit

    private func seedFlaggedCompound(_ db: AppDatabase) throws {
        try db.write { d in
            try self.task(self.root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try self.task(self.copy, type: .counting, maxCount: 1, sharedCounterId: self.root).save(d)
            try self.task(self.kid).save(d)
            try self.task(self.boxId, type: .compound, countsToward: self.root).save(d)
            try self.link("l1", self.boxId, self.kid, 0).save(d)
            try self.board(self.bA).save(d)
            try self.placement("bt1", self.bA, self.boxId).save(d)
        }
    }

    private func structureAddingCopy(_ db: AppDatabase) throws -> TaskEditPatch {
        let box = try fetch(db, boxId)
        var draft = TaskEditPatch.seededForEditor(from: box)
        draft.children = [try fetch(db, kid), try fetch(db, copy)].map { ChildPatch(from: $0) }
        return draft
    }

    func test_globalEditor_structureLoopOnAnAlreadyFlaggedCompoundIsRefused() throws {
        let db = try makeDb()
        try seedFlaggedCompound(db)
        let box = try fetch(db, boxId)
        XCTAssertThrowsError(try db.applyTaskEditPatch(
            taskId: boxId, patch: patch(box, compound: try structureAddingCopy(db)), now: now
        )) { XCTAssertEqual(AppDatabase.taskEditErrorMessage($0), "That counter already feeds this task.") }
        XCTAssertEqual(try db.read { try CompoundChild.filter(Column("compoundTaskId") == self.boxId && Column("isDeleted") == false).fetchCount($0) }, 1)
    }

    func test_boardEdit_structureLoopOnAnAlreadyFlaggedCompoundIsRefused() throws {
        let db = try makeDb()
        try seedFlaggedCompound(db)
        let ov = StagedTaskOverride(
            title: boxId, type: .compound, action: nil, unit: nil, maxCount: nil,
            compound: try structureAddingCopy(db)
        )
        XCTAssertThrowsError(try commit(db, stagedId: boxId, boardTaskId: "bt1", ov)) {
            XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.cycle))
        }
        XCTAssertEqual(try db.read { try CompoundChild.filter(Column("compoundTaskId") == self.boxId && Column("isDeleted") == false).fetchCount($0) }, 1)
    }

}
