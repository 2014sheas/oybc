import XCTest
import GRDB
@testable import OYBC

/// `TaskDetailViewModel` against an in-memory database: the hero anchor, writes through
/// the anchor placement and their Undo, the derived Activity feed and the achievement's
/// closest-line read. Clock fixed at 2026-10-17 noon UTC.
@MainActor
final class TaskDetailViewModelTests: XCTestCase {

    private let userId = "u1"
    private let now = parseISO8601Date("2026-10-17T12:00:00.000Z")!

    // MARK: Fixtures

    private func seedUser(_ db: AppDatabase) throws {
        let t = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1
        ))
    }

    private func board(
        _ id: String, start: String = "2026-10-12T00:00:00.000", end: String = "2026-10-18T23:59:59.999",
        size: Int = 1, status: BoardStatus = .active, sealedAt: String? = nil, sealedCells: [Int]? = nil
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board \(id)", "status": status.rawValue,
            "boardSize": size, "timeframe": Timeframe.weekly.rawValue, "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let cells = sealedCells, let data = try? JSONEncoder().encode(cells), let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        return try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func task(_ id: String, type: TaskType, maxCount: CountValue? = nil) -> Task {
        let t = AppDatabase.currentTimestamp()
        var task = Task(
            id: id, userId: userId, title: id, type: type, action: nil, unit: "pages", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0, createdAt: t, updatedAt: t, version: 1, isDeleted: false
        )
        if type == .compound { task.operatorType = .and }
        return task
    }

    private func place(_ db: AppDatabase, bt: String, board: String, task: String, row: Int = 0, col: Int = 0) throws {
        let t = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: bt, boardId: board, taskId: task, row: row, col: col, isCenter: false,
            createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1
        ))
    }

    /// Polls by yielding (an async test cannot drain the main queue from a nested run loop).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await _Concurrency.Task.sleep(nanoseconds: 10_000_000) }
        return predicate()
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async {
        let ok = await waitUntil(predicate)
        XCTAssertTrue(ok, file: file, line: line)
    }

    private func loaded(_ db: AppDatabase, taskId: String, expectHero: Bool = true) async -> TaskDetailViewModel {
        let vm = TaskDetailViewModel(taskId: taskId, database: db, now: { self.now })
        await vm.load()
        if expectHero { _ = await waitUntil { if case .none? = vm.model?.hero { return false }; return vm.model != nil } }
        else { _ = await waitUntil { vm.model != nil } }
        return vm
    }

    private func count(_ vm: TaskDetailViewModel) -> CountValue? {
        if case let .counting(c)? = vm.model?.hero { return c.current }
        return nil
    }

    /// A counting task on an active weekly board (b1) and an ended one (b0).
    private func seedCounting(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveBoard(board("b0", start: "2026-10-05T00:00:00.000", end: "2026-10-11T23:59:59.999"))
        try db.saveTask(task("c1", type: .counting, maxCount: 20))
        try place(db, bt: "bt1", board: "b1", task: "c1")
        try place(db, bt: "bt0", board: "b0", task: "c1")
    }

    /// Review fix C8: popping back to Task Detail drops a hero strip that describes a write from before
    /// the push (its Undo would reverse the counter's LATEST log, which may be a Counter Detail log).
    func test_hostReappearing_dropsTheHeroUndoStrip() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        let vm = await loaded(db, taskId: "c1")
        vm.log(amount: 5)
        await eventually { !vm.isBusy && vm.strip != nil }

        await vm.hostAppeared(taskId: "c1")

        XCTAssertNil(vm.strip, "the strip does not survive push/pop")
        XCTAssertEqual(count(vm), 5, "the model itself reloads")
    }

    // MARK: Anchor

    func test_anchorIsTheSoonestEndingActiveBoard_andRowsSplitActiveFromPast() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        let vm = await loaded(db, taskId: "c1")
        let model = try XCTUnwrap(vm.model)

        XCTAssertEqual(model.anchorName, try db.fetchBoard(id: "b1")?.displayName)
        XCTAssertEqual(count(vm), 0)
        XCTAssertEqual(model.activeBoards.map(\.id), ["b1"])
        XCTAssertEqual(model.pastBoards.map(\.id), ["b0"])
        XCTAssertEqual(model.boardCount, 2)
        XCTAssertEqual(model.pastBoards[0].value, "0", "past rows show their value")
        XCTAssertEqual(model.pastBoards[0].valueSub, "/20")
        XCTAssertTrue(model.activity.contains { $0.kind == .missed }, "an ended board whose window it did not complete")
        XCTAssertEqual(model.activeBoards[0].value, "0")
    }

    /// Binding decision 3 (4): a counting task with no square in play gets the
    /// board-less control — all-time count, a log "now" with Undo.
    func test_noSquareInPlay_countingLogsAllTime_andUndoReversesIt() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b0", start: "2026-10-05T00:00:00.000", end: "2026-10-11T23:59:59.999"))
        try db.saveTask(task("c1", type: .counting, maxCount: 20))
        try place(db, bt: "bt0", board: "b0", task: "c1")
        let vm = await loaded(db, taskId: "c1")
        func allTime() -> CountValue? { if case let .boardlessCounting(c)? = vm.model?.hero { return c.current }; return nil }

        XCTAssertEqual(allTime(), 0)
        XCTAssertNil(vm.model?.anchorName)
        vm.log(amount: 5)
        await eventually { allTime() == 5 && !vm.isBusy && vm.strip != nil }
        XCTAssertEqual(vm.strip?.text, "Logged +5 pages · All-time")
        XCTAssertEqual(vm.strip?.undo, .counterLog(sourceTaskId: "c1"))

        vm.undo()
        await eventually { allTime() == 0 && !vm.isBusy }
    }

    func test_noSquareInPlay_aNormalTaskHasNoControl() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveTask(task("n0", type: .normal))
        let vm = await loaded(db, taskId: "n0", expectHero: false)
        XCTAssertEqual(vm.model?.hero, TaskDetailModel.Hero.none)
    }

    /// Binding decision 3 (3): a sub-task placed only through its compound drives
    /// that square — its own Normal toggle, written as the compound child toggle.
    func test_subTaskPlacedThroughItsCompound_togglesThroughThatSquare() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("s", type: .normal))
        try db.saveTask(task("P", type: .compound))
        let t = AppDatabase.currentTimestamp()
        try db.write { try CompoundChild(
            id: "l1", compoundTaskId: "P", childTaskId: "s", childIndex: 0,
            createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        ).save($0) }
        try place(db, bt: "btP", board: "b1", task: "P")
        let vm = await loaded(db, taskId: "s")
        func isDone() -> Bool? { if case let .normal(done, _)? = vm.model?.hero { return done }; return nil }

        XCTAssertEqual(isDone(), false)
        XCTAssertEqual(vm.model?.anchorName, "Board b1")
        vm.toggleNormal()
        await eventually { isDone() == true && !vm.isBusy }
    }

    // MARK: Writes through the anchor placement

    func test_logWritesOnTheAnchorBoard_thenUndoRestoresIt() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        let vm = await loaded(db, taskId: "c1")

        vm.log(amount: 5)
        let strip = try XCTUnwrap(vm.strip)
        XCTAssertEqual(strip.undo, .restoreCount(taskId: "c1", boardTaskId: "bt1", count: 0))
        XCTAssertTrue(strip.text.hasPrefix("Logged +5 pages · "))
        await eventually { self.count(vm) == 5 && !vm.isBusy }

        vm.undo()
        XCTAssertNil(vm.strip)
        await eventually { self.count(vm) == 0 && !vm.isBusy }
    }

    /// Owner, 2026-10-18 — the library's counter row opens Task detail, so a
    /// counter ROOT placed only through a linked row must still get the counting
    /// hero (chips): it anchors on the linked square, and a log writes the root.
    func test_counterRootAnchorsOnItsLinkedRowsSquare_andALogWritesTheRoot() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        var root = task("r", type: .counting)
        root.isCounter = true
        try db.saveTask(root)
        var linked = task("l", type: .counting, maxCount: 20)
        linked.sharedCounterId = "r"
        linked.baseline = 0
        try db.saveTask(linked)
        try place(db, bt: "btL", board: "b1", task: "l")

        let vm = await loaded(db, taskId: "r")
        XCTAssertEqual(count(vm), 0, "the root gets the counting hero")

        vm.log(amount: 3)
        await eventually { self.count(vm) == 3 && !vm.isBusy }
        let rootEvents = try db.read { try TaskEvent.filter(Column("taskId") == "r" && Column("isDeleted") == false).fetchAll($0) }
        XCTAssertEqual(rootEvents.map(\.delta), [3])
    }

    /// A root whose only in-play square is a linked row INSIDE a compound: the
    /// hero drives that child and its Undo strip stays scoped to the root's page.
    func test_counterRootAnchoredOnALinkedCompoundChild_logShowsItsStrip() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        var root = task("r", type: .counting)
        root.isCounter = true
        try db.saveTask(root)
        var linked = task("l", type: .counting, maxCount: 20)
        linked.sharedCounterId = "r"
        linked.baseline = 0
        try db.saveTask(linked)
        try db.saveTask(task("P", type: .compound))
        let t = AppDatabase.currentTimestamp()
        try db.write { try CompoundChild(
            id: "lk", compoundTaskId: "P", childTaskId: "l", childIndex: 0,
            createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        ).save($0) }
        try place(db, bt: "btP", board: "b1", task: "P")

        let vm = await loaded(db, taskId: "r")
        XCTAssertEqual(count(vm), 0)
        vm.log(amount: 2)
        XCTAssertEqual(vm.strip?.scopeTaskId, "r")
        await eventually { self.count(vm) == 2 && !vm.isBusy }
    }

    func test_removalStripNamesTheAppliedAmount() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        let vm = await loaded(db, taskId: "c1")
        vm.log(amount: 3)
        await eventually { self.count(vm) == 3 && !vm.isBusy }

        vm.log(amount: 10, removing: true) // clamps at the 3 logged
        XCTAssertTrue(try XCTUnwrap(vm.strip).text.hasPrefix("Removed 3 pages"))
    }

    func test_normalToggleThroughAnchor_undoRestoresThePriorState() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("n1", type: .normal))
        try place(db, bt: "bt1", board: "b1", task: "n1")
        let vm = await loaded(db, taskId: "n1")
        func isDone() -> Bool? { if case let .normal(done, _)? = vm.model?.hero { return done }; return nil }
        XCTAssertEqual(isDone(), false)

        vm.toggleNormal()
        XCTAssertEqual(vm.strip?.undo, .restoreNormal(boardTaskId: "bt1", wasDone: false))
        XCTAssertEqual(vm.strip?.text, "n1 · done")
        await eventually { isDone() == true && !vm.isBusy }

        vm.undo()
        await eventually { isDone() == false && !vm.isBusy }
    }

    func test_compoundHeroReadsChildrenThroughTheWindow_andToggleHasAnExplicitUndo() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .normal))
        try place(db, bt: "bt1", board: "b1", task: "cmp")
        let t = AppDatabase.currentTimestamp()
        try db.write { d in
            try CompoundChild(id: "cmp-kid", compoundTaskId: "cmp", childTaskId: "kid", childIndex: 0, createdAt: t, updatedAt: t, version: 1, isDeleted: false).save(d)
        }
        let vm = await loaded(db, taskId: "cmp")
        func done() -> Int? { if case let .compound(c, _)? = vm.model?.hero { return c.doneCount }; return nil }
        XCTAssertEqual(done(), 0)
        XCTAssertEqual(vm.model?.kicker, "Compound · all of 1")

        vm.toggleChild("kid")
        XCTAssertEqual(vm.strip?.undo, .restoreToggle(taskId: "kid", wasDone: false))
        await eventually { done() == 1 && !vm.isBusy }
        vm.undo()
        await eventually { done() == 0 && !vm.isBusy }
    }

    // MARK: Activity + footer

    func test_activityFeedIsDerivedFromEventsAndPlacements() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        let vm = await loaded(db, taskId: "c1")
        vm.log(amount: 5)
        await eventually { self.count(vm) == 5 && !vm.isBusy }
        // The write finishing re-reads the snapshot (activity, rows, footer).
        await eventually { vm.model?.activity.contains { $0.kind == .logged } == true }

        let kinds = Set(try XCTUnwrap(vm.model).activity.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.logged, .placed, .missed, .created]))
        XCTAssertTrue(try XCTUnwrap(vm.model).footer.hasPrefix("Completed 0× all-time"))
    }

    // MARK: Closest line (the one new read)

    func test_achievementClosestLineReadsTheWatchedBoardsFrozenCells() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        // Watched: a SEALED 3×3 with cells 0 and 1 done → the top row is the closest line (2 of 3).
        try db.saveBoard(board("w1", start: "2026-10-05T00:00:00.000", end: "2026-10-11T23:59:59.999", size: 3, sealedAt: "2026-10-12T00:00:00.000Z", sealedCells: [0, 1]))
        try db.saveBoard(board("b1"))
        var ach = task("ach", type: .achievement)
        ach.referencedBoardId = "w1"
        ach.achievementTrigger = .bingo
        try db.saveTask(ach)
        try place(db, bt: "bt1", board: "b1", task: "ach")
        let vm = await loaded(db, taskId: "ach")
        await eventually { if case let .achievement(a)? = vm.model?.hero { return a.closestLine != nil }; return false }

        guard case let .achievement(a)? = vm.model?.hero else { return XCTFail() }
        XCTAssertEqual(a.closestLine?.cells, [0, 1, 2])
        XCTAssertEqual(a.closestLine?.done, 2)
        XCTAssertEqual(a.lineCells, [true, true, false])
        XCTAssertEqual(vm.model?.kicker, "Achievement · first bingo")
        XCTAssertEqual(vm.model?.watchedBoardId, "w1")
    }

    func test_completionGrid_liveBoardUsesKernelStates_freeCenterCounts() {
        let b = board("w", size: 3)
        var free = b
        free.centerSquareType = .free
        let grid = TaskDetailViewModel.completionGrid(board: free, boardTasks: [], cellStates: [:])
        XCTAssertEqual(grid, [false, false, false, false, true, false, false, false, false])
        let sealed = board("s", size: 3, sealedAt: "2026-10-12T00:00:00.000Z", sealedCells: [8])
        XCTAssertEqual(TaskDetailViewModel.completionGrid(board: sealed, boardTasks: [], cellStates: [:]).filter { $0 }.count, 1)
    }

    // MARK: Counter link

    func test_unitTaskShowsItsCounterRow() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        var root = task("root", type: .counting, maxCount: nil)
        root.isCounter = true
        root.currentCount = 12
        try db.saveTask(root)
        var unit = task("n1", type: .normal)
        unit.countsTowardCounterId = "root"
        try db.saveTask(unit)
        let vm = await loaded(db, taskId: "n1", expectHero: false)

        let link = try XCTUnwrap(vm.model?.counter)
        XCTAssertEqual(link.counterId, "root")
        XCTAssertEqual(link.label, "Counts toward")
        XCTAssertEqual(link.total, "12")
        XCTAssertTrue(try XCTUnwrap(vm.model?.kicker).hasPrefix("Normal · counts toward"))
    }

    // MARK: Missed / row values / activity sources

    func test_aBoardClosedBeforeItsEndIsNotMissed_andAGoallessCounterNeverIs() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        // Sealed early: its window still runs to the 18th.
        try db.saveBoard(board("early", sealedAt: "2026-10-13T00:00:00.000Z", sealedCells: [0]))
        // Ended, but the counter has no goal.
        try db.saveBoard(board("old", start: "2026-10-05T00:00:00.000", end: "2026-10-11T23:59:59.999"))
        try db.saveTask(task("c1", type: .counting, maxCount: nil))
        try place(db, bt: "bt-e", board: "early", task: "c1")
        try place(db, bt: "bt-o", board: "old", task: "c1")
        let vm = await loaded(db, taskId: "c1", expectHero: false)

        XCTAssertFalse(try XCTUnwrap(vm.model).activity.contains { $0.kind == .missed })
    }

    func test_normalRowsShowDoneOrNothing_neverNotYet() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1", size: 3)) // a bigger board stays active when one square is done
        try db.saveTask(task("n1", type: .normal))
        try place(db, bt: "bt1", board: "b1", task: "n1")
        let vm = await loaded(db, taskId: "n1")
        XCTAssertNil(vm.model?.activeBoards.first?.value)
        vm.toggleNormal()
        await eventually { vm.model?.activeBoards.first?.value == "Done" && !vm.isBusy }
    }

    func test_compoundRowReadsEveryBoardsWindow() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveBoard(board("b0", start: "2026-10-05T00:00:00.000", end: "2026-10-11T23:59:59.999"))
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .normal))
        try place(db, bt: "bt1", board: "b1", task: "cmp")
        try place(db, bt: "bt0", board: "b0", task: "cmp")
        let t = AppDatabase.currentTimestamp()
        try db.write { d in
            try CompoundChild(id: "cmp-kid", compoundTaskId: "cmp", childTaskId: "kid", childIndex: 0, createdAt: t, updatedAt: t, version: 1, isDeleted: false).save(d)
            // A completion inside the OLD board's window only.
            try TaskEvent(id: "ev1", userId: self.userId, taskId: "kid", kind: .completion, delta: nil, occurredAt: "2026-10-08T10:00:00.000Z", boardId: nil, createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(d)
        }
        let vm = await loaded(db, taskId: "cmp")
        let model = try XCTUnwrap(vm.model)
        XCTAssertEqual(model.pastBoards.first?.value, "1")
        XCTAssertEqual(model.pastBoards.first?.valueSub, "/1")
        XCTAssertEqual(model.pastBoards.first?.isDone, true)
        XCTAssertEqual(model.activeBoards.first?.value, "0")
        XCTAssertFalse(model.activity.contains { $0.kind == .missed }, "the old board was completed")
    }

    func test_linkedTaskActivityIncludesItsCounterRootsEvents() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveBoard(board("b1"))
        var root = task("root", type: .counting, maxCount: nil)
        root.isCounter = true
        try db.saveTask(root)
        var linked = task("c1", type: .counting, maxCount: 20)
        linked.sharedCounterId = "root"
        try db.saveTask(linked)
        try place(db, bt: "bt1", board: "b1", task: "c1")
        let t = AppDatabase.currentTimestamp()
        try db.write { d in
            try TaskEvent(id: "ev1", userId: self.userId, taskId: "root", kind: .increment, delta: 4, occurredAt: "2026-10-14T10:00:00.000Z", boardId: nil, createdAt: t, updatedAt: t, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(d)
        }
        let vm = await loaded(db, taskId: "c1")
        XCTAssertTrue(try XCTUnwrap(vm.model).activity.contains { $0.kind == .logged && $0.text.hasPrefix("Logged +4") })
    }

    func test_missingTaskSurfacesAnError() async throws {
        let db = try AppDatabase.makeTestInstance()
        let vm = TaskDetailViewModel(taskId: "nope", database: db, now: { self.now })
        await vm.load()
        XCTAssertEqual(vm.loadError, "Task not found")
        XCTAssertNil(vm.model)
    }

    // MARK: ⋯ › Use as shared counter

    func test_plainCountingTaskOffersUseAsCounter_linkedRootAndUnitTasksDoNot() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        try db.saveTask(task("plain", type: .counting, maxCount: 20))
        var root = task("root", type: .counting, maxCount: nil)
        root.isCounter = true
        try db.saveTask(root)
        var copy = task("copy", type: .counting, maxCount: 10)
        copy.sharedCounterId = "root"
        try db.saveTask(copy)
        var unit = task("unit", type: .counting, maxCount: 3)
        unit.countsTowardCounterId = "root"
        try db.saveTask(unit)
        try db.saveTask(task("n1", type: .normal))

        for (id, expected) in [("plain", true), ("root", false), ("copy", false), ("unit", false), ("n1", false)] {
            let vm = await loaded(db, taskId: id, expectHero: false)
            XCTAssertEqual(vm.model?.canPromoteToCounter, expected, id)
        }
    }

    func test_useAsCounter_flagsTheTask_keepsItsCountAndGoal_andTheHeroGainsItsCounterRow() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedCounting(db)
        var plain = try XCTUnwrap(try db.fetchTask(id: "c1"))
        plain.currentCount = 7
        try db.saveTask(plain)
        let vm = await loaded(db, taskId: "c1")
        XCTAssertEqual(vm.model?.canPromoteToCounter, true)
        XCTAssertNil(vm.model?.counter)

        let ok = await vm.useAsCounter()
        XCTAssertTrue(ok)
        XCTAssertNil(vm.saveError)
        let saved = try XCTUnwrap(try db.fetchTask(id: "c1"))
        XCTAssertEqual(saved.isCounter, true)
        XCTAssertEqual(saved.currentCount, 7)
        XCTAssertEqual(saved.maxCount, 20)
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(try db.fetchPendingSyncItems().filter { $0.entityId == "c1" }.count, 1)
        await eventually { vm.model?.canPromoteToCounter == false }
        let link = try XCTUnwrap(vm.model?.counter)
        XCTAssertEqual(link.counterId, "c1")
        XCTAssertEqual(link.label, "Shared counter")
    }

    func test_useAsCounter_refusedWriteSurfacesAnErrorAndFlagsNothing() async throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db)
        var root = task("root", type: .counting, maxCount: nil)
        root.isCounter = true
        try db.saveTask(root)
        var copy = task("copy", type: .counting, maxCount: 10)
        copy.sharedCounterId = "root"
        try db.saveTask(copy)
        let vm = await loaded(db, taskId: "copy", expectHero: false)

        let ok = await vm.useAsCounter()
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.saveError, "Could not use this task as a counter.")
        XCTAssertNotEqual(try XCTUnwrap(try db.fetchTask(id: "copy")).isCounter, true)
    }
}
