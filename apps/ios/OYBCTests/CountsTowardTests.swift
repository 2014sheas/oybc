import XCTest
import GRDB
@testable import OYBC

/// "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3;
/// D10: one credit per completion occurrence; D11: count from
/// `countsTowardSince`, credits honour the counter's sealed windows).
/// Twin of web `db/operations/__tests__/countsToward.test.ts`.
@MainActor
final class CountsTowardTests: XCTestCase {

    private let user = "user-1"
    private let t0 = "2026-01-01T00:00:00.000Z"
    private let root = "00000000-0000-4000-8000-0000000000a1"   // "Read 12 books"
    private let root2 = "00000000-0000-4000-8000-0000000000a3"  // "Finish 5 novels"
    private let copy2 = "00000000-0000-4000-8000-0000000000a4"  // ROOT2's copy, goal 1
    private let other = "00000000-0000-4000-8000-0000000000b3"  // a second Simple contributor
    private let missing = "00000000-0000-4000-8000-00000000dead"
    private let sealedLate = "00000000-0000-4000-8000-0000000000e7"
    private let z = "00000000-0000-4000-8000-0000000000c3"
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
    private let later = "2026-10-16T09:00:00.000Z"

    // MARK: - Fixtures

    /// A flagged task carries the counter AND the D11 `since` stamp (t0 = before every event here).
    private func task(
        _ id: String, type: TaskType = .normal, maxCount: CountValue? = nil, sharedCounterId: String? = nil,
        isCounter: Bool = false, operatorType: OperatorType? = nil, countKind: CountKind? = nil,
        countsTowardCounterId: String? = nil, countsTowardAmount: Int? = nil, countsTowardSince: String? = nil,
        forkedFromTaskId: String? = nil
    ) -> Task {
        Task(
            id: id, userId: user, title: id, type: type,
            action: type == .counting ? "Read" : nil, unit: type == .counting ? "books" : nil,
            maxCount: maxCount, operatorType: operatorType, totalCompletions: 0, totalInstances: 0,
            currentCount: type == .counting ? 0 : nil, createdAt: t0, updatedAt: t0, version: 1, isDeleted: false,
            sharedCounterId: sharedCounterId, baseline: sharedCounterId == nil ? nil : 0,
            isCounter: isCounter, countKind: countKind, forkedFromTaskId: forkedFromTaskId,
            countsTowardCounterId: countsTowardCounterId, countsTowardAmount: countsTowardAmount,
            countsTowardSince: countsTowardCounterId == nil ? nil : (countsTowardSince ?? t0)
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

    /// Seed "Read Dune" on October AND the week board, complete it on October,
    /// then fork it for October (the fork copies the in-window completion).
    private func forkCompletedDune(_ db: AppDatabase) throws -> Task {
        try seed(db)
        try db.write { try placement("bt-other", week, simple, col: 2).save($0) }
        try complete(db, oct, "bt-simple", simple)
        let plan = try db.read { d in
            BoardScopedFork.plan(
                task: try XCTUnwrap(Task.fetchOne(d, key: simple)), board: board(oct, octStart, octEnd), editedType: .normal,
                placements: try BoardTask.fetchAll(d), boards: try Board.fetchAll(d),
                compoundChildren: [], events: try TaskEvent.fetchAll(d), now: now
            )
        }
        guard case let .fork(fork, eventCopies, _, _, _) = plan else { throw XCTSkip("expected a fork") }
        try db.write { d in
            try fork.save(d)
            for e in eventCopies { try e.save(d) }
            try d.execute(sql: "UPDATE board_tasks SET taskId = ? WHERE id = 'bt-simple'", arguments: [fork.id])
            try AppDatabase.runBoardCascadeForTasks(db: d, changedTaskIds: [self.simple, fork.id], now: self.now)
        }
        return fork
    }

    private func sortedByInstant(_ rows: [TaskEvent]) -> [TaskEvent] {
        rows.sorted { a, b in
            let (ma, mb) = (DateFormatting.parseISO(a.occurredAt)!, DateFormatting.parseISO(b.occurredAt)!)
            if ma != mb { return ma < mb }
            return a.id < b.id
        }
    }

    /// Every counts-toward credit stored on the root (any state), by instant.
    private func storedCredits(_ db: AppDatabase, rootId: String? = nil) throws -> [TaskEvent] {
        let r = rootId ?? root
        return sortedByInstant(try db.read { try TaskEvent.filter(Column("taskId") == r && Column("kind") == "increment").fetchAll($0) })
    }

    /// The LIVE credits on the root, by instant.
    private func liveCredits(_ db: AppDatabase, rootId: String? = nil) throws -> [TaskEvent] {
        try storedCredits(db, rootId: rootId).filter { !$0.isDeleted }
    }

    /// The contributor's own live events, by instant.
    private func liveEvents(_ db: AppDatabase, of taskId: String) throws -> [TaskEvent] {
        sortedByInstant(try db.read { try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll($0) })
    }

    private func creditId(_ rootId: String, _ scope: String, _ occurrence: CountsToward.Occurrence) -> String {
        CountsToward.eventId(rootId: rootId, contributorScopeId: scope, occurrence: occurrence)
    }

    /// An own-event credit id on `rootId` — the contributor is not part of the name.
    private func eventCredit(_ eventId: String, rootId: String? = nil) -> String { creditId(rootId ?? root, "-", .event(eventId: eventId)) }
    /// A compound's credit for its completing child's event — scoped by the compound (its lineage root).
    private func childCredit(_ compoundId: String, _ eventId: String, rootId: String? = nil) -> String {
        creditId(rootId ?? root, compoundId, .childEvent(eventId: eventId))
    }

    /// Credits + sync queue before/after a replay must be identical.
    private func expectReplayNoop(_ db: AppDatabase, _ taskIds: [String], roots: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let rs = roots ?? [root]
        let before = try rs.map { try storedCredits(db, rootId: $0).map { "\($0.id)|\($0.version)|\($0.updatedAt)|\($0.isDeleted)" } }
        let queueBefore = try db.read { try SyncQueueItem.fetchCount($0) }
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: taskIds, now: "2026-10-30T00:00:00.000Z") }
        let after = try rs.map { try storedCredits(db, rootId: $0).map { "\($0.id)|\($0.version)|\($0.updatedAt)|\($0.isDeleted)" } }
        XCTAssertEqual(after, before, "replay changed credits", file: file, line: line)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, queueBefore, "replay enqueued", file: file, line: line)
    }

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

    func test_compoundCreditsEachCompleteWindow_keyedByTheCompletingChildEvent_andAnUnplacedOneToo() throws {
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

        let a = try liveEvents(db, of: childA)
        let b = try liveEvents(db, of: childB)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.id), [childCredit(life, a[0].id), childCredit(box, b[0].id), childCredit(box, b[1].id)])
        XCTAssertEqual(credits.map(\.occurredAt), ["2026-10-06T09:00:00.000Z", inW1, "2026-10-15T09:00:00.000Z"])
        XCTAssertEqual(try fetch(db, root).currentCount, 3)
    }

    func test_compoundOnDailyAndMonthly_completedOnce_isOneCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(box, type: .compound, operatorType: .and, countsTowardCounterId: root).save(d)
            try task(childA).save(d)
            try link("l-a", box, childA, 0).save(d)
            try board(day, dayStart, dayEnd).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-day", day, box).save(d)
            try placement("bt-oct", oct, box, col: 1).save(d)
        }
        try libraryComplete(db, childA, at: now)
        let a = try XCTUnwrap(liveEvents(db, of: childA).first)
        XCTAssertEqual(try liveCredits(db).map(\.id), [childCredit(box, a.id)])
    }

    func test_editingABoardsStartDate_keepsACompoundsCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(box, type: .compound, operatorType: .and, countsTowardCounterId: root).save(d)
            try task(childA).save(d)
            try link("l-a", box, childA, 0).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-oct", oct, box).save(d)
        }
        try libraryComplete(db, childA, at: now)
        let before = try liveCredits(db)
        XCTAssertEqual(before.count, 1)

        try db.updateBoardAndCascade(boardId: oct, patch: AppDatabase.UpdateActiveBoardPatch(startDate: "2026-10-03T00:00:00.000Z"))
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.box], now: self.later) }

        XCTAssertEqual(try storedCredits(db).map(\.id), before.map(\.id))
        XCTAssertEqual(try storedCredits(db).map(\.version), before.map(\.version))
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }

    func test_clearingTheFlag_tombstonesEveryLiveCredit_andTheSinceStamp() throws {
        let db = try AppDatabase.makeTestInstance(); try seedWeeks(db)
        try complete(db, w1, "bt-w1", simple, at: inW1)
        try complete(db, w2, "bt-w2", simple)
        XCTAssertEqual(try liveCredits(db).count, 2)

        try db.setCountsToward(taskId: simple, counterId: nil, now: later)

        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try storedCredits(db).map(\.version), [2, 2])
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
        XCTAssertNil(try fetch(db, simple).countsTowardSince)
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

    // MARK: - Fork lineage shares one credit

    func test_boardScopedFork_carriesTheCompletionOverAsTheSameCredit() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        XCTAssertEqual(fork.countsTowardCounterId, root)
        XCTAssertEqual(fork.countsTowardSince, t0)
        XCTAssertEqual(try liveCredits(db).count, 1)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        let before = try storedCredits(db)
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [fork.id], now: self.now) }
        XCTAssertEqual(try storedCredits(db).map(\.version), before.map(\.version))
    }

    func test_undoOnTheForksBoardOnly_theOriginalStillWantsTheCredit_soItStays() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        try complete(db, oct, "bt-simple", fork.id, false)

        XCTAssertEqual(try liveEvents(db, of: fork.id).count, 0)
        XCTAssertEqual(try liveEvents(db, of: simple).count, 1)
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }

    func test_undoOnTheOriginalOnly_theForkStillWantsTheCredit_soItStays() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        try complete(db, week, "bt-other", simple, false)

        XCTAssertEqual(try liveEvents(db, of: simple).count, 0)
        XCTAssertEqual(try liveEvents(db, of: fork.id).count, 1)
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
    }

    func test_deletingTheOriginal_theForkStillWantsTheCredit_soItStays() throws {
        let db = try AppDatabase.makeTestInstance()
        _ = try forkCompletedDune(db)
        try db.deleteTaskWithCascade(taskId: simple)
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
    }

    func test_clearingTheForksFlag_theOriginalStillWantsIt_onceBothAreGoneItIsTombstoned() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        try db.setCountsToward(taskId: fork.id, counterId: nil, now: later)
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])

        try complete(db, week, "bt-other", simple, false)
        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try storedCredits(db).map(\.version), [2])
    }


    func test_originalRepointedWhileTheForkKeepsTheFirst_separateCreditsOnEachRoot_replaysWriteNothing() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        try db.write { try task(root2, type: .counting, maxCount: 5, isCounter: true).save($0) }

        try db.setCountsToward(taskId: simple, counterId: root2, now: later)
        // The shared completion (10-14) is before the original's new `since`:
        // only the fork keeps crediting ROOT; the original credits ROOT2 from now on.
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
        XCTAssertEqual(try liveCredits(db, rootId: root2).count, 0)

        try libraryComplete(db, simple, at: "2026-10-17T09:00:00.000Z")
        let events = try liveEvents(db, of: simple)
        XCTAssertEqual(try liveCredits(db, rootId: root2).map(\.id), [eventCredit(events[1].id, rootId: root2)])
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])

        try expectReplayNoop(db, [simple], roots: [root, root2])
        try expectReplayNoop(db, [fork.id], roots: [root, root2])
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        XCTAssertEqual(try fetch(db, root2).currentCount, 1)
    }

    func test_forkAndOriginalDisagreeOnTheAmount_sharedCreditTakesTheLineageRootsAmount_theForksOwnCompletionTakesTheForks() throws {
        let db = try AppDatabase.makeTestInstance()
        let fork = try forkCompletedDune(db)
        try db.setCountsToward(taskId: fork.id, counterId: root, amount: 3, now: later)

        // The copied completion is wanted by both members → the lineage root's amount (1), not the fork's 3.
        XCTAssertEqual(try liveCredits(db).map(\.delta), [1])
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
        try expectReplayNoop(db, [fork.id])
        try expectReplayNoop(db, [simple])

        // Raising the lineage root's amount moves the shared credit (2 — still not the fork's 3).
        try db.setCountsToward(taskId: simple, counterId: root, amount: 2, now: later)
        XCTAssertEqual(try liveCredits(db).map(\.delta), [2])
        XCTAssertEqual(try liveCredits(db).map(\.version), [2])
        try expectReplayNoop(db, [fork.id])

        // A completion only the fork makes credits the fork's own amount.
        try complete(db, oct, "bt-simple", fork.id, false)
        try complete(db, oct, "bt-simple", fork.id, true, at: later)
        let own = try XCTUnwrap(liveEvents(db, of: fork.id).first { $0.occurredAt == later })
        XCTAssertEqual(try liveCredits(db).map(\.delta), [2, 3])
        XCTAssertEqual(try liveCredits(db).map(\.version), [2, 1])
        XCTAssertEqual(try liveCredits(db).map(\.id).last, eventCredit(own.id))
        XCTAssertEqual(try fetch(db, root).currentCount, 5)
        try expectReplayNoop(db, [fork.id])
        try expectReplayNoop(db, [simple])
    }

    func test_creditWritesJoinTheCallersTransaction_aThrowAfterTheCascadePersistsNothing() throws {
        struct Abort: Error {}
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        let queueBefore = try db.read { try SyncQueueItem.fetchCount($0) }
        XCTAssertThrowsError(try db.write { d in
            try AppDatabase.appendCompletionEvent(db: d, taskId: self.simple, boardId: self.oct, now: self.now, occurredAt: self.now)
            try AppDatabase.runBoardCascadeForTasks(db: d, changedTaskIds: [self.simple], now: self.now)
            // Written, inside the transaction.
            XCTAssertEqual(try TaskEvent.filter(Column("taskId") == self.root && Column("isDeleted") == false).fetchCount(d), 1)
            throw Abort()
        })

        XCTAssertEqual(try storedCredits(db).count, 0)
        XCTAssertEqual(try liveEvents(db, of: simple).count, 0)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, queueBefore)
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
    }

    func test_forkWhoseOriginalIsNotLoadedYet_producesNothingUntilTheOriginalArrives() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(other, countsTowardCounterId: root, forkedFromTaskId: missing).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-other", oct, other).save(d)
        }
        try complete(db, oct, "bt-other", other)
        XCTAssertEqual(try storedCredits(db).count, 0)

        try db.write { try task(missing).save($0) }
        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.other], now: self.now) }
        let done = try XCTUnwrap(liveEvents(db, of: other).first)
        XCTAssertEqual(try liveCredits(db).map(\.id), [eventCredit(done.id)])
    }

    // MARK: - Count from flag time (D11)

    func test_flagSetAfterACompletion_doesNotCreditIt_aCompletionAfterTheFlagDoes() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, flagged: false)
        try libraryComplete(db, simple, at: "2026-10-10T10:00:00.000Z")

        try db.setCountsToward(taskId: simple, counterId: root, now: now)
        XCTAssertEqual(try fetch(db, simple).countsTowardSince, now)
        XCTAssertEqual(try liveCredits(db).count, 0)

        try libraryComplete(db, simple, at: later)
        let events = try liveEvents(db, of: simple)
        XCTAssertEqual(try liveCredits(db).map(\.id), [eventCredit(events[1].id)])
        XCTAssertEqual(try liveCredits(db).first?.occurredAt, later)
    }

    func test_lateLogStampedAtAnEndedBoardsEndDateBeforeTheFlag_doesNotCredit() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(simple).save(d)
            try board(w1, w1Start, w1End).save(d)
            try placement("bt-w1", w1, simple).save(d)
        }
        try db.setCountsToward(taskId: simple, counterId: root, now: now) // since = 10-14, after W1 ended

        try complete(db, w1, "bt-w1", simple) // stamped min(now, endDate) = W1's end

        let stamp = try XCTUnwrap(liveEvents(db, of: simple).first?.occurredAt)
        XCTAssertEqual(DateFormatting.parseISO(stamp), DateFormatting.parseISO(w1End))
        XCTAssertEqual(try liveCredits(db).count, 0)
    }

    func test_repointingToAnotherCounter_resetsSince_tombstonesEarlierCredits_creditsLaterOnesOnTheNewRoot() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try db.write { try task(root2, type: .counting, maxCount: 5, isCounter: true).save($0) }
        try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(try liveCredits(db).count, 1)

        try db.setCountsToward(taskId: simple, counterId: root2, now: later)
        XCTAssertEqual(try fetch(db, simple).countsTowardSince, later)
        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try liveCredits(db, rootId: root2).count, 0)

        try libraryComplete(db, simple, at: "2026-10-17T09:00:00.000Z")
        XCTAssertEqual(try liveCredits(db, rootId: root2).map(\.occurredAt), ["2026-10-17T09:00:00.000Z"])
        XCTAssertEqual(try liveCredits(db).count, 0)
    }

    func test_changingOnlyTheAmountKeepsSince_clearingDropsIt() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        try db.setCountsToward(taskId: simple, counterId: root, amount: 3, now: later)
        XCTAssertEqual(try fetch(db, simple).countsTowardSince, t0)
        XCTAssertEqual(try liveCredits(db).map(\.delta), [3])

        try db.setCountsToward(taskId: simple, counterId: nil, now: later)
        let cleared = try fetch(db, simple)
        XCTAssertNil(cleared.countsTowardCounterId)
        XCTAssertNil(cleared.countsTowardAmount)
        XCTAssertNil(cleared.countsTowardSince)
    }

    // MARK: - Credits honour the counter's sealed windows (D11)

    func test_undoOnTheOpenMonthly_leavesACreditInsideANowSealedWeeklyCopyWindow_snapshotUnchanged() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(try completedTasks(db, week), 1)
        XCTAssertTrue(try db.sealBoard(boardId: week, now: "2026-10-19T00:00:00.000Z"))
        let sealed = try XCTUnwrap(db.fetchBoard(id: week))
        XCTAssertEqual(sealed.sealedCompletedCells, [0])

        try complete(db, oct, "bt-simple", simple, false, at: "2026-10-20T09:00:00.000Z")

        XCTAssertEqual(try liveEvents(db, of: simple).count, 0)
        XCTAssertEqual(try liveCredits(db).map(\.version), [1])
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        let after = try XCTUnwrap(db.fetchBoard(id: week))
        XCTAssertEqual(after.sealedCompletedCells, [0])
        XCTAssertEqual(after.completedTasks, 1)
        XCTAssertEqual(after.version, sealed.version)
    }

    func test_aCreditInsideASealedCopyWindow_isNotMintedOutsideTheLateLogPath() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        XCTAssertTrue(try db.sealBoard(boardId: week, now: "2026-10-19T00:00:00.000Z"))
        try libraryComplete(db, simple, at: now) // 10-14 sits inside the sealed week
        XCTAssertEqual(try liveCredits(db).count, 0)

        try libraryComplete(db, simple, at: "2026-10-20T09:00:00.000Z") // outside it
        XCTAssertEqual(try liveCredits(db).map(\.occurredAt), ["2026-10-20T09:00:00.000Z"])
    }


    func test_lateLogExemptionCoversOnlyTheStampedInstant_aChainedCreditInsideASealedWindowStaysSuppressed() throws {
        let closedEnd = "2026-10-07T23:59:59.999Z"
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(root2, type: .counting, maxCount: 5, isCounter: true).save(d)
            try task(copy, type: .counting, maxCount: 1, sharedCounterId: root).save(d)
            try task(copy2, type: .counting, maxCount: 1, sharedCounterId: root2).save(d)
            try task(simple, countsTowardCounterId: root).save(d) // → ROOT, late-logged on the closed board
            try task(box, type: .compound, operatorType: .and, countsTowardCounterId: root2).save(d) // [copy of ROOT, Z] → ROOT2
            try task(z).save(d)
            try link("l-copy", box, copy, 0).save(d)
            try link("l-z", box, z, 1).save(d)
            try board(closed, octStart, closedEnd, sealedAt: "2026-10-08T00:00:01.000Z").save(d)
            try board(oct, octStart, octEnd).save(d) // open; holds ROOT's copy and the container
            try board(sealedLate, "2026-10-19T00:00:00.000Z", "2026-10-25T23:59:59.999Z", sealedAt: "2026-10-26T00:00:01.000Z").save(d) // holds ROOT2's copy
            try placement("bt-simple-closed", closed, simple).save(d)
            try placement("bt-copy-oct", oct, copy).save(d)
            try placement("bt-box-oct", oct, box, col: 1).save(d)
            try placement("bt-copy2-late", sealedLate, copy2).save(d)
            try completion("ev-z", z, "2026-10-20T09:00:00.000Z").save(d)
        }

        try db.lateLogCompletion(boardId: closed, taskId: simple, now: "2026-10-27T09:00:00.000Z")

        // ROOT's credit at the stamped instant lands; the container it completes
        // (its completing child is Z at 10-20) sits inside ROOT2's sealed copy
        // window → that chained credit is suppressed.
        XCTAssertEqual(try liveCredits(db).map { DateFormatting.parseISO($0.occurredAt) }, [DateFormatting.parseISO(closedEnd)])
        XCTAssertEqual(try storedCredits(db, rootId: root2).count, 0)
        XCTAssertEqual(try fetch(db, root2).currentCount, 0)
    }

    // MARK: - A Compound container

    func test_compoundCountsOnceBothSubTasksAreDone_keyedByTheLaterChildsEvent() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        try libraryComplete(db, childA, at: "2026-10-13T08:00:00.000Z")
        XCTAssertEqual(try liveCredits(db).count, 0)
        try libraryComplete(db, childB, at: "2026-10-15T20:00:00.000Z")

        let b = try XCTUnwrap(liveEvents(db, of: childB).first)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.count, 1)
        let ev = try XCTUnwrap(credits.first)
        XCTAssertEqual(ev.id, childCredit(box, b.id))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(ev.delta, 1)
        XCTAssertEqual(ev.occurredAt, "2026-10-15T20:00:00.000Z")
        XCTAssertEqual(try completedTasks(db, week), 1)
    }

    func test_lateLogOnClosedBoard_completesTheContainer_creditStampedAtEndDate_evenThoughTheCopysWindowThereIsSealed() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        let closedStart = "2026-10-01T00:00:00.000Z"
        let closedEnd = "2026-10-07T23:59:59.999Z"
        try db.write { d in
            try board(closed, closedStart, closedEnd, sealedAt: "2026-10-08T00:00:01.000Z").save(d)
            try placement("bt-closed", closed, box, col: 1).save(d)
            try placement("bt-copy-closed", closed, copy, col: 2).save(d)
            try completion("ev-a", childA, "2026-10-03T10:00:00.000Z").save(d)
        }
        try db.lateLogCompoundParts(boardId: closed, compoundTaskId: box, childTaskIds: [childB], now: now)

        let b = try XCTUnwrap(liveEvents(db, of: childB).first)
        let credits = try liveCredits(db)
        XCTAssertEqual(credits.map(\.id), [childCredit(box, b.id)])
        XCTAssertEqual(credits.first?.taskId, root)
        XCTAssertEqual(DateFormatting.parseISO(try XCTUnwrap(credits.first?.occurredAt)), DateFormatting.parseISO(closedEnd))
        let cells = try XCTUnwrap(db.fetchBoard(id: closed)?.sealedCompletedCells)
        XCTAssertTrue(cells.contains(1) && cells.contains(2))
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

    func test_deletingTheCounter_unflagsContributors_sinceCleared_creditsStayWithTheRoot() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try complete(db, oct, "bt-simple", simple)
        let versionBefore = try fetch(db, simple).version
        try db.write { try $0.execute(sql: "DELETE FROM sync_queue") }

        try db.deleteCounterWithUnlink(sourceId: root, now: now)

        let after = try fetch(db, simple)
        XCTAssertNil(after.countsTowardCounterId)
        XCTAssertNil(after.countsTowardSince)
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

    func test_aFlaggedCountingTask_cannotBePromotedToACounter() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try runTask().save(d)
        }
        XCTAssertThrowsError(try db.promoteTaskToCounter(taskId: run, now: now)) { error in
            XCTAssertTrue("\(error)".contains("counterPromotionRejected"), "expected counterPromotionRejected, got \(error)")
            XCTAssertTrue("\(error)".contains("counts toward a counter cannot be a counter"))
        }
        XCTAssertFalse(try fetch(db, run).isCounter)
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

        try db.setCountsToward(taskId: simple, counterId: root, amount: 2, now: "2026-10-09T00:00:00.000Z") // since before the completion
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

    func test_pullingAContributorRowWhoseFlagAnotherDeviceCleared_withdrawsItsCreditsHere() throws {
        let db = try AppDatabase.makeTestInstance(); try seedUser(db)
        try db.write { d in
            try task(root, type: .counting, maxCount: 12, isCounter: true).save(d)
            try task(box, type: .compound, operatorType: .and, countsTowardCounterId: root).save(d)
            try task(childA).save(d)
            try link("l-a", box, childA, 0).save(d)
            try board(oct, octStart, octEnd).save(d)
            try placement("bt-box", oct, box).save(d)
        }
        try libraryComplete(db, childA, at: now)
        XCTAssertEqual(try liveCredits(db).count, 1)

        var remote = try db.read { try XCTUnwrap(Task.fetchOne($0, key: box)) }
        remote.countsTowardCounterId = nil
        remote.countsTowardSince = nil
        remote.updatedAt = later
        remote.version += 1
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SyncQueueBuilder.encodePayload(remote).utf8)) as? [String: Any])
        let outcome = try db.write {
            try AppDatabase.applyPullBatchTx(db: $0, collection: (firestoreName: "tasks", grdbTable: "tasks"), docs: [doc], userId: self.user)
        }
        XCTAssertEqual(outcome.pulled, 1)

        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try storedCredits(db).map(\.version), [2])
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
    }

    func test_pullingAContributorRowAnotherDeviceRepointed_movesItsCreditsToTheNewRoot() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        try db.write { try task(root2, type: .counting, maxCount: 5, isCounter: true).save($0) }
        try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(try liveCredits(db).count, 1)

        var remote = try fetch(db, simple)
        remote.countsTowardCounterId = root2
        remote.countsTowardSince = t0
        remote.updatedAt = later
        remote.version += 1
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SyncQueueBuilder.encodePayload(remote).utf8)) as? [String: Any])
        _ = try db.write {
            try AppDatabase.applyPullBatchTx(db: $0, collection: (firestoreName: "tasks", grdbTable: "tasks"), docs: [doc], userId: self.user)
        }

        XCTAssertEqual(try liveCredits(db).count, 0)
        XCTAssertEqual(try storedCredits(db).map(\.version), [2])
        XCTAssertEqual(try liveCredits(db, rootId: root2).map(\.occurredAt), [now])
    }
}
