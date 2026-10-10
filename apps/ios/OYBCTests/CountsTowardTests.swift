import XCTest
import GRDB
@testable import OYBC

/// "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3;
/// D10: one credit per completion occurrence).
/// Twin of web `db/operations/__tests__/countsToward.test.ts`.
@MainActor
final class CountsTowardTests: XCTestCase {

    private let user = "user-1"
    private let t0 = "2026-01-01T00:00:00.000Z"
    private let root = "00000000-0000-4000-8000-0000000000a1"   // "Read 12 books"
    private let copy = "00000000-0000-4000-8000-0000000000a2"   // weekly copy, goal 1
    private let simple = "00000000-0000-4000-8000-0000000000b1" // "Read Dune"
    private let run = "00000000-0000-4000-8000-0000000000b2"    // "Run 2 km" — a plain counting contributor
    private let childA = "00000000-0000-4000-8000-0000000000c1"
    private let childB = "00000000-0000-4000-8000-0000000000c2"
    private let box = "00000000-0000-4000-8000-0000000000d1"
    private let oct = "00000000-0000-4000-8000-0000000000e1"
    private let week = "00000000-0000-4000-8000-0000000000e2"
    private let closed = "00000000-0000-4000-8000-0000000000e3"
    private let w1 = "00000000-0000-4000-8000-0000000000e4"     // the repeating weekly board, window 1
    private let w2 = "00000000-0000-4000-8000-0000000000e5"     // … window 2
    private let day = "00000000-0000-4000-8000-0000000000e6"
    private let octStart = "2026-10-01T00:00:00.000Z"
    private let octEnd = "2026-10-31T23:59:59.999Z"
    private let weekStart = "2026-10-12T00:00:00.000Z"
    private let weekEnd = "2026-10-18T23:59:59.999Z"
    private let w1Start = "2026-10-05T00:00:00.000Z"
    private let w1End = "2026-10-11T23:59:59.999Z"
    private let dayStart = "2026-10-14T00:00:00.000Z"
    private let dayEnd = "2026-10-14T23:59:59.999Z"
    private let inW1 = "2026-10-07T09:00:00.000Z"
    private let now = "2026-10-14T09:00:00.000Z"

    // MARK: - Fixtures

    private func task(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil, sharedCounterId: String? = nil,
        isCounter: Bool = false, operatorType: OperatorType? = nil, countKind: CountKind? = nil,
        countsTowardCounterId: String? = nil, countsTowardAmount: Int? = nil
    ) -> Task {
        Task(
            id: id, userId: user, title: id, type: type,
            action: type == .counting ? "Read" : nil, unit: type == .counting ? "books" : nil,
            maxCount: maxCount, operatorType: operatorType, totalCompletions: 0, totalInstances: 0,
            currentCount: type == .counting ? 0 : nil, createdAt: t0, updatedAt: t0, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: sharedCounterId == nil ? nil : 0,
            isCounter: isCounter, countKind: countKind,
            countsTowardCounterId: countsTowardCounterId, countsTowardAmount: countsTowardAmount
        )
    }

    private func board(_ id: String, _ start: String, _ end: String, sealedAt: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": user, "name": id, "status": BoardStatus.active.rawValue,
            "boardSize": 3, "timeframe": Timeframe.custom.rawValue, "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": t0, "updatedAt": t0, "version": 1, "isDeleted": false,
        ]
        if let sealedAt {
            dict["sealedAt"] = sealedAt
            dict["sealedCompletedCells"] = "[]"
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func placement(_ id: String, _ boardId: String, _ taskId: String, col: Int = 0) -> BoardTask {
        BoardTask(id: id, boardId: boardId, taskId: taskId, row: 0, col: col, isCenter: false,
                  createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1)
    }

    private func link(_ id: String, _ parent: String, _ child: String, _ index: Int) -> CompoundChild {
        CompoundChild(id: id, compoundTaskId: parent, childTaskId: child, childIndex: index,
                      createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil)
    }

    private func completion(_ id: String, _ taskId: String, _ at: String) -> TaskEvent {
        TaskEvent(id: id, userId: user, taskId: taskId, kind: .completion, delta: nil, occurredAt: at, boardId: nil,
                  createdAt: at, updatedAt: at, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil)
    }

    private func seedUser(_ db: AppDatabase) throws {
        try db.saveUser(User(
            id: user, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: t0, updatedAt: t0, lastSyncedAt: nil, version: 1
        ))
    }

    /// Root counter + its weekly copy (goal 1) on the week board + "Read Dune" on the October board.
    private func seed(_ db: AppDatabase, amount: Int? = nil, flagged: Bool = true) throws {
        try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(copy, type: .counting, maxCount: 1, sharedCounterId: root).save(d)
            try task(simple, countsTowardCounterId: flagged ? root : nil, countsTowardAmount: amount).save(d)
            try board(oct, octStart, octEnd).save(d)
            try board(week, weekStart, weekEnd).save(d)
            try placement("bt-simple", oct, simple).save(d)
            try placement("bt-copy", week, copy).save(d)
        }
    }

    /// Root counter + a contributor on two windows of a repeating weekly board.
    private func seedWeeks(_ db: AppDatabase, contributor: Task? = nil) throws {
        let c = contributor ?? task(simple, countsTowardCounterId: root)
        try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try c.save(d)
            try board(w1, w1Start, w1End).save(d)
            try board(w2, weekStart, weekEnd).save(d)
            try placement("bt-w1", w1, c.id).save(d)
            try placement("bt-w2", w2, c.id).save(d)
        }
    }

    private func runTask() -> Task {
        task(run, type: .counting, maxCount: 2, countsTowardCounterId: root)
    }

    private func seedBox(_ db: AppDatabase, op: OperatorType = .and) throws {
        try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(copy, type: .counting, maxCount: 1, sharedCounterId: root).save(d)
            try task(box, type: .compound, operatorType: op, countsTowardCounterId: root).save(d)
            try task(childA).save(d)
            try task(childB).save(d)
            try link("l-a", box, childA, 0).save(d)
            try link("l-b", box, childB, 1).save(d)
            try board(oct, octStart, octEnd).save(d)
            try board(week, weekStart, weekEnd).save(d)
            try placement("bt-box", oct, box).save(d)
            try placement("bt-copy", week, copy).save(d)
        }
    }

    @discardableResult
    private func complete(
        _ db: AppDatabase, _ boardId: String, _ boardTaskId: String, _ taskId: String, _ done: Bool = true, at: String? = nil
    ) throws -> [String: AppDatabase.CascadeBoardResult] {
        let b = try XCTUnwrap(db.fetchBoard(id: boardId))
        let bt = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: boardTaskId) })
        return try db.completeTaskOrchestrated(board: b, taskId: taskId, intent: .setCompleted(done), boardTask: bt, now: at ?? now)
    }

    /// A counting square tap: the desired windowed count, stamped at `at`.
    private func count(_ db: AppDatabase, _ boardId: String, _ boardTaskId: String, _ taskId: String, _ desired: CountValue, at: String) throws {
        let b = try XCTUnwrap(db.fetchBoard(id: boardId))
        let bt = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: boardTaskId) })
        _ = try db.completeTaskOrchestrated(board: b, taskId: taskId, intent: .setWindowedCount(desired), boardTask: bt, now: at)
    }

    /// A library-style completion: event + the cascade, one transaction.
    private func libraryComplete(_ db: AppDatabase, _ taskId: String, at: String) throws {
        try db.write { d in
            try AppDatabase.appendCompletionEvent(db: d, taskId: taskId, boardId: nil, now: at, occurredAt: at)
            try AppDatabase.runBoardCascadeForTasks(db: d, changedTaskIds: [taskId], now: at)
        }
    }

    private func sortedByInstant(_ rows: [TaskEvent]) -> [TaskEvent] {
        rows.sorted { a, b in
            let (ma, mb) = (DateFormatting.parseISO(a.occurredAt)!, DateFormatting.parseISO(b.occurredAt)!)
            if ma != mb { return ma < mb }
            return a.id < b.id
        }
    }

    /// Every counts-toward credit stored on the root (any state), by instant.
    private func storedCredits(_ db: AppDatabase) throws -> [TaskEvent] {
        sortedByInstant(try db.read { try TaskEvent.filter(Column("taskId") == self.root && Column("kind") == "increment").fetchAll($0) })
    }

    /// The LIVE credits on the root, by instant.
    private func liveCredits(_ db: AppDatabase) throws -> [TaskEvent] {
        try storedCredits(db).filter { !$0.isDeleted }
    }

    /// The contributor's own live events, by instant.
    private func liveEvents(_ db: AppDatabase, of taskId: String) throws -> [TaskEvent] {
        sortedByInstant(try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) })
    }

    private func creditId(_ contributor: String, _ occurrence: CountsToward.Occurrence) -> String {
        CountsToward.eventId(contributorId: contributor, occurrence: occurrence)
    }

    /// An event-keyed credit id — the contributor is not part of the name.
    private func eventCredit(_ eventId: String) -> String { creditId("-", .event(eventId: eventId)) }

    private func fetch(_ db: AppDatabase, _ id: String) throws -> Task { try XCTUnwrap(db.read { try Task.fetchOne($0, key: id) }) }
    private func completedTasks(_ db: AppDatabase, _ boardId: String) throws -> Int { try XCTUnwrap(db.fetchBoard(id: boardId)).completedTasks }
    private func queued(_ db: AppDatabase, _ type: String) throws -> [String] {
        try db.read { try SyncQueueItem.filter(Column("entityType") == type).fetchAll($0).map(\.entityId) }
    }

    // MARK: - A Simple task

    func test_simpleCompletes_plusOneOnRoot_keyedByTheCompletion_weeklyCopyCountsInWindow() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)

        let done = try XCTUnwrap(liveEvents(db, of: simple).first)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.count, 1)
        let ev = try XCTUnwrap(credits.first)
        XCTAssertEqual(ev.id, eventCredit(done.id))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(ev.kind, .increment)
        XCTAssertEqual(ev.delta, 1)
        XCTAssertEqual(ev.occurredAt, now)
        XCTAssertEqual(ev.version, 1)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        XCTAssertEqual(try completedTasks(db, week), 1)
        XCTAssertTrue(try queued(db, "taskEvents").contains(ev.id))
    }

    func test_uncomplete_tombstonesTheCredit_copyDropsBack() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        try complete(db, oct, "bt-simple", simple, false)

        let stored = try storedCredits(db)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.isDeleted, true)
        XCTAssertEqual(stored.first?.version, 2)
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
        XCTAssertEqual(try completedTasks(db, week), 0)
    }

    func test_amountThree() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, amount: 3)
        try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(try liveCredits(db).first?.delta, 3)
        XCTAssertEqual(try fetch(db, root).currentCount, 3)
    }

    func test_copyOnTheSameBoard_isReadInTheSamePass_itsBingoIsReported() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        let done = "00000000-0000-4000-8000-0000000000b9"
        try db.write { d in
            try task(done).save(d)
            try completion("00000000-0000-4000-8000-0000000000b8", done, "2026-10-02T10:00:00.000Z").save(d)
            try placement("bt-copy-oct", oct, copy, col: 1).save(d)
            try placement("bt-done", oct, done, col: 2).save(d)
        }
        let results = try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(results[oct]?.update.newBingos.count, 1)
        XCTAssertEqual(try completedTasks(db, oct), 3)
    }

    func test_replayWithNoStateChange_writesNothing() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        let queueBefore = try db.read { try SyncQueueItem.fetchCount($0) }
        let before = try storedCredits(db)
        let rootVersionBefore = try fetch(db, root).version

        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.simple], now: "2026-10-14T10:00:00.000Z") }

        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?.version, 1)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, queueBefore)
        let after = try storedCredits(db)
        XCTAssertEqual(after.map(\.version), before.map(\.version))
        XCTAssertEqual(after.map(\.updatedAt), before.map(\.updatedAt))
        XCTAssertEqual(after.map(\.occurredAt), before.map(\.occurredAt))
        XCTAssertEqual(try fetch(db, root).version, rootVersionBefore)
    }

    // MARK: - One credit per completion occurrence (D10)

    func test_sameSimpleTaskOnTwoWeeklyWindows_creditsEachWindow_stampedAtEachCompletion() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db)
        try complete(db, w1, "bt-w1", simple, at: inW1)
        try complete(db, w2, "bt-w2", simple)

        let events = try liveEvents(db, of: simple)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.occurredAt), [inW1, now])
        XCTAssertEqual(credits.map(\.id), events.map { eventCredit($0.id) })
        XCTAssertNotEqual(credits[0].id, credits[1].id)
        XCTAssertEqual(try fetch(db, root).currentCount, 2)
    }

    func test_uncompletingWeekTwo_tombstonesOnlyWeekTwosCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db)
        try complete(db, w1, "bt-w1", simple, at: inW1)
        try complete(db, w2, "bt-w2", simple)
        try complete(db, w2, "bt-w2", simple, false)

        let stored = try storedCredits(db)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].occurredAt, inW1)
        XCTAssertFalse(stored[0].isDeleted)
        XCTAssertEqual(stored[0].version, 1)
        XCTAssertEqual(stored[1].occurredAt, now)
        XCTAssertTrue(stored[1].isDeleted)
        XCTAssertEqual(stored[1].version, 2)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }

    func test_sameSimpleTaskOnDailyAndMonthly_completedOnce_isOneCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple, countsTowardCounterId: root).save(d)
            try board(day, dayStart, dayEnd).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-day", day, simple).save(d)
            try placement("bt-oct", oct, simple).save(d)
        }
        try complete(db, day, "bt-day", simple)

        XCTAssertEqual(try liveCredits(db).count, 1)
        XCTAssertEqual(try completedTasks(db, oct), 1)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }

    func test_plainCountingReachesItsGoalInTwoWindows_creditsEach_keyedByTheCrossingIncrement() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db, contributor: runTask())
        try count(db, w1, "bt-w1", run, 1, at: "2026-10-06T09:00:00.000Z")
        try count(db, w1, "bt-w1", run, 2, at: inW1)
        XCTAssertEqual(try liveCredits(db).count, 1)
        try count(db, w2, "bt-w2", run, 1, at: "2026-10-13T09:00:00.000Z")
        try count(db, w2, "bt-w2", run, 2, at: now)

        let increments = try liveEvents(db, of: run)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.occurredAt), [inW1, now])
        XCTAssertEqual(credits.map(\.id), [eventCredit(increments[1].id), eventCredit(increments[3].id)])
        XCTAssertEqual(try fetch(db, root).currentCount, 2)
    }

    func test_sameCrossingIncrementInsideTwoOverlappingWindows_isOneCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try runTask().save(d)
            try board(week, weekStart, weekEnd).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-run-week", week, run).save(d)
            try placement("bt-run-oct", oct, run).save(d)
        }
        try count(db, week, "bt-run-week", run, 1, at: "2026-10-13T09:00:00.000Z")
        try count(db, week, "bt-run-week", run, 2, at: now)

        let increments = try liveEvents(db, of: run)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.id), [eventCredit(increments[1].id)])
        XCTAssertEqual(credits.first?.occurredAt, now)
        XCTAssertEqual(try completedTasks(db, oct), 1)
    }

    func test_compoundCreditsEachCompleteWindow_andAnUnplacedOneCreditsItsLifetime() throws {
        let life = "00000000-0000-4000-8000-0000000000d2"
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(box, type: .compound, operatorType: .and, countsTowardCounterId: root).save(d)
            try task(life, type: .compound, operatorType: .or, countsTowardCounterId: root).save(d)
            try task(childA).save(d)
            try task(childB).save(d)
            try link("l-a", box, childA, 0).save(d)
            try link("l-b", box, childB, 1).save(d)
            try link("l-life", life, childA, 0).save(d)
            try board(w1, w1Start, w1End).save(d)
            try board(w2, weekStart, weekEnd).save(d)
            try placement("bt-w1", w1, box).save(d)
            try placement("bt-w2", w2, box).save(d)
        }
        try libraryComplete(db, childA, at: "2026-10-06T09:00:00.000Z")
        try libraryComplete(db, childB, at: inW1)
        try libraryComplete(db, childA, at: "2026-10-13T09:00:00.000Z")
        try libraryComplete(db, childB, at: "2026-10-15T09:00:00.000Z")

        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.id), [
            creditId(life, .lifetime),
            creditId(box, .window(startDate: w1Start)),
            creditId(box, .window(startDate: weekStart)),
        ])
        XCTAssertEqual(credits.map(\.occurredAt), ["2026-10-06T09:00:00.000Z", inW1, "2026-10-15T09:00:00.000Z"])
        XCTAssertEqual(try fetch(db, root).currentCount, 3)
    }

    func test_boardScopedFork_carriesTheCompletionOverAsTheSameCredit_oneLiveCreditBeforeAndAfter() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try db.write { try placement("bt-other", week, simple, col: 2).save($0) }
        try complete(db, oct, "bt-simple", simple)
        let before = try liveCredits(db)
        XCTAssertEqual(before.count, 1)

        let plan = try db.read { d in
            BoardScopedFork.plan(
                task: try XCTUnwrap(Task.fetchOne(d, key: simple)), board: board(oct, octStart, octEnd), editedType: .normal,
                placements: try BoardTask.fetchAll(d), boards: try Board.fetchAll(d),
                compoundChildren: [], events: try TaskEvent.fetchAll(d), now: now
            )
        }
        guard case let .fork(fork, eventCopies, _, _, _) = plan else { return XCTFail("expected a fork") }
        XCTAssertEqual(fork.countsTowardCounterId, root)
        XCTAssertEqual(eventCopies.count, 1)
        try db.write { d in
            try fork.save(d)
            for e in eventCopies { try e.save(d) }
            try d.execute(sql: "UPDATE board_tasks SET taskId = ? WHERE id = 'bt-simple'", arguments: [fork.id])
            try AppDatabase.runBoardCascadeForTasks(db: d, changedTaskIds: [self.simple, fork.id], now: self.now)
        }

        let after = try storedCredits(db)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.version), before.map(\.version))
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        // A replay from the fork's side changes nothing.
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [fork.id], now: self.now) }
        XCTAssertEqual(try storedCredits(db).map(\.version), before.map(\.version))
    }

    func test_clearingTheFlag_tombstonesEveryLiveCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db)
        try complete(db, w1, "bt-w1", simple, at: inW1)
        try complete(db, w2, "bt-w2", simple)
        XCTAssertEqual(try liveCredits(db).count, 2)

        try db.setCountsToward(taskId: simple, counterId: nil)

        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try storedCredits(db).map(\.version), [2, 2])
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
    }

    func test_replayAfterSeveralOccurrences_writesNothing() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db)
        try complete(db, w1, "bt-w1", simple, at: inW1)
        try complete(db, w2, "bt-w2", simple)
        let before = try storedCredits(db)
        let queueBefore = try db.read { try SyncQueueItem.fetchCount($0) }

        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.simple], now: "2026-10-14T10:00:00.000Z") }
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.root], now: "2026-10-14T10:00:00.000Z") }

        let after = try storedCredits(db)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.version), before.map(\.version))
        XCTAssertEqual(after.map(\.updatedAt), before.map(\.updatedAt))
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, queueBefore)
    }

    // MARK: - A Compound container

    func test_compoundCountsOnceBothSubTasksAreDone_keyedByTheOctoberWindow_stampedAtTheLaterOne() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        try libraryComplete(db, childA, at: "2026-10-13T08:00:00.000Z")
        XCTAssertEqual(try liveCredits(db).count, 0)
        try libraryComplete(db, childB, at: "2026-10-15T20:00:00.000Z")

        let credits = try liveCredits(db)
        XCTAssertEqual(credits.count, 1)
        let ev = try XCTUnwrap(credits.first)
        XCTAssertEqual(ev.id, creditId(box, .window(startDate: octStart)))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(ev.delta, 1)
        XCTAssertEqual(ev.occurredAt, "2026-10-15T20:00:00.000Z")
        XCTAssertEqual(try completedTasks(db, week), 1)
    }

    func test_lateLogOnClosedBoard_completesTheContainerThere_thatWindowsCreditStampedAtEndDate() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        let closedStart = "2026-10-01T00:00:00.000Z"
        let closedEnd = "2026-10-07T23:59:59.999Z"
        try db.write { d in
            try board(closed, closedStart, closedEnd, sealedAt: "2026-10-08T00:00:01.000Z").save(d)
            try placement("bt-closed", closed, box, col: 1).save(d)
            try completion("ev-a", childA, "2026-10-03T10:00:00.000Z").save(d)
        }
        try db.lateLogCompoundParts(boardId: closed, compoundTaskId: box, childTaskIds: [childB], now: now)

        let ev = try XCTUnwrap(liveCredits(db).first { $0.id == creditId(box, .window(startDate: closedStart)) })
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(DateFormatting.parseISO(ev.occurredAt), DateFormatting.parseISO(closedEnd))
    }

    func test_deletingTheSubTaskTheContainerNeeded_reDerivesIt() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db, op: .or)
        try libraryComplete(db, childA, at: now)
        XCTAssertEqual(try liveCredits(db).count, 1)
        try db.deleteTaskWithCascade(taskId: childA)
        XCTAssertEqual(try liveCredits(db).count, 0)
    }

    func test_emptyContainer_allowedOnlyWithTheFlag_andEvaluatesIncomplete() throws {
        let patch = TaskEditPatch(title: "A book")
        XCTAssertEqual(patch.validate(type: .compound), "A compound task needs a sub-task.")
        XCTAssertNil(patch.validate(type: .compound, countsToward: true))

        let flagged = task(box, type: .compound, operatorType: .and, countsTowardCounterId: root)
        XCTAssertFalse(CompoundEvaluation.evaluate(compound: flagged, childrenByCompound: [:], taskById: [box: flagged]))
        let plain = task(box, type: .compound, operatorType: .and)
        XCTAssertTrue(CompoundEvaluation.evaluate(compound: plain, childrenByCompound: [:], taskById: [box: plain]))
    }

    // MARK: - Deletion and guards

    func test_deletingAContributor_tombstonesItsCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        try db.deleteTaskWithCascade(taskId: simple)
        XCTAssertEqual(try storedCredits(db).map(\.isDeleted), [true])
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
    }

    func test_deletePreview_namesTheCounter() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        XCTAssertEqual(try db.computeTaskDeletionImpact(taskId: simple).countsTowardCounter?.id, root)
        XCTAssertNil(try db.computeTaskDeletionImpact(taskId: copy).countsTowardCounter)
    }

    func test_deletingTheCounter_unflagsContributors_creditsStayWithTheRoot() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        let versionBefore = try fetch(db, simple).version
        try db.write { try $0.execute(sql: "DELETE FROM sync_queue") }

        try db.deleteCounterWithUnlink(sourceId: root, now: now)

        let after = try fetch(db, simple)
        XCTAssertNil(after.countsTowardCounterId)
        XCTAssertEqual(after.version, versionBefore + 1)
        XCTAssertTrue(try queued(db, "tasks").contains(simple))
        XCTAssertEqual(try storedCredits(db).map(\.isDeleted), [false])
    }

    func test_kindSwitch_refusesToLeaveDiscreteWhileContributorsExist() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        XCTAssertThrowsError(try db.switchCounterKind(rootTaskId: root, to: .continuous)) { error in
            XCTAssertEqual(error as? CountKindSwitchError, .hasContributors)
        }
        XCTAssertNil(try fetch(db, root).countKind)
        XCTAssertEqual(CountKindSwitchError.countsTowardMessage, "A counter other tasks count toward stays Discrete.")
    }

    func test_setCountsToward_validates_mintsAtOnceForADoneTask_clearTombstones() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, flagged: false)
        let km = "00000000-0000-4000-8000-0000000000f2"
        let done = completion("00000000-0000-4000-8000-0000000000f1", simple, "2026-10-10T10:00:00.000Z")
        try db.write { d in
            try done.save(d)
            try task(km, type: .counting, maxCount: 5, isCounter: true, countKind: .continuous).save(d)
        }
        XCTAssertThrowsError(try db.setCountsToward(taskId: simple, counterId: km)) {
            XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.targetNotDiscrete))
        }
        XCTAssertThrowsError(try db.setCountsToward(taskId: simple, counterId: simple)) {
            XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.selfTarget))
        }

        try db.setCountsToward(taskId: simple, counterId: root, amount: 2)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.id), [eventCredit(done.id)])
        XCTAssertEqual(credits.first?.delta, 2)
        XCTAssertEqual(credits.first?.occurredAt, "2026-10-10T10:00:00.000Z")

        try db.setCountsToward(taskId: simple, counterId: nil)
        let cleared = try fetch(db, simple)
        XCTAssertNil(cleared.countsTowardCounterId)
        XCTAssertNil(cleared.countsTowardAmount)
        XCTAssertEqual(try liveCredits(db).count, 0)
    }

    // MARK: - Pull path

    func test_secondDevice_reDerivesTheSameCredit_fromThePulledCompletion_andThePeersCopyConverges() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        let completionId = "00000000-0000-4000-8000-0000000000f9"
        let completionDoc: [String: Any] = [
            "id": completionId, "userId": user, "taskId": simple, "kind": "completion",
            "occurredAt": "2026-10-13T07:30:00.000Z", "createdAt": "2026-10-13T07:30:00.000Z",
            "updatedAt": "2026-10-13T07:30:00.000Z", "version": 1, "isDeleted": false,
        ]
        _ = try db.write { try AppDatabase.applyTaskEventsBatchTx(db: $0, userId: self.user, rawDocs: [completionDoc]) }
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.count, 1)
        let mine = try XCTUnwrap(credits.first)
        XCTAssertEqual(mine.id, eventCredit(completionId))
        XCTAssertEqual(mine.taskId, root)
        XCTAssertEqual(mine.delta, 1)
        XCTAssertEqual(mine.occurredAt, "2026-10-13T07:30:00.000Z")

        let peer: [String: Any] = [
            "id": eventCredit(completionId), "userId": user, "taskId": root,
            "kind": "increment", "delta": 1, "occurredAt": "2026-10-13T07:30:00.000Z",
            "createdAt": "2026-10-13T07:30:01.000Z", "updatedAt": "2026-10-13T07:30:01.000Z",
            "version": 1, "isDeleted": false,
        ]
        _ = try db.write { try AppDatabase.applyTaskEventsBatchTx(db: $0, userId: self.user, rawDocs: [peer]) }
        let rows = try storedCredits(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.delta, 1)
        XCTAssertEqual(rows.first?.occurredAt, "2026-10-13T07:30:00.000Z")
        XCTAssertEqual(rows.first?.isDeleted, false)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }
}
