import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 4 — final self-review regressions for the
/// closed-board late-log path (twins of the web additions in
/// `lateLog.test.ts` / `lateLogUndo.test.ts`): the R1 variant with a CLOSED
/// weekly + OPEN monthly + a Friday daily, a real mid-transaction rollback,
/// window-stamped-derived late-log undo + re-freeze, plain-source
/// propagation, compound COUNTING-child staging + pre-check, and the counter
/// Undo toast's seal immunity / sealed re-derive.
@MainActor
final class LateLogReviewRegressionTests: XCTestCase {

    private let userId = "u1"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeTask(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil,
        sharedCounterId: String? = nil, startDate: String? = nil, endDate: String? = nil,
        createdInWizard: Bool = false, baseline: CountValue? = nil, currentCount: CountValue? = nil,
        isCompleted: Bool = false, operatorType: OperatorType? = nil, threshold: Int? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: type,
            action: type == .counting ? "Do" : nil, unit: type == .counting ? "reps" : nil,
            maxCount: maxCount, operatorType: operatorType, threshold: threshold,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: nil, currentCount: currentCount,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: startDate, endDate: endDate,
            sharedCounterId: sharedCounterId, baseline: baseline, lastSyncedCount: nil,
            createdInWizard: createdInWizard
        )
    }

    private func makeBoard(
        id: String, startDate: String, endDate: String,
        status: BoardStatus = .active, sealedAt: String? = nil, sealedCompletedCells: [Int]? = nil,
        timeframe: Timeframe = .daily, size: Int = 1
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": status.rawValue,
            "boardSize": size, "timeframe": timeframe.rawValue,
            "startDate": startDate, "endDate": endDate,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": size * size, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": startDate, "version": 1, "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let cells = sealedCompletedCells,
           let data = try? JSONEncoder().encode(cells),
           let str = String(data: data, encoding: .utf8) {
            dict["sealedCompletedCells"] = str
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, cell: Int = 0, size: Int = 1) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: cell / size, col: cell % size,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func fetchBoard(_ db: AppDatabase, _ id: String) throws -> Board { try db.fetchBoard(id: id)! }

    private func events(_ db: AppDatabase, taskId: String) throws -> [TaskEvent] {
        try db.read { try TaskEvent.filter(Column("taskId") == taskId).fetchAll($0) }
    }

    private let dailyStart = "2026-07-07T00:00:00.000Z" // Tuesday
    private let dailyEnd = "2026-07-08T00:00:00.000Z"

    // MARK: - R1 variant

    func test_R1_counting_closedWeekly_openMonthly_fridayDailyUntouched_lifetimePlusFive() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-run", type: .counting, maxCount: 5))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t-run"))
        try db.saveBoard(makeBoard(id: "W", startDate: "2026-07-06T00:00:00.000Z", endDate: "2026-07-13T00:00:00.000Z",
                                    sealedAt: "2026-07-14T00:00:00.000Z", sealedCompletedCells: [], timeframe: .weekly))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "W", taskId: "t-run"))
        try db.saveBoard(makeBoard(id: "M", startDate: "2026-07-01T00:00:00.000Z", endDate: "2026-07-31T00:00:00.000Z",
                                    timeframe: .monthly))
        try db.saveBoardTask(makeBoardTask(id: "bt-m", boardId: "M", taskId: "t-run"))
        try db.saveBoard(makeBoard(id: "fri", startDate: "2026-07-10T00:00:00.000Z", endDate: "2026-07-11T00:00:00.000Z"))
        try db.saveBoardTask(makeBoardTask(id: "bt-fri", boardId: "fri", taskId: "t-run"))

        try db.lateLogIncrement(boardId: "D", taskId: "t-run", delta: 5, now: "2026-07-15T10:00:00.000Z")

        let ev = try events(db, taskId: "t-run")
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(ev[0].occurredAt, dailyEnd)
        XCTAssertEqual(ev[0].boardId, "D")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])
        XCTAssertEqual(try fetchBoard(db, "W").sealedCompletedCells, [0], "the CLOSED weekly re-derives too")
        XCTAssertEqual(try fetchBoard(db, "W").version, 1, "sealed re-derivation is local-only")
        XCTAssertEqual(try fetchBoard(db, "M").completedTasks, 1, "the OPEN monthly live-cascades")
        XCTAssertEqual(try fetchBoard(db, "fri").completedTasks, 0, "Friday's daily never counts a Tuesday-stamped log")
        XCTAssertEqual(try db.fetchTask(id: "t-run")?.currentCount, 5, "lifetime cache +5")
    }

    // MARK: - One transaction: a mid-transaction failure rolls everything back

    func test_lateLog_rollsBackEventCachesAndBoards_whenASealedReDeriveFails() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-run", type: .counting, maxCount: 5))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t-run"))
        try db.saveBoard(makeBoard(id: "M", startDate: "2026-07-01T00:00:00.000Z", endDate: "2026-07-31T00:00:00.000Z",
                                    sealedAt: "2026-08-02T00:00:00.000Z", sealedCompletedCells: [], timeframe: .monthly))
        try db.saveBoardTask(makeBoardTask(id: "bt-m", boardId: "M", taskId: "t-run"))
        // Make the sealed monthly's re-derive write fail mid-transaction.
        try db.write { try $0.execute(sql: """
            CREATE TEMP TRIGGER fail_monthly BEFORE UPDATE ON boards WHEN NEW.id = 'M'
            BEGIN SELECT RAISE(ABORT, 'boom'); END
            """) }

        XCTAssertThrowsError(try db.lateLogIncrement(boardId: "D", taskId: "t-run", delta: 5, now: "2026-07-10T12:00:00.000Z"))

        XCTAssertEqual(try events(db, taskId: "t-run").count, 0, "the event rolls back")
        XCTAssertEqual(try db.fetchTask(id: "t-run")?.currentCount ?? 0, 0, "the lifetime cache rolls back")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [], "the closed daily rolls back")
    }

    // MARK: - Plain source counter: propagate to hub-linked rows (web parity)

    func test_lateLogIncrement_plainSource_propagatesToHubLinkedRow() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t-root", type: .counting, maxCount: 10, currentCount: 0))
        try db.saveTask(makeTask("t-hub", type: .counting, maxCount: 10, sharedCounterId: "t-root",
                                  startDate: nil, baseline: 0, currentCount: 0))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t-root"))

        try db.lateLogIncrement(boardId: "D", taskId: "t-root", delta: 3, now: "2026-07-10T12:00:00.000Z")

        XCTAssertEqual(try db.fetchTask(id: "t-root")?.currentCount, 3)
        XCTAssertEqual(try db.fetchTask(id: "t-hub")?.currentCount, 3, "the hub-linked row mirrors the root, like incrementSharedCounter")
    }

    // MARK: - Window-stamped derived: late log is undoable, and re-freezes

    private func seedDerivedFixture(_ db: AppDatabase) throws {
        try db.saveTask(makeTask("R", type: .counting, maxCount: 100))
        try db.saveTask(makeTask("Dd", type: .counting, maxCount: 5, sharedCounterId: "R",
                                  startDate: dailyStart, endDate: dailyEnd, createdInWizard: true, baseline: 0))
        try db.saveTask(makeTask("Dw", type: .counting, maxCount: 5, sharedCounterId: "R",
                                  startDate: "2026-07-06T00:00:00.000Z", endDate: "2026-07-13T00:00:00.000Z",
                                  createdInWizard: true, baseline: 0))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "Dd"))
        try db.saveBoard(makeBoard(id: "W", startDate: "2026-07-06T00:00:00.000Z", endDate: "2026-07-13T00:00:00.000Z",
                                    timeframe: .weekly))
        try db.saveBoardTask(makeBoardTask(id: "bt-w", boardId: "W", taskId: "Dw"))
    }

    func test_undoLateLog_windowStampedDerived_undoesTheRootLateLog() throws {
        let db = try makeDb(); try seedUser(db)
        try seedDerivedFixture(db)
        try db.lateLogIncrement(boardId: "D", taskId: "Dd", delta: 5, now: "2026-07-10T12:00:00.000Z")
        XCTAssertEqual(try events(db, taskId: "R").first?.boardId, "D", "a derived late log carries the closed board's id")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])

        try db.undoLateLog(boardId: "D", taskId: "R", now: "2026-07-10T13:00:00.000Z")

        XCTAssertTrue(try events(db, taskId: "R").allSatisfy(\.isDeleted), "the root late log is tombstoned")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [], "the closed daily reverts")
    }

    func test_undoLateLog_windowStampedDerived_refreezesWhenASiblingDerivedBoardSealsLater() throws {
        let db = try makeDb(); try seedUser(db)
        try seedDerivedFixture(db)
        try db.lateLogIncrement(boardId: "D", taskId: "Dd", delta: 5, now: "2026-07-10T12:00:00.000Z")
        // The weekly — placing only ITS OWN derived row of R — closes after the log.
        XCTAssertTrue(try db.closeBoard(boardId: "W", now: "2026-07-14T00:00:00.000Z"))
        XCTAssertEqual(try fetchBoard(db, "W").sealedCompletedCells, [0])

        try db.undoLateLog(boardId: "D", taskId: "R", now: "2026-07-15T00:00:00.000Z")

        XCTAssertFalse(try events(db, taskId: "R").contains(where: \.isDeleted), "re-frozen by W's later seal — undo is a no-op")
        XCTAssertEqual(try fetchBoard(db, "W").sealedCompletedCells, [0])
    }

    // MARK: - Compound: a staged +1 on a plain COUNTING child (D7) + pre-check

    func test_lateLogCompoundParts_countingChildPlusOne_meetsAndRule_previewAgrees() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("c1", type: .compound, operatorType: .and))
        try db.saveTask(makeTask("n1"))
        try db.saveTask(makeTask("k1", type: .counting, maxCount: 3))
        let now = AppDatabase.currentTimestamp()
        try db.write { db in
            try CompoundChild(id: "l1", compoundTaskId: "c1", childTaskId: "n1", childIndex: 0,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(db)
            try CompoundChild(id: "l2", compoundTaskId: "c1", childTaskId: "k1", childIndex: 1,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(db)
            // k1 at 2/3 inside the window, plus 5 from a PREVIOUS window (ignored).
            for (id, delta, at) in [("in", 2, "2026-07-07T09:00:00.000Z"), ("prev", 5, "2026-07-06T09:00:00.000Z")] as [(String, CountValue, String)] {
                try TaskEvent(id: id, userId: self.userId, taskId: "k1", kind: .increment, delta: delta,
                              occurredAt: at, boardId: nil, createdAt: at, updatedAt: at,
                              lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(db)
            }
        }
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "c1"))

        let (board, taskById, children, eventsByTaskId): (Board, [String: Task], [String: [CompoundChild]], [String: [TaskEvent]]) = try db.read { db in
            let tasks = Dictionary(uniqueKeysWithValues: try Task.fetchAll(db).map { ($0.id, $0) })
            let links = Dictionary(grouping: try CompoundChild.fetchAll(db), by: \.compoundTaskId)
            let evs = Dictionary(grouping: try TaskEvent.fetchAll(db), by: \.taskId)
            return (try Board.fetchOne(db, key: "D")!, tasks, links, evs)
        }
        func preview(_ ids: Set<String>) -> AppDatabase.CompoundLateLogPlan {
            AppDatabase.planCompoundLateLog(
                board: board, compound: taskById["c1"]!, requestedChildIds: ids, taskById: taskById,
                childrenByCompound: children, eventsByTaskId: eventsByTaskId,
                occurredAt: dailyEnd, now: "2026-07-10T12:00:00.000Z"
            )
        }
        XCTAssertFalse(preview(["n1"]).isRuleMet, "2/3 alone does not finish k1")
        XCTAssertTrue(preview(["n1", "k1"]).isRuleMet, "a staged +1 finishes k1 (3/3)")

        try db.lateLogCompoundParts(boardId: "D", compoundTaskId: "c1", childTaskIds: ["n1", "k1"],
                                    now: "2026-07-10T12:00:00.000Z")
        let k1Late = try events(db, taskId: "k1").filter { $0.boardId == "D" }
        XCTAssertEqual(k1Late.map(\.delta), [1])
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])
    }

    // MARK: - Counter Undo toast (undoLastCounterLog): immunity + sealed re-derive

    func test_undoLastCounterLog_refusesASealImmuneEntry() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 5, currentCount: 2))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t1"))
        try db.write { db in
            try TaskEvent(id: "pre", userId: self.userId, taskId: "t1", kind: .increment, delta: 2,
                          occurredAt: "2026-07-07T09:00:00.000Z", boardId: nil,
                          createdAt: "2026-07-07T09:00:00.000Z", updatedAt: "2026-07-07T09:00:00.000Z",
                          lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil).save(db)
        }

        let result = try db.undoLastCounterLog(sourceTaskId: "t1")

        XCTAssertEqual(result.undoneAmount, 0)
        XCTAssertFalse(try events(db, taskId: "t1")[0].isDeleted, "sealed history stays immune")
        XCTAssertEqual(try db.fetchTask(id: "t1")?.currentCount, 2)
    }

    func test_undoLastCounterLog_reDerivesTheSealedBoardOfAnUndoneLateLog() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveTask(makeTask("t1", type: .counting, maxCount: 5))
        try db.saveBoard(makeBoard(id: "D", startDate: dailyStart, endDate: dailyEnd,
                                    sealedAt: "2026-07-09T00:00:00.000Z", sealedCompletedCells: []))
        try db.saveBoardTask(makeBoardTask(id: "bt-d", boardId: "D", taskId: "t1"))
        try db.lateLogIncrement(boardId: "D", taskId: "t1", delta: 5, now: "2026-07-10T12:00:00.000Z")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0])

        let result = try db.undoLastCounterLog(sourceTaskId: "t1")

        XCTAssertEqual(result.undoneAmount, 5)
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [], "the closed board re-derives in the same transaction")
    }

    // MARK: - ViewModel path: window-stamped derived late log (F1)

    /// Pump the main run loop until `predicate` holds (mirrors
    /// `BoardPlayViewModelBoardActionsTests`' house style).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    /// Bridges a VM `async throws` call back to this synchronous test.
    private func run(_ operation: @escaping () async throws -> Void) -> Error? {
        var caughtError: Error?
        var done = false
        _Concurrency.Task { @MainActor in
            do { try await operation() } catch { caughtError = error }
            done = true
        }
        XCTAssertTrue(waitUntil { done }, "the async operation never completed")
        return caughtError
    }

    /// F1 regression: the late-log sheet's counting branch drives the VM with
    /// the tapped (PLACED) derived square. The VM must hand the DB the placed
    /// id (the DB resolves the root itself) — passing the pre-resolved root
    /// threw `taskNotPlaced` on every derived square. Undo still targets the
    /// root's late log through the same VM.
    func test_viewModel_lateLogIncrement_windowStampedDerived_appendsOnRoot_andUndoes() throws {
        let db = try makeDb(); try seedUser(db)
        try seedDerivedFixture(db)
        let vm = BoardPlayViewModel(boardId: "D", userId: userId, database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "D" && vm.taskMap["Dd"] != nil })
        let derived = try XCTUnwrap(vm.taskMap["Dd"])

        let error = run { try await vm.commitLateLogIncrement(for: derived, delta: 5) }
        XCTAssertNil(error, "a derived square's late log must not throw (was taskNotPlaced)")

        let rootEvents = try events(db, taskId: "R")
        XCTAssertEqual(rootEvents.count, 1)
        XCTAssertEqual(rootEvents.first?.delta, 5)
        XCTAssertEqual(rootEvents.first?.occurredAt, dailyEnd, "stamped at the closed board's endDate")
        XCTAssertEqual(rootEvents.first?.boardId, "D")
        XCTAssertTrue(try events(db, taskId: "Dd").isEmpty, "derived rows own no events")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [0], "the sealed snapshot re-derives")
        XCTAssertTrue(waitUntil { vm.hasClosedBoardLateLog(for: derived) }, "Undo late log is offered")

        let undoError = run { try await vm.undoLateLog(for: derived) }
        XCTAssertNil(undoError)
        XCTAssertTrue(try events(db, taskId: "R").allSatisfy(\.isDeleted), "only that late log is tombstoned")
        XCTAssertEqual(try fetchBoard(db, "D").sealedCompletedCells, [], "the closed daily reverts")
    }
}
