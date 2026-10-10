import XCTest
import GRDB
@testable import OYBC

/// "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3).
/// Twin of web `db/operations/__tests__/countsToward.test.ts`.
@MainActor
final class CountsTowardTests: XCTestCase {

    private let user = "user-1"
    private let t0 = "2026-01-01T00:00:00.000Z"
    private let root = "00000000-0000-4000-8000-0000000000a1"   // "Read 12 books"
    private let copy = "00000000-0000-4000-8000-0000000000a2"   // weekly copy, goal 1
    private let simple = "00000000-0000-4000-8000-0000000000b1" // "Read Dune"
    private let childA = "00000000-0000-4000-8000-0000000000c1"
    private let childB = "00000000-0000-4000-8000-0000000000c2"
    private let box = "00000000-0000-4000-8000-0000000000d1"
    private let oct = "00000000-0000-4000-8000-0000000000e1"
    private let week = "00000000-0000-4000-8000-0000000000e2"
    private let closed = "00000000-0000-4000-8000-0000000000e3"
    private let octStart = "2026-10-01T00:00:00.000Z"
    private let octEnd = "2026-10-31T23:59:59.999Z"
    private let weekStart = "2026-10-12T00:00:00.000Z"
    private let weekEnd = "2026-10-18T23:59:59.999Z"
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

    private func complete(_ db: AppDatabase, _ boardId: String, _ boardTaskId: String, _ taskId: String, _ done: Bool = true)
        throws -> [String: AppDatabase.CascadeBoardResult] {
        let b = try XCTUnwrap(db.fetchBoard(id: boardId))
        let bt = try XCTUnwrap(db.read { try BoardTask.fetchOne($0, key: boardTaskId) })
        return try db.completeTaskOrchestrated(board: b, taskId: taskId, intent: .setCompleted(done), boardTask: bt, now: now)
    }

    /// A library-style completion: event + the cascade, one transaction.
    private func libraryComplete(_ db: AppDatabase, _ taskId: String, at: String) throws {
        try db.write { d in
            try AppDatabase.appendCompletionEvent(db: d, taskId: taskId, boardId: nil, now: at, occurredAt: at)
            try AppDatabase.runBoardCascadeForTasks(db: d, changedTaskIds: [taskId], now: at)
        }
    }

    private func event(_ db: AppDatabase, for contributor: String) throws -> TaskEvent? {
        try db.read { try TaskEvent.fetchOne($0, key: CountsToward.eventId(contributingTaskId: contributor)) }
    }

    private func liveEvent(_ db: AppDatabase, for contributor: String) throws -> TaskEvent? {
        try event(db, for: contributor).flatMap { $0.isDeleted ? nil : $0 }
    }

    private func fetch(_ db: AppDatabase, _ id: String) throws -> Task { try XCTUnwrap(db.read { try Task.fetchOne($0, key: id) }) }
    private func completedTasks(_ db: AppDatabase, _ boardId: String) throws -> Int { try XCTUnwrap(db.fetchBoard(id: boardId)).completedTasks }
    private func queued(_ db: AppDatabase, _ type: String) throws -> [String] {
        try db.read { try SyncQueueItem.filter(Column("entityType") == type).fetchAll($0).map(\.entityId) }
    }

    // MARK: - A Simple task

    func test_simpleCompletes_plusOneOnRoot_stampedAtCompletion_weeklyCopyCountsInWindow() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        _ = try complete(db, oct, "bt-simple", simple)

        let ev = try XCTUnwrap(liveEvent(db, for: simple))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(ev.kind, .increment)
        XCTAssertEqual(ev.delta, 1)
        XCTAssertEqual(ev.occurredAt, now)
        XCTAssertEqual(ev.version, 1)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
        XCTAssertEqual(try completedTasks(db, week), 1)
        XCTAssertTrue(try queued(db, "taskEvents").contains(ev.id))
    }

    func test_uncomplete_tombstonesTheIncrement_copyDropsBack() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        _ = try complete(db, oct, "bt-simple", simple)
        _ = try complete(db, oct, "bt-simple", simple, false)

        let ev = try XCTUnwrap(event(db, for: simple))
        XCTAssertTrue(ev.isDeleted)
        XCTAssertEqual(ev.version, 2)
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
        XCTAssertEqual(try completedTasks(db, week), 0)
    }

    func test_amountThree() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db, amount: 3)
        _ = try complete(db, oct, "bt-simple", simple)
        XCTAssertEqual(try liveEvent(db, for: simple)?.delta, 3)
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
        _ = try complete(db, oct, "bt-simple", simple)
        let queueBefore = try db.read { try SyncQueueItem.fetchCount($0) }
        let eventBefore = try XCTUnwrap(event(db, for: simple))
        let rootVersionBefore = try fetch(db, root).version

        try db.write { try AppDatabase.runBoardCascadeForTasks(db: $0, changedTaskIds: [self.simple], now: "2026-10-14T10:00:00.000Z") }

        XCTAssertEqual(eventBefore.version, 1)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, queueBefore)
        let eventAfter = try XCTUnwrap(event(db, for: simple))
        XCTAssertEqual(eventAfter.version, eventBefore.version)
        XCTAssertEqual(eventAfter.updatedAt, eventBefore.updatedAt)
        XCTAssertEqual(eventAfter.occurredAt, eventBefore.occurredAt)
        XCTAssertEqual(try fetch(db, root).version, rootVersionBefore)
    }

    // MARK: - A Compound container

    func test_compoundCountsOnceBothSubTasksAreDone_stampedAtTheLaterOne() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        try libraryComplete(db, childA, at: "2026-10-13T08:00:00.000Z")
        XCTAssertNil(try liveEvent(db, for: box))
        try libraryComplete(db, childB, at: "2026-10-15T20:00:00.000Z")

        let ev = try XCTUnwrap(liveEvent(db, for: box))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(ev.delta, 1)
        XCTAssertEqual(ev.occurredAt, "2026-10-15T20:00:00.000Z")
        XCTAssertEqual(try completedTasks(db, week), 1)
    }

    func test_lateLogOnClosedBoard_completesTheContainer_incrementStampedAtEndDate() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db)
        let closedEnd = "2026-10-07T23:59:59.999Z"
        try db.write { d in
            try board(closed, "2026-10-01T00:00:00.000Z", closedEnd, sealedAt: "2026-10-08T00:00:01.000Z").save(d)
            try placement("bt-closed", closed, box, col: 1).save(d)
            try completion("ev-a", childA, "2026-10-03T10:00:00.000Z").save(d)
        }
        try db.lateLogCompoundParts(boardId: closed, compoundTaskId: box, childTaskIds: [childB], now: now)

        let ev = try XCTUnwrap(liveEvent(db, for: box))
        XCTAssertEqual(ev.taskId, root)
        XCTAssertEqual(DateFormatting.parseISO(ev.occurredAt), DateFormatting.parseISO(closedEnd))
    }

    func test_deletingTheSubTaskTheContainerNeeded_reDerivesIt() throws {
        let db = try AppDatabase.makeTestInstance(); try seedBox(db, op: .or)
        try libraryComplete(db, childA, at: now)
        XCTAssertNotNil(try liveEvent(db, for: box))
        try db.deleteTaskWithCascade(taskId: childA)
        XCTAssertNil(try liveEvent(db, for: box))
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

    // MARK: - Forks, deletion and guards

    func test_boardScopedFork_keepsTheFlag_andMintsItsOwnEvent() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        let original = try fetch(db, simple)
        let plan = BoardScopedFork.plan(
            task: original, board: board(oct, octStart, octEnd), editedType: .normal,
            placements: [placement("bt-simple", oct, simple), placement("bt-other", week, simple, col: 2)],
            boards: [board(oct, octStart, octEnd), board(week, weekStart, weekEnd)],
            compoundChildren: [], events: [], now: now
        )
        guard case let .fork(fork, _, _, _, _) = plan else { return XCTFail("expected a fork") }
        XCTAssertEqual(fork.countsTowardCounterId, root)
        try db.write { d in
            try fork.save(d)
            try d.execute(sql: "UPDATE board_tasks SET taskId = ? WHERE id = 'bt-simple'", arguments: [fork.id])
        }
        _ = try complete(db, oct, "bt-simple", fork.id)
        XCTAssertEqual(try liveEvent(db, for: fork.id)?.taskId, root)
        XCTAssertNil(try liveEvent(db, for: simple))
    }

    func test_deletingAContributor_tombstonesItsIncrement() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        _ = try complete(db, oct, "bt-simple", simple)
        try db.deleteTaskWithCascade(taskId: simple)
        XCTAssertEqual(try event(db, for: simple)?.isDeleted, true)
        XCTAssertEqual(try fetch(db, root).currentCount, 0)
    }

    func test_deletePreview_namesTheCounter() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        XCTAssertEqual(try db.computeTaskDeletionImpact(taskId: simple).countsTowardCounter?.id, root)
        XCTAssertNil(try db.computeTaskDeletionImpact(taskId: copy).countsTowardCounter)
    }

    func test_deletingTheCounter_unflagsContributors_eventsStayWithTheRoot() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        _ = try complete(db, oct, "bt-simple", simple)
        let versionBefore = try fetch(db, simple).version
        try db.write { try $0.execute(sql: "DELETE FROM sync_queue") }

        try db.deleteCounterWithUnlink(sourceId: root, now: now)

        let after = try fetch(db, simple)
        XCTAssertNil(after.countsTowardCounterId)
        XCTAssertEqual(after.version, versionBefore + 1)
        XCTAssertTrue(try queued(db, "tasks").contains(simple))
        XCTAssertEqual(try event(db, for: simple)?.isDeleted, false)
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
        try db.write { d in
            try completion("00000000-0000-4000-8000-0000000000f1", simple, "2026-10-10T10:00:00.000Z").save(d)
            try task(km, type: .counting, maxCount: 5, isCounter: true, countKind: .continuous).save(d)
        }
        XCTAssertThrowsError(try db.setCountsToward(taskId: simple, counterId: km)) {
            XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.targetNotDiscrete))
        }
        XCTAssertThrowsError(try db.setCountsToward(taskId: simple, counterId: simple)) {
            XCTAssertEqual($0 as? AppDatabase.CountsTowardError, .refused(.selfTarget))
        }

        try db.setCountsToward(taskId: simple, counterId: root, amount: 2)
        let ev = try XCTUnwrap(liveEvent(db, for: simple))
        XCTAssertEqual(ev.delta, 2)
        XCTAssertEqual(ev.occurredAt, "2026-10-10T10:00:00.000Z")

        try db.setCountsToward(taskId: simple, counterId: nil)
        let cleared = try fetch(db, simple)
        XCTAssertNil(cleared.countsTowardCounterId)
        XCTAssertNil(cleared.countsTowardAmount)
        XCTAssertNil(try liveEvent(db, for: simple))
    }

    // MARK: - Pull path

    func test_secondDevice_reDerivesTheSameEvent_fromThePulledCompletion_andThePeersCopyConverges() throws {
        let db = try AppDatabase.makeTestInstance(); try seed(db)
        let completionDoc: [String: Any] = [
            "id": "00000000-0000-4000-8000-0000000000f9", "userId": user, "taskId": simple, "kind": "completion",
            "occurredAt": "2026-10-13T07:30:00.000Z", "createdAt": "2026-10-13T07:30:00.000Z",
            "updatedAt": "2026-10-13T07:30:00.000Z", "version": 1, "isDeleted": false,
        ]
        _ = try db.write { try AppDatabase.applyTaskEventsBatchTx(db: $0, userId: self.user, rawDocs: [completionDoc]) }
        let mine = try XCTUnwrap(liveEvent(db, for: simple))
        XCTAssertEqual(mine.taskId, root)
        XCTAssertEqual(mine.delta, 1)
        XCTAssertEqual(mine.occurredAt, "2026-10-13T07:30:00.000Z")

        let peer: [String: Any] = [
            "id": CountsToward.eventId(contributingTaskId: simple), "userId": user, "taskId": root,
            "kind": "increment", "delta": 1, "occurredAt": "2026-10-13T07:30:00.000Z",
            "createdAt": "2026-10-13T07:30:01.000Z", "updatedAt": "2026-10-13T07:30:01.000Z",
            "version": 1, "isDeleted": false,
        ]
        _ = try db.write { try AppDatabase.applyTaskEventsBatchTx(db: $0, userId: self.user, rawDocs: [peer]) }
        let rows = try db.read { try TaskEvent.filter(Column("taskId") == self.root).fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.delta, 1)
        XCTAssertEqual(rows.first?.occurredAt, "2026-10-13T07:30:00.000Z")
        XCTAssertEqual(rows.first?.isDeleted, false)
        XCTAssertEqual(try fetch(db, root).currentCount, 1)
    }
}
