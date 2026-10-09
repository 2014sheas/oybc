import XCTest
import GRDB
@testable import OYBC

/// Board-scoped task edits PR 2 (docs/BOARD_SCOPED_TASK_EDITS.md) — the
/// Board Edit Save (`BoardPlayViewModel.applyStagedOverrides`) and the board
/// wizard (`saveWizardBoard`) fork a task placed on any other board and edit
/// in place otherwise. Twin of web `boardEditCommit.boardScoped.test.ts` +
/// `wizardBoard.boardScoped.test.ts`.
final class BoardScopedEditCommitTests: XCTestCase {

    private static let t0 = "2026-10-01T00:00:00.000Z"
    private static let b1Start = "2026-10-05T00:00:00.000Z"
    private static let b1End = "2026-10-11T23:59:59.999Z"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.saveUser(User(
            id: "u1", email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: Self.t0, updatedAt: Self.t0, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func task(_ id: String, title: String, type: TaskType = .normal) -> Task {
        var t = Task(
            id: id, userId: "u1", title: title, type: type,
            totalCompletions: 0, totalInstances: 1,
            createdAt: Self.t0, updatedAt: Self.t0, version: 1, isDeleted: false
        )
        if type == .compound { t.operatorType = .and }
        return t
    }

    private func board(_ id: String, start: String, end: String, sealedAt: String? = nil) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": "u1", "name": id, "status": "active", "boardSize": 3,
            "timeframe": "weekly", "startDate": start, "endDate": end,
            "centerSquareType": "none", "isRandomized": false, "totalTasks": 9,
            "completedTasks": 0, "linesCompleted": 0, "createdAt": Self.t0,
            "updatedAt": Self.t0, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func placement(_ id: String, board: String, task: String, col: Int = 0) -> BoardTask {
        BoardTask(
            id: id, boardId: board, taskId: task, row: 0, col: col, isCenter: false,
            createdAt: Self.t0, updatedAt: Self.t0, version: 1, isDeleted: false
        )
    }

    private func link(_ id: String, _ parent: String, _ child: String, _ idx: Int) -> CompoundChild {
        CompoundChild(
            id: id, compoundTaskId: parent, childTaskId: child, childIndex: idx,
            createdAt: Self.t0, updatedAt: Self.t0, version: 1, isDeleted: false
        )
    }

    private func completion(_ id: String, task: String, at: String) -> TaskEvent {
        TaskEvent(
            id: id, userId: "u1", taskId: task, kind: .completion, delta: nil,
            occurredAt: at, boardId: nil, createdAt: Self.t0, updatedAt: Self.t0,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// B1 (the edited weekly) + B2 (a monthly).
    private func seedBoards(_ db: AppDatabase) throws {
        try db.saveBoard(try board("B1", start: Self.b1Start, end: Self.b1End))
        try db.saveBoard(try board("B2", start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.999Z"))
    }

    private func insert(_ db: AppDatabase, _ rows: [any PersistableRecord]) throws {
        try db.write { d in for r in rows { try r.insert(d) } }
    }

    private func fetchTask(_ db: AppDatabase, _ id: String) throws -> Task? {
        try db.read { try Task.fetchOne($0, key: id) }
    }

    private func liveChildIds(_ db: AppDatabase, of parent: String) throws -> [String] {
        try db.read {
            try CompoundChild.filter(Column("compoundTaskId") == parent && Column("isDeleted") == false).fetchAll($0)
        }.map(\.childTaskId).sorted()
    }

    private func placedTaskId(_ db: AppDatabase, _ boardTaskId: String) throws -> String? {
        try db.read { try BoardTask.fetchOne($0, key: boardTaskId) }?.taskId
    }

    private func override(_ title: String, _ type: TaskType = .normal, compound: TaskEditPatch? = nil,
                          action: String? = nil, unit: String? = nil, maxCount: CountValue? = nil) -> StagedTaskOverride {
        StagedTaskOverride(title: title, type: type, action: action, unit: unit, maxCount: maxCount, compound: compound)
    }

    /// Runs Save step 7b for one override on the square `boardTaskId` of B1.
    private func commit(
        _ db: AppDatabase, stagedId: String, boardTaskId: String, cellTaskId: String? = nil,
        _ ov: StagedTaskOverride
    ) throws {
        let mapTask = try fetchTask(db, stagedId)
        let cell = BoardPlayViewModel.StagedCellRef(
            boardTaskId: boardTaskId, isNew: false, row: 0, col: 0, stagedTaskId: cellTaskId ?? stagedId
        )
        try db.write { d in
            try BoardPlayViewModel.applyStagedOverrides(
                db: d, boardId: "B1",
                overrides: [.init(stagedId: stagedId, override: ov, mapTask: mapTask)],
                cells: [cell], now: "2026-10-08T12:00:00.000Z"
            )
        }
    }

    // MARK: - Board Edit

    func testEditsInPlaceWhenPlacedOnlyHere() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [placement("bt1", board: "B1", task: "T")])

        try commit(db, stagedId: "T", boardTaskId: "bt1", override("Read 20 pages"))

        XCTAssertEqual(try fetchTask(db, "T")?.title, "Read 20 pages")
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")))
        XCTAssertEqual(try placedTaskId(db, "bt1"), "T")
    }

    func testForksWhenPlacedElsewhereAndMigratesCompletion() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [
            placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T"),
            completion("e-in", task: "T", at: "2026-10-06T09:00:00.000Z"),
            completion("e-out", task: "T", at: "2026-10-02T09:00:00.000Z"),
        ])

        try commit(db, stagedId: "T", boardTaskId: "bt1", override("Read a chapter"))

        let forkId = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")
        let fork = try XCTUnwrap(try fetchTask(db, forkId))
        XCTAssertEqual(fork.title, "Read a chapter")
        XCTAssertEqual(fork.forkedFromTaskId, "T")
        XCTAssertTrue(fork.createdInWizard)
        XCTAssertTrue(fork.isCompleted, "caches stamped from the migrated events")
        XCTAssertEqual(fork.completedAt, "2026-10-06T09:00:00.000Z")

        let original = try XCTUnwrap(try fetchTask(db, "T"))
        XCTAssertEqual(original.title, "Read")
        XCTAssertEqual(original.version, 1)
        XCTAssertEqual(try placedTaskId(db, "bt1"), forkId)
        XCTAssertEqual(try placedTaskId(db, "bt2"), "T")

        let forkEvents = try db.read { try TaskEvent.filter(Column("taskId") == forkId).fetchAll($0) }
        XCTAssertEqual(forkEvents.map(\.id), [BoardScopedFork.forkedEventId(forkId: forkId, eventId: "e-in")])
        XCTAssertTrue(resolveTaskWindowState(task: fork, events: forkEvents, windowStart: Self.b1Start, windowEnd: Self.b1End).isCompleted)
        let origEvents = try db.read { try TaskEvent.filter(Column("taskId") == "T").fetchAll($0) }
        XCTAssertEqual(origEvents.count, 2)
        XCTAssertTrue(resolveTaskWindowState(
            task: original, events: origEvents, windowStart: "2026-10-01T00:00:00.000Z", windowEnd: "2026-10-31T23:59:59.999Z"
        ).isCompleted)
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: "B1") }?.completedTasks, 1)

        let queued = try db.read { try SyncQueueItem.fetchAll($0) }
        XCTAssertTrue(queued.contains { $0.entityType == "tasks" && $0.entityId == forkId })
        XCTAssertTrue(queued.contains { $0.entityType == "taskEvents" && $0.entityId == forkEvents.first?.id })
        XCTAssertTrue(queued.contains { $0.entityType == "boardTasks" && $0.entityId == "bt1" })
    }

    func testTypeChangeMigratesOnlyEventsTheNewTypeOwns() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Run"))
        try insert(db, [
            placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T"),
            completion("e1", task: "T", at: "2026-10-06T09:00:00.000Z"),
        ])

        try commit(db, stagedId: "T", boardTaskId: "bt1", override("", .counting, action: "Run", unit: "km", maxCount: 5))

        let forkId = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")
        let fork = try XCTUnwrap(try fetchTask(db, forkId))
        XCTAssertEqual(fork.type, .counting)
        XCTAssertEqual(fork.maxCount, 5)
        XCTAssertFalse(fork.isCompleted)
        XCTAssertEqual(try db.read { try TaskEvent.filter(Column("taskId") == forkId).fetchCount($0) }, 0)
        XCTAssertEqual(try fetchTask(db, "T")?.type, .normal)
    }

    func testCompoundForksParentOnlyChildrenStayShared() throws {
        let db = try makeDb()
        try seedBoards(db)
        for t in [task("P", title: "Morning", type: .compound), task("C1", title: "Stretch"), task("C2", title: "Coffee")] {
            try db.saveTask(t)
        }
        try insert(db, [
            link("l1", "P", "C1", 0), link("l2", "P", "C2", 1),
            placement("bt1", board: "B1", task: "P"), placement("bt2", board: "B2", task: "P"),
        ])
        var structure = TaskEditPatch(title: "Morning routine")
        structure.operatorType = .and
        structure.children = [ChildPatch(from: try XCTUnwrap(try fetchTask(db, "C1"))), ChildPatch(from: try XCTUnwrap(try fetchTask(db, "C2")))]

        try commit(db, stagedId: "P", boardTaskId: "bt1", override("Morning routine", .compound, compound: structure))

        let forkId = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "P")
        XCTAssertEqual(try fetchTask(db, forkId)?.title, "Morning routine")
        XCTAssertEqual(try fetchTask(db, "P")?.title, "Morning")
        XCTAssertEqual(try liveChildIds(db, of: forkId), ["C1", "C2"])
        XCTAssertEqual(try liveChildIds(db, of: "P"), ["C1", "C2"])
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "C1")))
        XCTAssertEqual(try placedTaskId(db, "bt1"), forkId)
    }

    func testRenamedSubTaskPlacedElsewhereIsForkedAndLinkRepointed() throws {
        let db = try makeDb()
        try seedBoards(db)
        for t in [task("P", title: "Morning", type: .compound), task("C1", title: "Stretch"), task("C2", title: "Coffee")] {
            try db.saveTask(t)
        }
        try insert(db, [
            link("l1", "P", "C1", 0), link("l2", "P", "C2", 1),
            placement("bt1", board: "B1", task: "P"), placement("bt2", board: "B2", task: "C1"),
        ])
        var structure = TaskEditPatch(title: "Morning")
        structure.operatorType = .and
        var c1 = ChildPatch(from: try XCTUnwrap(try fetchTask(db, "C1")))
        c1.title = "Stretch 10 min"
        structure.children = [c1, ChildPatch(from: try XCTUnwrap(try fetchTask(db, "C2")))]

        try commit(db, stagedId: "P", boardTaskId: "bt1", override("Morning", .compound, compound: structure))

        let c1Fork = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "C1")
        XCTAssertEqual(try fetchTask(db, c1Fork)?.title, "Stretch 10 min")
        XCTAssertEqual(try fetchTask(db, "C1")?.title, "Stretch")
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "P")))
        XCTAssertEqual(try liveChildIds(db, of: "P"), ["C2", c1Fork].sorted())
        XCTAssertEqual(try placedTaskId(db, "bt2"), "C1")
    }

    func testHolderPlacedElsewhereIsForkedFirstAndItsCopiedLinkRepointed() throws {
        let db = try makeDb()
        try seedBoards(db)
        for t in [task("T", title: "Walk"), task("H", title: "Habits", type: .compound), task("X", title: "Water")] {
            try db.saveTask(t)
        }
        try insert(db, [
            link("lh1", "H", "T", 0), link("lh2", "H", "X", 1),
            placement("bt1", board: "B1", task: "T"),
            placement("bt1h", board: "B1", task: "H", col: 1),
            placement("bt2h", board: "B2", task: "H"),
        ])

        try commit(db, stagedId: "T", boardTaskId: "bt1", override("Walk 5k"))

        let tFork = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")
        let hFork = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "H")
        XCTAssertEqual(try placedTaskId(db, "bt1"), tFork)
        XCTAssertEqual(try placedTaskId(db, "bt1h"), hFork)
        XCTAssertEqual(try placedTaskId(db, "bt2h"), "H")
        XCTAssertEqual(try liveChildIds(db, of: hFork), [tFork, "X"].sorted())
        XCTAssertEqual(try liveChildIds(db, of: "H"), ["T", "X"])
        XCTAssertEqual(try fetchTask(db, "T")?.title, "Walk")
    }

    func testOverrideOnAReplacedSquareIsDropped() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try db.saveTask(task("X", title: "Other"))
        try insert(db, [placement("bt1", board: "B1", task: "X"), placement("bt2", board: "B2", task: "T")])

        // The square now holds X; the override staged on T has no cell.
        try commit(db, stagedId: "T", boardTaskId: "bt1", cellTaskId: "X", override("Renamed"))

        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")))
        XCTAssertEqual(try fetchTask(db, "T")?.title, "Read")
    }

    func testReplayConvergesOnTheSameRows() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [
            placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T"),
            completion("e-in", task: "T", at: "2026-10-06T09:00:00.000Z"),
        ])
        func snapshot() throws -> [String] {
            try db.read { d in
                try Task.fetchAll(d).map(\.id).sorted()
                    + TaskEvent.fetchAll(d).map(\.id).sorted()
                    + BoardTask.fetchAll(d).map { "\($0.id):\($0.taskId)" }.sorted()
            }
        }

        try commit(db, stagedId: "T", boardTaskId: "bt1", override("Read more"))
        let first = try snapshot()
        try commit(db, stagedId: "T", boardTaskId: "bt1", cellTaskId: "T", override("Read more"))
        XCTAssertEqual(try snapshot(), first)
        XCTAssertEqual(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T"))?.title, "Read more")
    }

    func testSealedBoardNeverReachesTheFork() throws {
        let db = try makeDb()
        try db.saveBoard(try board("B1", start: Self.b1Start, end: Self.b1End, sealedAt: "2026-10-07T00:00:00.000Z"))
        try db.saveBoard(try board("B2", start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.999Z"))
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T")])

        XCTAssertThrowsError(try db.write { d in try AppDatabase.assertBoardEditable(db: d, boardId: "B1") })
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")))
    }

    func testWouldForkOnBoardReadsTheSameTest() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try db.saveTask(task("S", title: "Solo"))
        try insert(db, [
            placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T"),
            placement("bt3", board: "B1", task: "S", col: 1),
        ])
        XCTAssertTrue(db.wouldForkOnBoard(taskId: "T", boardId: "B1"))
        XCTAssertFalse(db.wouldForkOnBoard(taskId: "S", boardId: "B1"))
        XCTAssertFalse(db.wouldForkOnBoard(taskId: "pending", boardId: "B1"))
    }

    /// Runs Save step 7b for several overrides, in order, on B1 squares.
    private func commitAll(_ db: AppDatabase, _ items: [(stagedId: String, boardTaskId: String, ov: StagedTaskOverride)]) throws {
        let inputs = try items.map { BoardPlayViewModel.StagedOverrideInput(stagedId: $0.stagedId, override: $0.ov, mapTask: try fetchTask(db, $0.stagedId)) }
        let cells = items.map {
            BoardPlayViewModel.StagedCellRef(boardTaskId: $0.boardTaskId, isNew: false, row: 0, col: 0, stagedTaskId: $0.stagedId)
        }
        try db.write { d in
            try BoardPlayViewModel.applyStagedOverrides(
                db: d, boardId: "B1", overrides: inputs, cells: cells, now: "2026-10-08T12:00:00.000Z"
            )
        }
    }

    func testHolderEditedAfterItsSubTaskForkedInTheSameSaveKeepsTheFork() throws {
        let db = try makeDb()
        try seedBoards(db)
        for t in [task("C", title: "Stretch"), task("H", title: "Habits", type: .compound), task("X", title: "Water")] {
            try db.saveTask(t)
        }
        try insert(db, [
            link("lh1", "H", "C", 0), link("lh2", "H", "X", 1),
            placement("btc", board: "B1", task: "C"), placement("bth", board: "B1", task: "H", col: 1),
            placement("bt2", board: "B2", task: "C"),
        ])
        // The holder sheet was seeded from the stored rows: C still "Stretch".
        var structure = TaskEditPatch(title: "Habits renamed")
        structure.operatorType = .and
        structure.children = [ChildPatch(from: try XCTUnwrap(try fetchTask(db, "C"))), ChildPatch(from: try XCTUnwrap(try fetchTask(db, "X")))]

        try commitAll(db, [
            ("C", "btc", override("Stretch 10 min")),
            ("H", "bth", override("Habits renamed", .compound, compound: structure)),
        ])

        let cFork = BoardScopedFork.forkTaskId(boardId: "B1", taskId: "C")
        XCTAssertEqual(try liveChildIds(db, of: "H"), [cFork, "X"].sorted())
        XCTAssertEqual(try fetchTask(db, cFork)?.title, "Stretch 10 min")
        XCTAssertEqual(try fetchTask(db, "H")?.title, "Habits renamed")
    }

    func testAFailingLaterOverrideRollsTheForkBack() throws {
        let db = try makeDb()
        try seedBoards(db)
        try db.saveTask(task("T", title: "Read"))
        try db.saveTask(task("P", title: "Bad", type: .compound))
        try insert(db, [
            placement("bt1", board: "B1", task: "T"), placement("bt2", board: "B2", task: "T"),
            placement("btp", board: "B1", task: "P", col: 1),
        ])
        var empty = TaskEditPatch(title: "Bad")
        empty.operatorType = .and

        XCTAssertThrowsError(try commitAll(db, [
            ("T", "bt1", override("Renamed")),
            ("P", "btp", override("Bad", .compound, compound: empty)),
        ]))
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "B1", taskId: "T")))
        XCTAssertEqual(try placedTaskId(db, "bt1"), "T")
    }

    // MARK: - Sheet model

    func testSheetLabelAndConfirmRule() {
        XCTAssertEqual(SquareEditTaskSheet.doneLabel(wouldFork: true), "Save for this board")
        XCTAssertEqual(SquareEditTaskSheet.doneLabel(wouldFork: false), "Done")
        XCTAssertTrue(SquareEditTaskSheet.needsForkConfirm(wouldFork: true, confirmed: false))
        XCTAssertFalse(SquareEditTaskSheet.needsForkConfirm(wouldFork: true, confirmed: true))
        XCTAssertFalse(SquareEditTaskSheet.needsForkConfirm(wouldFork: false, confirmed: false))
        XCTAssertEqual(SquareEditTaskSheet.forkConfirmBody, "Applies to this board only. Other boards keep the original.")
    }

    func testSheetWouldForkCountsAChangedForkingSubTask() {
        let c = task("C", title: "Stretch")
        var draft = TaskEditPatch(title: "H")
        var step = ChildPatch(from: c)
        draft.children = [step]
        XCTAssertTrue(SquareEditTaskSheet.wouldFork(taskId: "H", draft: nil, forkingTaskIds: ["H"], rows: [:]))
        XCTAssertFalse(SquareEditTaskSheet.wouldFork(taskId: "H", draft: draft, forkingTaskIds: ["C"], rows: ["C": c]))
        step.title = "Stretch 10 min"
        draft.children = [step]
        XCTAssertTrue(SquareEditTaskSheet.wouldFork(taskId: "H", draft: draft, forkingTaskIds: ["C"], rows: ["C": c]))
        XCTAssertFalse(SquareEditTaskSheet.wouldFork(taskId: "H", draft: draft, forkingTaskIds: [], rows: ["C": c]))
    }

    // MARK: - Wizard

    private func wizardBoard() throws -> Board {
        try board("NEW", start: "2026-10-06T00:00:00.000Z", end: "2026-10-06T23:59:59.999Z")
    }

    func testWizardForksALibraryTaskPlacedOnAnotherBoard() throws {
        let db = try makeDb()
        try db.saveBoard(try board("B2", start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.999Z"))
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [
            placement("bt2", board: "B2", task: "T"),
            completion("e-in", task: "T", at: "2026-10-06T09:00:00.000Z"),
            completion("e-out", task: "T", at: "2026-10-08T09:00:00.000Z"),
        ])
        var patch = TaskEditPatch(title: "Read a chapter")
        patch.title = "Read a chapter"

        try db.saveWizardBoard(
            board: try wizardBoard(), boardTasks: [placement("new-0", board: "NEW", task: "T")],
            pendingTasks: [], stagedEdits: ["T": patch], isUpdate: false, now: "2026-10-06T12:00:00.000Z"
        )

        let forkId = BoardScopedFork.forkTaskId(boardId: "NEW", taskId: "T")
        let fork = try XCTUnwrap(try fetchTask(db, forkId))
        XCTAssertEqual(fork.title, "Read a chapter")
        XCTAssertTrue(fork.isCompleted)
        XCTAssertEqual(try fetchTask(db, "T")?.title, "Read")
        XCTAssertEqual(try placedTaskId(db, "new-0"), forkId)
        XCTAssertEqual(try placedTaskId(db, "bt2"), "T")
        let forkEvents = try db.read { try TaskEvent.filter(Column("taskId") == forkId).fetchAll($0) }
        XCTAssertEqual(forkEvents.map(\.id), [BoardScopedFork.forkedEventId(forkId: forkId, eventId: "e-in")])
        XCTAssertEqual(try db.read { try Board.fetchOne($0, key: "NEW") }?.completedTasks, 1)
    }

    func testWizardEditsInPlaceWhenPlacedNowhereElse() throws {
        let db = try makeDb()
        try db.saveTask(task("T", title: "Read"))

        try db.saveWizardBoard(
            board: try wizardBoard(), boardTasks: [placement("new-0", board: "NEW", task: "T")],
            pendingTasks: [], stagedEdits: ["T": TaskEditPatch(title: "Read more")], isUpdate: false,
            now: "2026-10-06T12:00:00.000Z"
        )

        XCTAssertEqual(try fetchTask(db, "T")?.title, "Read more")
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "NEW", taskId: "T")))
    }

    func testWizardPendingCompoundIsEditedInPlace() throws {
        let db = try makeDb()
        let parent = task("P", title: "Routine", type: .compound)
        let kid = task("K", title: "Stretch")
        var patch = TaskEditPatch(title: "Morning routine")
        patch.operatorType = .and
        patch.children = [ChildPatch(from: kid)]

        try db.saveWizardBoard(
            board: try wizardBoard(), boardTasks: [placement("new-0", board: "NEW", task: "P")],
            pendingTasks: [PendingTaskPayload(task: parent, childTasks: [kid], childLinks: [link("lk", "P", "K", 0)])],
            stagedEdits: ["P": patch], isUpdate: false, now: "2026-10-06T12:00:00.000Z"
        )

        XCTAssertEqual(try fetchTask(db, "P")?.title, "Morning routine")
        XCTAssertNil(try fetchTask(db, BoardScopedFork.forkTaskId(boardId: "NEW", taskId: "P")))
        XCTAssertEqual(try placedTaskId(db, "new-0"), "P")
    }

    func testPoolEditorPathStaysGlobal() throws {
        let db = try makeDb()
        try db.saveBoard(try board("B2", start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.999Z"))
        try db.saveTask(task("T", title: "Read"))
        try insert(db, [placement("bt2", board: "B2", task: "T")])

        try db.write { d in
            try AppDatabase.applyStagedTaskEdits(
                db: d, stagedEdits: ["T": TaskEditPatch(title: "Global")], strict: true, now: Self.t0
            )
        }

        XCTAssertEqual(try fetchTask(db, "T")?.title, "Global")
    }

    func testWizardSubTaskForkedInsideACompoundEditAlsoReplacesItsOwnSquare() throws {
        let db = try makeDb()
        try db.saveBoard(try board("B2", start: "2026-10-01T00:00:00.000Z", end: "2026-10-31T23:59:59.999Z"))
        let h = task("H", title: "Habits", type: .compound)
        let c = task("C", title: "Stretch")
        try db.saveTask(h)
        try db.saveTask(c)
        try insert(db, [link("lhc", "H", "C", 0), placement("bt2", board: "B2", task: "C")])
        var patch = TaskEditPatch(title: "Habits")
        patch.operatorType = .and
        var step = ChildPatch(from: c)
        step.title = "Stretch 10 min"
        patch.children = [step]

        try db.saveWizardBoard(
            board: try wizardBoard(),
            boardTasks: [placement("new-0", board: "NEW", task: "H"), placement("new-1", board: "NEW", task: "C", col: 1)],
            pendingTasks: [], stagedEdits: ["H": patch], isUpdate: false, manualTaskIds: ["H", "C"],
            now: "2026-10-06T12:00:00.000Z"
        )

        let cFork = BoardScopedFork.forkTaskId(boardId: "NEW", taskId: "C")
        XCTAssertEqual(try fetchTask(db, cFork)?.title, "Stretch 10 min")
        XCTAssertEqual(try placedTaskId(db, "new-0"), "H")
        XCTAssertEqual(try placedTaskId(db, "new-1"), cFork)
        XCTAssertEqual(try liveChildIds(db, of: "H"), [cFork])
        XCTAssertEqual(try placedTaskId(db, "bt2"), "C")
    }
}
