import Combine
import GRDB
import XCTest
@testable import OYBC

/// The instant-count half of the board-log lag fix: a write registers an optimistic delta on
/// its counter family that every board-play count read adds on top of the loaded count, until
/// the reload carrying the write has applied (or the write fails and the delta rolls back).
@MainActor
final class BoardPlayOptimisticCountTests: XCTestCase {

    private let userId = "u1"
    private var bag = Set<AnyCancellable>()

    // MARK: Fixtures

    private func seed(_ db: AppDatabase, counterRoot: Bool) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        let dict: [String: Any] = [
            "id": "b1", "userId": userId, "name": "Week", "status": BoardStatus.active.rawValue, "boardSize": 1,
            "timeframe": Timeframe.monthly.rawValue, "startDate": "2026-06-01T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false, "totalTasks": 1,
            "completedTasks": 0, "linesCompleted": 0, "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000", "version": 1, "isDeleted": false,
        ]
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict)))
        var t = Task(
            id: "c1", userId: userId, title: "Read", type: .counting, action: "Read", unit: "pages", maxCount: 20,
            totalCompletions: 0, totalInstances: 0, createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
        if counterRoot { t.isCounter = true }
        try db.saveTask(t)
        try db.saveBoardTask(BoardTask(
            id: "bt1", boardId: "b1", taskId: "c1", row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
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

    private func sum(_ db: AppDatabase, _ taskId: String) throws -> CountValue {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) }
            .reduce(0) { $0 + ($1.delta ?? 0) }
    }

    private func shown(_ vm: BoardPlayViewModel) -> CountValue {
        vm.displayCount(of: vm.placementRender(for: vm.boardTasks[0]))
    }

    /// Samples `shown` after every publish of the view model (what a render would read).
    private func recordShown(_ vm: BoardPlayViewModel) -> () -> [CountValue] {
        var samples: [CountValue] = []
        vm.objectWillChange.sink { [unowned vm] _ in
            DispatchQueue.main.async { samples.append(vm.displayCount(of: vm.placementRender(for: vm.boardTasks[0]))) }
        }.store(in: &bag)
        return { samples }
    }

    // MARK: Shared counter (the root and its linked rows)

    func test_aLogMovesTheCountOnTap_holdsUntilTheReloadApplies_thenHandsOverWithoutAFlicker() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: true)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        XCTAssertEqual(shown(vm), 0)
        let samples = recordShown(vm)

        vm.snapshotDelay = 0.4 // hold the reload so the write-landed / reload-pending window is observable
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 5)

        XCTAssertEqual(shown(vm), 5, "the number moves on the tap, before any write or reload")
        XCTAssertTrue(waitUntil { (try? self.sum(db, "c1")) == 5 }, "the write landed")
        XCTAssertTrue(vm.isProcessing, "reload still pending")
        XCTAssertEqual(vm.windowedBaseCountValue(try XCTUnwrap(vm.taskMap["c1"])), 0, "loaded state is still pre-write")
        XCTAssertEqual(shown(vm), 5, "the optimistic delta carries the display until the reload lands")

        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertTrue(vm.pendingCountDeltas.isEmpty, "cleared with the reload that carries the write")
        XCTAssertEqual(vm.windowedBaseCountValue(try XCTUnwrap(vm.taskMap["c1"])), 5)
        XCTAssertEqual(shown(vm), 5)
        _ = waitUntil(timeout: 0.2) { false }
        let seen = samples()
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen, seen.sorted(), "never new -> old -> new")
        XCTAssertEqual(seen.last, 5)
    }

    func test_undoMovesTheCountAtOnce_andRemoveClampsAtWhatTheBoardShows() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: true)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 5)
        XCTAssertTrue(waitUntil { !vm.isProcessing && self.shown(vm) == 5 })

        vm.snapshotDelay = 0.4
        vm.undoSharedCounterLog(sourceTaskId: "c1")
        XCTAssertEqual(shown(vm), 0, "Undo moves the number on the tap too")
        XCTAssertTrue(waitUntil { (try? self.sum(db, "c1")) == 0 })
        XCTAssertEqual(shown(vm), 0, "still held until the reload applies")
        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertEqual(shown(vm), 0)

        vm.snapshotDelay = 0
        vm.handleCountingDecrement(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 3)
        XCTAssertEqual(shown(vm), 0, "a removal never shows below zero")
        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertEqual(shown(vm), 0)
    }

    func test_aFailedWriteRollsTheOptimisticCountBack_andLeavesTheExistingErrorPath() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: true)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        let samples = recordShown(vm)
        try db.write { try $0.execute(sql: "DROP TABLE task_events") } // the write throws

        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 5)
        XCTAssertEqual(shown(vm), 5, "optimistic until the write reports back")
        XCTAssertTrue(waitUntil { !vm.isProcessing })

        XCTAssertTrue(vm.pendingCountDeltas.isEmpty, "rolled back")
        XCTAssertEqual(shown(vm), 0)
        _ = waitUntil(timeout: 0.2) { false }
        XCTAssertEqual(samples().last, 0)
    }

    // MARK: Standalone counter (orchestration path)

    func test_aStandaloneCounterTap_isOptimisticToo() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: false)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        vm.snapshotDelay = 0.3
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 4)
        XCTAssertEqual(shown(vm), 4)
        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertTrue(vm.pendingCountDeltas.isEmpty)
        XCTAssertEqual(shown(vm), 4)
        XCTAssertEqual(vm.windowedState(forTaskId: "c1").count, 4)
    }

    // MARK: Menu + sheet read the same optimistic count

    func test_theSheetsAndMenusCountFollowsTheOptimisticDelta() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: true)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        let task = try XCTUnwrap(vm.placedTask(bt))
        vm.snapshotDelay = 0.4
        vm.handleCountingTap(boardTask: bt, task: task, amount: 5)

        XCTAssertEqual(vm.squareCountState(task).current, 5, "sheet body")
        XCTAssertEqual(
            vm.squareCountState(task).chips, CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 5),
            "chips are measured from the moved count"
        )
        let menu = try XCTUnwrap(vm.menuInput(for: vm.placementRender(for: bt)))
        guard case let .counting(c) = menu.body else { return XCTFail("counting menu") }
        XCTAssertEqual(c.current, 5, "hold menu header")
        XCTAssertTrue(waitUntil { !vm.isProcessing })
    }

    // MARK: Busy look

    func test_theBusyLookWaitsForTheDelay_whileTheGuardIsImmediate() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, counterRoot: true)
        let vm = loadedVM(db)
        let bt = try XCTUnwrap(vm.boardTasks.first)
        XCTAssertFalse(vm.showsBusyLook)
        vm.snapshotDelay = 0.7
        vm.handleCountingTap(boardTask: bt, task: try XCTUnwrap(vm.taskMap["c1"]), amount: 1)

        XCTAssertTrue(vm.isProcessing, "controls go inert at once")
        XCTAssertFalse(vm.showsBusyLook, "but do not look busy yet")
        XCTAssertTrue(waitUntil(timeout: 5) { vm.showsBusyLook }, "still in flight after the delay: dims")
        XCTAssertTrue(vm.isProcessing)
        XCTAssertTrue(waitUntil { !vm.isProcessing })
        XCTAssertFalse(vm.showsBusyLook, "clears with the write")
    }
}
