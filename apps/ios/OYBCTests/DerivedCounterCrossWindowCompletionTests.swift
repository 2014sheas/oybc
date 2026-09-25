import XCTest
import GRDB
@testable import OYBC

/// REPRO — owner report 2026-09-23 (branch
/// `bugfix/derived-counter-cross-window-completion`): "Completing a shared
/// counter task on a daily board with a counter task pulled in from a weekly
/// board seems to complete the task on the weekly board as well, even if the
/// weekly board has a larger goal count that is not met yet."
///
/// Swift twin of `apps/web/src/db/operations/__tests__/derivedCounterCrossWindowCompletion.test.ts`.
/// Production paths only: `saveWizardBoard` (wizard active save → mint),
/// `incrementSharedCounter` (what `BoardPlayViewModel.handleCountingTap`
/// routes a shared cell to), `DerivationPass.computeBoardGrid` with
/// `buildWindowContext` (the play grid's per-cell resolver).
final class DerivedCounterCrossWindowCompletionTests: XCTestCase {

    private let userId = "u1"
    private let rootId = "root-1"
    private let monthlyId = "monthly-src"

    // Windows are built around the REAL clock: `incrementSharedCounter`
    // stamps its event with `currentTimestamp()` (real now), so the boards
    // must contain now.
    private var cal: Calendar { Calendar.current }
    private var today: Date { cal.startOfDay(for: Date()) }
    private var dayStart: String { wizardLocalISOString(today) }
    private var dayEnd: String { wizardLocalISOString(today.addingTimeInterval(86_400 - 0.001)) }
    private var weekStartDate: Date { today.addingTimeInterval(-2 * 86_400) }
    private var weekStart: String { wizardLocalISOString(weekStartDate) }
    private var weekEnd: String { wizardLocalISOString(weekStartDate.addingTimeInterval(7 * 86_400 - 0.001)) }
    private var historyAt: String { wizardLocalISOString(today.addingTimeInterval(-13 * 86_400)) }
    private let seedNow = "2026-08-01T00:00:00.000Z"

    private func makeDb() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try database.write { db in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: seedNow, updatedAt: seedNow, lastSyncedAt: nil, version: 1
            ).save(db)
        }
        return database
    }

    private func board(id: String, timeframe: Timeframe, start: String, end: String) throws -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": id, "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": timeframe.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": seedNow, "updatedAt": seedNow, "version": 1, "isDeleted": false,
        ]
        return try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private func placement(boardId: String, taskId: String) -> BoardTask {
        BoardTask(
            id: "bt-\(boardId)", boardId: boardId, taskId: taskId,
            row: 0, col: 0, isCenter: false,
            createdAt: seedNow, updatedAt: seedNow, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// Root counter with goal `goal`; `history` increments logged two weeks ago.
    private func seedRoot(_ database: AppDatabase, goal: Int, history: Int) throws {
        try database.write { db in
            try Task(
                id: self.rootId, userId: self.userId, title: "Read \(goal) pages", type: .counting,
                action: "Read", unit: "pages", maxCount: goal,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: history >= goal, currentCount: history,
                createdAt: self.seedNow, updatedAt: self.seedNow, version: 1, isDeleted: false
            ).save(db)
            if history > 0 {
                try TaskEvent(
                    id: "hist-1", userId: self.userId, taskId: self.rootId, kind: .increment, delta: history,
                    occurredAt: self.historyAt, boardId: nil,
                    createdAt: self.historyAt, updatedAt: self.historyAt, lastSyncedAt: nil,
                    version: 1, isDeleted: false, deletedAt: nil
                ).save(db)
            }
        }
    }

    private func createWeekly(_ database: AppDatabase, sources: [BoardSource], manual: [String], memberId: String) throws -> String {
        let weekly = try board(id: "weekly", timeframe: .weekly, start: weekStart, end: weekEnd)
        try database.saveWizardBoard(
            board: weekly, boardTasks: [placement(boardId: "weekly", taskId: memberId)], pendingTasks: [],
            isUpdate: false, sources: sources, manualTaskIds: manual, now: AppDatabase.currentTimestamp()
        )
        return "weekly"
    }

    private func createDailyPulling(_ database: AppDatabase, weeklyId: String, memberId: String) throws -> String {
        let daily = try board(id: "daily", timeframe: .daily, start: dayStart, end: dayEnd)
        try database.saveWizardBoard(
            board: daily, boardTasks: [placement(boardId: "daily", taskId: memberId)], pendingTasks: [],
            isUpdate: false,
            sources: [BoardSource(sourceId: weeklyId, kind: .board)],
            manualTaskIds: [], now: AppDatabase.currentTimestamp()
        )
        return "daily"
    }

    private func weeklyCell(_ database: AppDatabase, weeklyId: String) throws -> (cell: DerivationPass.CellState?, completedTasks: Int, board: Board, placedTask: Task?) {
        try database.read { db in
            let b = try XCTUnwrap(try Board.fetchOne(db, key: weeklyId))
            let bts = try BoardTask.filter(Column("boardId") == weeklyId && Column("isDeleted") == false).fetchAll(db)
            var taskById: [String: Task] = [:]
            for t in try Task.fetchAll(db) { taskById[t.id] = t }
            let built = DerivationPass.computeBoardGrid(
                board: b, boardTasksOnBoard: bts, childrenByCompound: [:], taskById: taskById,
                allBoards: try Board.fetchAll(db),
                windowContext: try AppDatabase.buildWindowContext(db: db)
            )
            return (built.cells.first, built.completedTasks, b, bts.first.flatMap { taskById[$0.taskId] })
        }
    }

    private func completeDaily(_ database: AppDatabase, dailyId: String) throws {
        let dId = BoardSources.derivedTaskId(boardId: dailyId, rootTaskId: rootId)
        let d = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: dId) },
                              "precondition: the daily's member is a distinct minted row")
        XCTAssertEqual(d.sharedCounterId, rootId)
        XCTAssertEqual(d.maxCount, 3, "precondition: ceil(20 × 1 / 7)")
        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 3)
        XCTAssertEqual(try database.read { try Task.fetchOne($0, key: dId) }?.isCompleted, true)
        XCTAssertEqual(try database.fetchBoard(id: dailyId)?.completedTasks, 1)
    }

    func test_variantA0_weeklyHandAddedRoot_noHistory() throws {
        let database = try makeDb()
        try seedRoot(database, goal: 20, history: 0)
        let weeklyId = try createWeekly(database, sources: [], manual: [rootId], memberId: rootId)
        let dailyId = try createDailyPulling(database, weeklyId: weeklyId, memberId: rootId)
        try completeDaily(database, dailyId: dailyId)
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.cell?.isCompleted, false)
        XCTAssertEqual(w.completedTasks, 0)
        XCTAssertEqual(w.board.completedTasks, 0)
    }

    func test_variantA1_weeklyHandAddedRoot_lifetimeHistoryPastGoal() throws {
        let database = try makeDb()
        try seedRoot(database, goal: 20, history: 25)
        let weeklyId = try createWeekly(database, sources: [], manual: [rootId], memberId: rootId)
        let dailyId = try createDailyPulling(database, weeklyId: weeklyId, memberId: rootId)
        try completeDaily(database, dailyId: dailyId)
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.cell?.isCompleted, false)
        XCTAssertEqual(w.completedTasks, 0)
        XCTAssertEqual(w.board.completedTasks, 0)
    }

    private func variantB(history: Int) throws {
        let database = try makeDb()
        try seedRoot(database, goal: 80, history: history)
        let monthly = try board(
            id: monthlyId, timeframe: .monthly,
            start: wizardLocalISOString(today.addingTimeInterval(-10 * 86_400)),
            end: wizardLocalISOString(today.addingTimeInterval(20 * 86_400))
        )
        try database.write { db in
            try monthly.save(db)
            try self.placement(boardId: self.monthlyId, taskId: self.rootId).save(db)
        }
        let weeklyId = try createWeekly(
            database,
            sources: [BoardSource(sourceId: monthlyId, kind: .board, min: 0, max: nil,
                                  excludedTaskIds: [], filter: .all,
                                  memberRules: [rootId: BoardSourceMemberRule(target: 20)])],
            manual: [], memberId: rootId
        )
        let wId = BoardSources.derivedTaskId(boardId: weeklyId, rootTaskId: rootId)
        let wRow = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: wId) })
        XCTAssertEqual(wRow.maxCount, 20)
        XCTAssertFalse(wRow.isCompleted)

        let dailyId = try createDailyPulling(database, weeklyId: weeklyId, memberId: wId)
        try completeDaily(database, dailyId: dailyId)
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.placedTask?.id, wId)
        XCTAssertEqual(w.placedTask?.isCompleted, false)
        XCTAssertEqual(w.cell?.isCompleted, false)
        XCTAssertEqual(w.board.completedTasks, 0)
    }

    func test_variantB_weeklyDerivedMember_noHistory() throws { try variantB(history: 0) }
    func test_variantB_weeklyDerivedMember_withHistory() throws { try variantB(history: 25) }

    // MARK: - THE REPRODUCTION — the pulled weekly's window has ENDED

    /// The daily pulls a weekly whose window ENDED but which is still ACTIVE
    /// and unsealed — a designed flow (`isEligibleSourceBoard` offers a
    /// closed-window ACTIVE board for the lookback; the backstop seal is 42h
    /// after a weekly's end, applied lazily on app-open). 17 of 20 were logged
    /// inside the weekly's own window (goal NOT met); today's daily log of 3
    /// completes it, because the weekly has no window END: a ROOT square sums
    /// events over `[startDate, ∞)`, a window-stamped DERIVED square latches
    /// from `currentCount − baseline` in `propagateIncrement`.
    ///
    /// Both variants are GREEN regression pins:
    /// - DERIVED square: the kernel resolves a window-stamped row from its
    ///   root's events inside `[startDate, endDate]`, and propagation freezes
    ///   at the window end.
    /// - ROOT square: the 2026-09-24 amendment of WC Decision 1 (owner chose
    ///   option C) end-bounds a board's root squares at `[startDate,
    ///   endDate]`, so today's daily log no longer completes the ended weekly.
    ///   (Was `XCTExpectFailure` while the decision was open.)
    private func pastWeekly(_ database: AppDatabase, derived: Bool) throws -> (weeklyId: String, weeklyTaskId: String) {
        let start = today.addingTimeInterval(-9 * 86_400)
        let pastStart = wizardLocalISOString(start)
        let pastEnd = wizardLocalISOString(start.addingTimeInterval(7 * 86_400 - 0.001))
        let inWindow = wizardLocalISOString(start.addingTimeInterval(2 * 86_400 + 9 * 3_600))
        try database.write { db in
            try Task(
                id: self.rootId, userId: self.userId, title: "Read", type: .counting,
                action: "Read", unit: "pages", maxCount: derived ? 80 : 20,
                totalCompletions: 0, totalInstances: 0,
                isCompleted: false, currentCount: 17,
                createdAt: self.seedNow, updatedAt: self.seedNow, version: 1, isDeleted: false
            ).save(db)
            try TaskEvent(
                id: "in-window-17", userId: self.userId, taskId: self.rootId, kind: .increment, delta: 17,
                occurredAt: inWindow, boardId: nil,
                createdAt: inWindow, updatedAt: inWindow, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            ).save(db)
        }
        let weekly = try board(id: "weekly", timeframe: .weekly, start: pastStart, end: pastEnd)
        var sources: [BoardSource] = []
        var manual: [String] = [rootId]
        if derived {
            let monthly = try board(
                id: monthlyId, timeframe: .monthly,
                start: wizardLocalISOString(today.addingTimeInterval(-20 * 86_400)),
                end: wizardLocalISOString(today.addingTimeInterval(10 * 86_400))
            )
            try database.write { db in
                try monthly.save(db)
                try self.placement(boardId: self.monthlyId, taskId: self.rootId).save(db)
            }
            sources = [BoardSource(sourceId: monthlyId, kind: .board, min: 0, max: nil,
                                   excludedTaskIds: [], filter: .all,
                                   memberRules: [rootId: BoardSourceMemberRule(target: 20)])]
            manual = []
        }
        try database.saveWizardBoard(
            board: weekly, boardTasks: [placement(boardId: "weekly", taskId: rootId)], pendingTasks: [],
            isUpdate: false, sources: sources, manualTaskIds: manual, now: AppDatabase.currentTimestamp()
        )
        let weeklyTaskId = derived ? BoardSources.derivedTaskId(boardId: "weekly", rootTaskId: rootId) : rootId
        let before = try weeklyCell(database, weeklyId: "weekly")
        XCTAssertEqual(before.placedTask?.id, weeklyTaskId)
        XCTAssertEqual(before.cell?.isCompleted, false, "precondition: 17 of 20 — not met in its own window")
        return ("weekly", weeklyTaskId)
    }

    private func logTodayOnDaily(_ database: AppDatabase, weeklyId: String, memberId: String) throws {
        let dailyId = try createDailyPulling(database, weeklyId: weeklyId, memberId: memberId)
        let dId = BoardSources.derivedTaskId(boardId: dailyId, rootTaskId: rootId)
        let d = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: dId) })
        XCTAssertEqual(d.maxCount, 3, "a distinct, pro-rated daily row")
        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 3)
        XCTAssertEqual(try database.read { try Task.fetchOne($0, key: dId) }?.isCompleted, true)
    }

    func test_pastWeeklyRootSquare_staysIncompleteAfterPostWindowDailyLog() throws {
        let database = try makeDb()
        let (weeklyId, weeklyTaskId) = try pastWeekly(database, derived: false)
        try logTodayOnDaily(database, weeklyId: weeklyId, memberId: weeklyTaskId)
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.cell?.isCompleted, false)
        XCTAssertEqual(w.board.completedTasks, 0)
    }

    /// Was `XCTExpectFailure` on dev (propagateIncrement latched every linked
    /// row, unbounded). Now a regression pin: the ended row is frozen (no latch
    /// write) and the kernel reads the root's in-window sum (17 < 20).
    func test_pastWeeklyDerivedSquare_staysIncompleteAfterPostWindowDailyLog() throws {
        let database = try makeDb()
        let (weeklyId, weeklyTaskId) = try pastWeekly(database, derived: true)
        try logTodayOnDaily(database, weeklyId: weeklyId, memberId: weeklyTaskId)
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.placedTask?.isCompleted, false)
        XCTAssertEqual(w.cell?.isCompleted, false)
        XCTAssertEqual(w.board.completedTasks, 0)

        // Pin the KERNEL too, not just the freeze: a stale latch (a pre-freeze
        // client's write, synced in) must not green the cell.
        try database.write { db in
            try db.execute(sql: "UPDATE tasks SET isCompleted = 1 WHERE id = ?", arguments: [weeklyTaskId])
        }
        let stale = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(stale.placedTask?.isCompleted, true, "precondition: the stale latch is set")
        XCTAssertEqual(stale.cell?.isCompleted, false)
        XCTAssertEqual(stale.completedTasks, 0)
    }

    // MARK: - Late shared-counter logs (2026-09-24 amendment, decision C2)
    //
    // Twins of the web `lateLogWindowEnd.test.ts` shared-counter cases. The
    // play surface passes its board id; a log made on an ended-but-unsealed
    // board is stamped at that board's `endDate`. Real clock — the ops stamp
    // `currentTimestamp()`.

    private func rootEvents(_ database: AppDatabase) throws -> [TaskEvent] {
        try database.read { db in
            try TaskEvent.filter(Column("taskId") == self.rootId && Column("isDeleted") == false).fetchAll(db)
        }
    }

    private func utcStamp(_ localIso: String) -> String {
        DateFormatting.utcISOString(DateFormatting.parseISO(localIso)!)
    }

    func test_sharedCounterLog_withEndedBoardId_stampsAtEndDate_withoutBoardId_stampsNow() throws {
        let database = try makeDb()
        let (weeklyId, _) = try pastWeekly(database, derived: false)
        let weeklyEnd = try XCTUnwrap(try database.fetchBoard(id: weeklyId)?.endDate)

        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 3, boardId: weeklyId)
        let late = try XCTUnwrap(try rootEvents(database).first { $0.delta == 3 })
        XCTAssertEqual(late.occurredAt, utcStamp(weeklyEnd), "late log lands at the ended board's endDate")
        XCTAssertNil(late.boardId, "provenance unchanged — only occurredAt is clamped")
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.cell?.isCompleted, true, "17 + 3 inside the weekly's own window")
        XCTAssertEqual(w.board.completedTasks, 1)

        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 1)
        let plain = try XCTUnwrap(try rootEvents(database).first { $0.delta == 1 })
        XCTAssertEqual(plain.occurredAt, plain.createdAt, "no board → stamped now")

        _ = try database.decrementSharedCounter(sourceTaskId: rootId, by: 2, boardId: weeklyId)
        let dec = try XCTUnwrap(try rootEvents(database).first { $0.delta == -2 })
        XCTAssertEqual(dec.occurredAt, utcStamp(weeklyEnd), "decrement is clamped the same way")
    }

    func test_sharedCounterLog_withOpenBoardId_stampsNow() throws {
        let database = try makeDb()
        try seedRoot(database, goal: 20, history: 0)
        let daily = try board(id: "open-daily", timeframe: .daily, start: dayStart, end: dayEnd)
        try database.write { db in
            try daily.save(db)
            try self.placement(boardId: "open-daily", taskId: self.rootId).save(db)
        }

        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 2, boardId: "open-daily")

        let e = try XCTUnwrap(try rootEvents(database).first)
        XCTAssertEqual(e.occurredAt, e.createdAt, "an open board's window contains now")
    }

    /// A late log stamped at the ended weekly's `endDate` falls inside its
    /// FROZEN window-stamped derived row: the row is never written, but the
    /// weekly's stored stats must re-derive (cascade only).
    func test_lateSharedCounterLog_reachesFrozenDerivedRow_cascadeOnly() throws {
        let database = try makeDb()
        let (weeklyId, weeklyTaskId) = try pastWeekly(database, derived: true)
        let rowBefore = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: weeklyTaskId) })

        _ = try database.incrementSharedCounter(sourceTaskId: rootId, by: 3, boardId: weeklyId)

        let rowAfter = try XCTUnwrap(try database.read { try Task.fetchOne($0, key: weeklyTaskId) })
        XCTAssertEqual(rowAfter.version, rowBefore.version, "frozen row is never written")
        XCTAssertFalse(rowAfter.isCompleted, "no latch write on a frozen row")
        let w = try weeklyCell(database, weeklyId: weeklyId)
        XCTAssertEqual(w.cell?.isCompleted, true, "kernel: 17 + 3 in the row's window")
        XCTAssertEqual(try database.fetchBoard(id: weeklyId)?.completedTasks, 1, "stored stats re-derived")
    }
}

