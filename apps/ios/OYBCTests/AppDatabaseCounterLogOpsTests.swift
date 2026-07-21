import XCTest
import GRDB
@testable import OYBC

/// Tests for `AppDatabase.undoLastCounterLog(sourceTaskId:)` and
/// `AppDatabase.setCounterDefaultLogAmount(sourceTaskId:amount:)` (R2
/// Counters UX refresh — `Database/AppDatabase+SharedCounters.swift`).
///
/// `undoLastCounterLog` mirrors `decrementSharedCounter`'s write shape
/// (source `currentCount` correction + linked-task propagation + board
/// cascade + one-way completion latch) but keyed to a specific `TaskEvent`
/// rather than a fresh negative event — these tests cover both the shared
/// invariants (latch, cascade) and the undo-specific mechanics (tombstoning
/// the right entry, seed-sentinel exclusion, negative-delta reversal).
final class AppDatabaseCounterLogOpsTests: XCTestCase {

    // MARK: - Helpers (mirrors AppDatabaseSharedCounterDecrementTests)

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id,
            email: "test@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
        try db.saveUser(user)
    }

    private func makeSourceTask(
        id: String,
        userId: String = "u1",
        currentCount: Int = 10,
        maxCount: Int = 20,
        isCompleted: Bool = false,
        completedAt: String? = nil,
        defaultLogAmount: Int? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Test Counter \(id)",
            description: nil,
            type: .counting,
            action: "Do",
            unit: "reps",
            maxCount: maxCount,
            operatorType: nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            completedAt: completedAt,
            currentCount: currentCount,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: nil,
            baseline: nil,
            lastSyncedCount: nil,
            createdInWizard: false,
            isCounter: false,
            defaultLogAmount: defaultLogAmount
        )
    }

    private func makeLinkedTask(
        id: String,
        sourceId: String,
        userId: String = "u1",
        baseline: Int = 0,
        maxCount: Int = 10,
        isCompleted: Bool = false
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Linked Counter \(id)",
            description: nil,
            type: .counting,
            action: "Do",
            unit: "reps",
            maxCount: maxCount,
            operatorType: nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            completedAt: nil,
            currentCount: nil,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: sourceId,
            baseline: baseline,
            lastSyncedCount: nil,
            createdInWizard: false
        )
    }

    /// Seeds a live `increment` TaskEvent directly (bypassing the write
    /// choke points — mirrors how `incrementSharedCounter` writes via
    /// `insertIncrementEventRaw`, i.e. no cache restamp).
    @discardableResult
    private func seedIncrementEvent(
        _ db: AppDatabase,
        id: String = UUID().uuidString,
        taskId: String,
        userId: String = "u1",
        delta: Int,
        occurredAt: String,
        createdAt: String? = nil
    ) throws -> TaskEvent {
        let ts = createdAt ?? occurredAt
        let event = TaskEvent(
            id: id, userId: userId, taskId: taskId,
            kind: .increment, delta: delta, occurredAt: occurredAt, boardId: nil,
            createdAt: ts, updatedAt: ts, lastSyncedAt: nil,
            version: 1, isDeleted: false, deletedAt: nil
        )
        try db.write { try event.save($0) }
        return event
    }

    private func makeBoard(id: String, name: String, userId: String = "u1") -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": name,
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false, "totalTasks": 9, "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: UUID().uuidString, boardId: boardId, taskId: taskId,
            row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    // MARK: - undoLastCounterLog: no-op paths

    func test_undo_noSource_returnsZero() throws {
        let db = try makeDb()
        try seedUser(db)
        let result = try db.undoLastCounterLog(sourceTaskId: "missing")
        XCTAssertEqual(result.undoneAmount, 0)
        XCTAssertTrue(result.affectedBoards.isEmpty)
    }

    func test_undo_deletedSource_returnsZero() throws {
        let db = try makeDb()
        try seedUser(db)
        var source = makeSourceTask(id: "src-del", currentCount: 5)
        source.isDeleted = true
        try db.saveTask(source)
        let result = try db.undoLastCounterLog(sourceTaskId: "src-del")
        XCTAssertEqual(result.undoneAmount, 0)
    }

    func test_undo_noUndoableEntry_returnsZeroAndLeavesCountUnchanged() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-noevt", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        let result = try db.undoLastCounterLog(sourceTaskId: "src-noevt")

        XCTAssertEqual(result.undoneAmount, 0)
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-noevt") })
        XCTAssertEqual(fetched.currentCount, 5, "no undoable event → currentCount must be unchanged")
    }

    func test_undo_onlySeedSentinelEvent_returnsZero() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-seed", currentCount: 100, maxCount: 200)
        try db.saveTask(source)
        try seedIncrementEvent(db, taskId: "src-seed", delta: 100, occurredAt: TaskEvents.seedEventOccurredAt)

        let result = try db.undoLastCounterLog(sourceTaskId: "src-seed")

        XCTAssertEqual(result.undoneAmount, 0, "the seed/backfill sentinel event must never be undoable")
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-seed") })
        XCTAssertEqual(fetched.currentCount, 100)
    }

    // MARK: - undoLastCounterLog: reverses the most recent entry

    func test_undo_reversesSimpleIncrement() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-1", currentCount: 15, maxCount: 100)
        try db.saveTask(source)
        try seedIncrementEvent(db, taskId: "src-1", delta: 5, occurredAt: "2026-07-20T09:00:00.000")

        let result = try db.undoLastCounterLog(sourceTaskId: "src-1")

        XCTAssertEqual(result.undoneAmount, 5)
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-1") })
        XCTAssertEqual(fetched.currentCount, 10, "currentCount must be corrected by subtracting the reversed entry's delta")

        // The event itself must be tombstoned.
        let events = try db.read { try TaskEvent.filter(Column("taskId") == "src-1").fetchAll($0) }
        let undone = try XCTUnwrap(events.first { $0.delta == 5 })
        XCTAssertTrue(undone.isDeleted, "the undone event must be tombstoned")
    }

    func test_undo_reversesNegativeDeltaEntry_addsAmountBack() throws {
        // Undoing a DECREMENT entry (negative delta) should ADD the amount
        // back — `newCurrentCount = currentCount - entry.delta`, and
        // `entry.delta` is negative here.
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-2", currentCount: 8, maxCount: 100)
        try db.saveTask(source)
        try seedIncrementEvent(db, taskId: "src-2", delta: -2, occurredAt: "2026-07-20T09:00:00.000")

        let result = try db.undoLastCounterLog(sourceTaskId: "src-2")

        XCTAssertEqual(result.undoneAmount, 2, "undoneAmount is the ABSOLUTE amount reversed")
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-2") })
        XCTAssertEqual(fetched.currentCount, 10, "undoing a decrement adds the amount back")
    }

    func test_undo_picksMostRecentEntryOnly() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-3", currentCount: 30, maxCount: 100)
        try db.saveTask(source)
        try seedIncrementEvent(db, id: "e-old", taskId: "src-3", delta: 10, occurredAt: "2026-07-18T09:00:00.000")
        try seedIncrementEvent(db, id: "e-new", taskId: "src-3", delta: 20, occurredAt: "2026-07-20T09:00:00.000")

        let result = try db.undoLastCounterLog(sourceTaskId: "src-3")

        XCTAssertEqual(result.undoneAmount, 20, "only the MOST RECENT entry is reversed")
        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-3") })
        XCTAssertEqual(fetched.currentCount, 10)

        let events = try db.read { try TaskEvent.filter(Column("taskId") == "src-3").fetchAll($0) }
        XCTAssertTrue(events.first { $0.id == "e-new" }!.isDeleted)
        XCTAssertFalse(events.first { $0.id == "e-old" }!.isDeleted, "the older entry must be left alone")
    }

    func test_undo_skipsAlreadyDeletedEvents() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-4", currentCount: 30, maxCount: 100)
        try db.saveTask(source)
        var deleted = try seedIncrementEvent(db, id: "e-deleted", taskId: "src-4", delta: 50, occurredAt: "2026-07-20T12:00:00.000")
        deleted.isDeleted = true
        try db.write { try deleted.save($0) }
        try seedIncrementEvent(db, id: "e-live", taskId: "src-4", delta: 5, occurredAt: "2026-07-19T09:00:00.000")

        let result = try db.undoLastCounterLog(sourceTaskId: "src-4")

        XCTAssertEqual(result.undoneAmount, 5, "a soft-deleted event must never be selected for undo")
    }

    // MARK: - undoLastCounterLog: ONE-WAY LATCH

    func test_undo_doesNotUncompleteSource() throws {
        let db = try makeDb()
        try seedUser(db)
        let completedAt = "2026-06-15T10:00:00.000Z"
        let source = makeSourceTask(
            id: "src-latch", currentCount: 20, maxCount: 20,
            isCompleted: true, completedAt: completedAt
        )
        try db.saveTask(source)
        try seedIncrementEvent(db, taskId: "src-latch", delta: 5, occurredAt: "2026-07-20T09:00:00.000")

        _ = try db.undoLastCounterLog(sourceTaskId: "src-latch")

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-latch") })
        XCTAssertEqual(fetched.currentCount, 15)
        XCTAssertTrue(fetched.isCompleted, "ONE-WAY LATCH: undo must not un-complete the source")
        XCTAssertEqual(fetched.completedAt, completedAt)
    }

    // MARK: - undoLastCounterLog: linked-task propagation

    func test_undo_propagatesToLinkedTasks() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-link", currentCount: 20, maxCount: 100)
        try db.saveTask(source)
        let linked = makeLinkedTask(id: "lnk-1", sourceId: "src-link", baseline: 0, maxCount: 30)
        try db.saveTask(linked)
        try seedIncrementEvent(db, taskId: "src-link", delta: 5, occurredAt: "2026-07-20T09:00:00.000")

        _ = try db.undoLastCounterLog(sourceTaskId: "src-link")

        let fetchedLinked = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "lnk-1") })
        XCTAssertEqual(fetchedLinked.currentCount, 15, "linked task must mirror the corrected source count")
    }

    // MARK: - undoLastCounterLog: affectedBoards

    func test_undo_returnsActiveBoardsWithMemberTasks() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-ab", currentCount: 10, maxCount: 100)
        try db.saveTask(source)
        let board = makeBoard(id: "board-a", name: "June Board")
        try db.saveBoard(board)
        try db.saveBoardTask(makeBoardTask(boardId: "board-a", taskId: "src-ab"))
        try seedIncrementEvent(db, taskId: "src-ab", delta: 3, occurredAt: "2026-07-20T09:00:00.000")

        let result = try db.undoLastCounterLog(sourceTaskId: "src-ab")

        XCTAssertEqual(result.undoneAmount, 3)
        XCTAssertTrue(result.affectedBoards.contains(where: { $0.boardId == "board-a" }))
    }

    // MARK: - undoLastCounterLog: validation

    func test_undo_passingLinkedId_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-e", currentCount: 5, maxCount: 20)
        try db.saveTask(source)
        let linked = makeLinkedTask(id: "lnk-e", sourceId: "src-e")
        try db.saveTask(linked)

        XCTAssertThrowsError(try db.undoLastCounterLog(sourceTaskId: "lnk-e"))
    }

    // MARK: - setCounterDefaultLogAmount

    func test_setDefault_persistsAmountAndBumpsVersion() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-d1", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        try db.setCounterDefaultLogAmount(sourceTaskId: "src-d1", amount: 10)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-d1") })
        XCTAssertEqual(fetched.defaultLogAmount, 10)
        XCTAssertEqual(fetched.version, 2)
    }

    func test_setDefault_noOpWhenAmountUnchanged() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-d2", currentCount: 5, maxCount: 20, defaultLogAmount: 10)
        try db.saveTask(source)

        try db.setCounterDefaultLogAmount(sourceTaskId: "src-d2", amount: 10)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-d2") })
        XCTAssertEqual(fetched.version, 1, "no-op when the amount already matches — no needless version bump")
    }

    func test_setDefault_throwsForNonPositiveAmount() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-d3", currentCount: 5, maxCount: 20)
        try db.saveTask(source)

        XCTAssertThrowsError(try db.setCounterDefaultLogAmount(sourceTaskId: "src-d3", amount: 0))
        XCTAssertThrowsError(try db.setCounterDefaultLogAmount(sourceTaskId: "src-d3", amount: -5))
    }

    func test_setDefault_throwsForLinkedTask() throws {
        let db = try makeDb()
        try seedUser(db)
        let source = makeSourceTask(id: "src-d4", currentCount: 5, maxCount: 20)
        try db.saveTask(source)
        let linked = makeLinkedTask(id: "lnk-d4", sourceId: "src-d4")
        try db.saveTask(linked)

        XCTAssertThrowsError(try db.setCounterDefaultLogAmount(sourceTaskId: "lnk-d4", amount: 5))
    }

    func test_setDefault_missingSource_isSilentNoOp() throws {
        let db = try makeDb()
        try seedUser(db)
        XCTAssertNoThrow(try db.setCounterDefaultLogAmount(sourceTaskId: "missing", amount: 5))
    }
}
