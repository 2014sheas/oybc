import XCTest
import GRDB
@testable import OYBC

/// The view-model half of the square sheet's one-gesture logging: the explicit
/// amount on a compound child's `+`, and the Undo recipes (`squareLogUndo` /
/// `undoSquareLog`). Web twin: `compoundChildIncrement` + the sheet's glue tests.
@MainActor
final class BoardPlayViewModelSquareSheetTests: XCTestCase {

    private let userId = "u1"

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func board(_ id: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board \(id)", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        return try! JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func task(_ id: String, type: TaskType, maxCount: CountValue? = nil, sharedCounterId: String? = nil, isCounter: Bool = false) -> Task {
        let now = AppDatabase.currentTimestamp()
        var t = Task(
            id: id, userId: userId, title: id, type: type, action: nil, unit: "pages", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId
        )
        if type == .compound { t.operatorType = .and }
        if isCounter { t.isCounter = true }
        return t
    }

    private func place(_ db: AppDatabase, bt: String, taskId: String) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: bt, boardId: "b1", taskId: taskId, row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func link(_ db: AppDatabase, parent: String, child: String) throws {
        let now = AppDatabase.currentTimestamp()
        try db.write { d in
            try CompoundChild(
                id: "\(parent)-\(child)", compoundTaskId: parent, childTaskId: child, childIndex: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            ).save(d)
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: userId, database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        return vm
    }

    private func events(_ db: AppDatabase, _ taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) }
    }

    // MARK: - Undo recipes

    func test_squareLogUndo_placedStandalone_restoresTheStartingCount() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("c1", type: .counting, maxCount: 20))
        try place(db, bt: "bt-c1", taskId: "c1")
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        let t = try XCTUnwrap(vm.taskMap["c1"])

        let undo = vm.squareLogUndo(for: t, placement: bt, delta: 5)
        XCTAssertEqual(undo, .restoreCount(taskId: "c1", boardTaskId: "bt-c1", count: 0))

        vm.handleCountingTap(boardTask: bt, task: t, amount: 5)
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.windowedState(forTaskId: "c1").count == 5 })

        vm.undoSquareLog(undo)
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.windowedState(forTaskId: "c1").count == 0 })
    }

    func test_squareLogUndo_sharedCounter_reversesTheCountersLastLog() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("root", type: .counting, maxCount: 20, isCounter: true))
        try place(db, bt: "bt-root", taskId: "root")
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        let t = try XCTUnwrap(vm.taskMap["root"])

        let undo = vm.squareLogUndo(for: t, placement: bt, delta: 5)
        XCTAssertEqual(undo, .counterLog(sourceTaskId: "root"))

        vm.handleCountingTap(boardTask: bt, task: t, amount: 5)
        XCTAssertTrue(waitUntil { !vm.isProcessing && (try? self.events(db, "root").count) == 1 })
        vm.undoSquareLog(undo)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "root").reduce(0) { $0 + ($1.delta ?? 0) }) ?? 1) == 0 })
    }

    // MARK: - Compound child logs

    func test_compoundChild_unplaced_logsTheChipAmount_andUndoRemovesIt() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .counting, maxCount: 20))
        try place(db, bt: "bt-cmp", taskId: "cmp")
        try link(db, parent: "cmp", child: "kid")
        let vm = loadedVM(db)
        let kid = try XCTUnwrap(vm.taskMap["kid"])
        XCTAssertNil(vm.boardTasks.first { $0.taskId == "kid" })

        let undo = vm.squareLogUndo(for: kid, placement: nil, delta: 5)
        XCTAssertEqual(undo, .childDelta(taskId: "kid", delta: 5))

        vm.handleCompoundChildIncrement(childTask: kid, direction: 1, amount: 5)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "kid").reduce(0) { $0 + ($1.delta ?? 0) }) ?? 0) == 5 })

        vm.undoSquareLog(undo)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "kid").reduce(0) { $0 + ($1.delta ?? 0) }) ?? 1) == 0 })
    }

    func test_compoundChild_linkedChildLogsTheExplicitAmountNotTheCountersDefault() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        var root = task("root", type: .counting, maxCount: nil, isCounter: true)
        root.defaultLogAmount = 10
        try db.saveTask(root)
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .counting, maxCount: 20, sharedCounterId: "root"))
        try place(db, bt: "bt-cmp", taskId: "cmp")
        try link(db, parent: "cmp", child: "kid")
        let vm = loadedVM(db)
        let kid = try XCTUnwrap(vm.taskMap["kid"])

        vm.handleCompoundChildIncrement(childTask: kid, direction: 1, amount: 5)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "root").reduce(0) { $0 + ($1.delta ?? 0) }) ?? 0) == 5 })

        // No amount → the counter's remembered default, as before.
        vm.handleCompoundChildIncrement(childTask: kid, direction: 1)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "root").reduce(0) { $0 + ($1.delta ?? 0) }) ?? 0) == 15 })
    }

    func test_unplacedChild_otherAmountPersistsAsTheChildsDefault_chipDoesNot() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .counting, maxCount: 20))
        try place(db, bt: "bt-cmp", taskId: "cmp")
        try link(db, parent: "cmp", child: "kid")
        let vm = loadedVM(db)
        let kid = try XCTUnwrap(vm.taskMap["kid"])

        vm.handleCompoundChildIncrement(childTask: kid, direction: 1, amount: 5, persistAsDefault: false)
        XCTAssertTrue(waitUntil { !vm.isProcessing && ((try? self.events(db, "kid").count) ?? 0) == 1 })
        XCTAssertNil(try db.fetchTasks(userId: userId).first { $0.id == "kid" }?.defaultLogAmount)

        vm.handleCompoundChildIncrement(childTask: kid, direction: 1, amount: 7, persistAsDefault: true)
        XCTAssertTrue(waitUntil { !vm.isProcessing && (try? self.db(db, "kid")?.defaultLogAmount) == 7 })
    }

    private func db(_ db: AppDatabase, _ id: String) throws -> Task? {
        try db.fetchTasks(userId: userId).first { $0.id == id }
    }

    // MARK: - Normal Undo restores the PRIOR state

    func test_setNormalCompleted_isExplicit_notAToggle() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("n1", type: .normal))
        try place(db, bt: "bt-n1", taskId: "n1")
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)

        // Complete, then un-complete (the toast would carry wasDone = true).
        vm.handleNormalTap(boardTask: bt)
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.windowedState(forTaskId: "n1").isCompleted })
        vm.handleNormalTap(boardTask: bt)
        XCTAssertTrue(waitUntil { !vm.isProcessing && !vm.windowedState(forTaskId: "n1").isCompleted })

        // Undo restores done; a second Undo tap leaves it done (no toggle back).
        XCTAssertTrue(vm.setNormalCompleted(boardTask: bt, completed: true))
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.windowedState(forTaskId: "n1").isCompleted })
        XCTAssertTrue(vm.setNormalCompleted(boardTask: bt, completed: true))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(vm.windowedState(forTaskId: "n1").isCompleted)
    }

    func test_setNormalCompleted_reportsBusyAndWritesNothing() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("n1", type: .normal))
        try place(db, bt: "bt-n1", taskId: "n1")
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)

        vm.handleNormalTap(boardTask: bt) // write in flight
        XCTAssertTrue(vm.isProcessing)
        XCTAssertFalse(vm.setNormalCompleted(boardTask: bt, completed: false), "busy → the caller keeps its toast")
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.windowedState(forTaskId: "n1").isCompleted })
    }

    // MARK: - Compound child toggle Undo

    func test_restoreToggle_revertsToThePriorState_andIsIdempotent() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.saveBoard(board("b1"))
        try db.saveTask(task("cmp", type: .compound))
        try db.saveTask(task("kid", type: .normal))
        try place(db, bt: "bt-cmp", taskId: "cmp")
        try link(db, parent: "cmp", child: "kid")
        let vm = loadedVM(db)
        let kid = try XCTUnwrap(vm.taskMap["kid"])

        vm.handleCompoundChildToggle(childTask: kid)
        XCTAssertTrue(waitUntil { !vm.isProcessing && vm.compoundChildIsCompleted(kid) })

        vm.undoSquareLog(.restoreToggle(taskId: "kid", wasDone: false))
        XCTAssertTrue(waitUntil { !vm.isProcessing && !vm.compoundChildIsCompleted(kid) })
        vm.undoSquareLog(.restoreToggle(taskId: "kid", wasDone: false)) // already holds → no-op
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(vm.compoundChildIsCompleted(kid))
    }
}
