import XCTest
import GRDB
@testable import OYBC

/// Tests for the P5 counter write ops (Shared Counters Hub, PR-2) — Swift
/// twin of `apps/web/src/db/operations/__tests__/counterOps.test.ts`.
///
/// Covers:
///   1. `createCounterTask` — writes task + seed event atomically; no event
///      when `startingCount` is 0/nil; rejects blank action/unit; rejects a
///      negative `startingCount`.
///   2. `promoteTaskToCounter` — flags a standalone counting task; rejects a
///      derived (linked) task, a non-counting task, and a missing/deleted task.
///   3. `deleteCounterWithUnlink` — unlinks members with a snapshot event then
///      soft-deletes the source; skips the snapshot event when displayed
///      clamps to 0; no-op when the source is missing or already deleted.
///   4. `computeTaskDeletionImpact` — enumerates counter members for a
///      source task; reports zero for a non-source task.
///
/// Each test spins up its own in-memory `AppDatabase.makeTestInstance()`
/// (full migration chain).
final class CounterOpsTests: XCTestCase {

    // MARK: - Fixtures

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

    private let now = "2026-07-16T10:00:00.000Z"

    /// A counter SOURCE task (isCounter, no sharedCounterId).
    private func makeSourceTask(
        id: String,
        userId: String = "u1",
        currentCount: Int = 40,
        isCounter: Bool = true,
        isDeleted: Bool = false
    ) -> Task {
        Task(
            id: id,
            userId: userId,
            title: "Push-ups (reps)",
            type: .counting,
            action: "Push-ups",
            unit: "reps",
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: currentCount,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: isDeleted,
            isCounter: isCounter
        )
    }

    /// A derived member linked to `sourceId`.
    private func makeMemberTask(
        id: String = "member1",
        sourceId: String,
        baseline: Int = 10,
        maxCount: Int = 50,
        userId: String = "u1"
    ) -> Task {
        Task(
            id: id,
            userId: userId,
            title: "Push-ups goal",
            type: .counting,
            action: "Push-ups",
            unit: "reps",
            maxCount: maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            sharedCounterId: sourceId,
            baseline: baseline,
            isCounter: false
        )
    }

    private func makeStandaloneCountingTask(id: String = "standalone1", userId: String = "u1", isDeleted: Bool = false) -> Task {
        Task(
            id: id,
            userId: userId,
            title: "Push-ups 100 reps",
            type: .counting,
            action: "Push-ups",
            unit: "reps",
            maxCount: 100,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: isDeleted,
            isCounter: false
        )
    }

    // MARK: - createCounterTask

    func test_createCounterTask_writesTaskAndSeedEventAtomically() throws {
        let db = try makeDb()
        try seedUser(db)

        let t = try db.createCounterTask(userId: "u1", action: "Push-ups", unit: "reps", startingCount: 500, now: now)

        XCTAssertTrue(t.isCounter)
        XCTAssertNil(t.maxCount)
        XCTAssertEqual(t.title, "Push-ups (reps)")
        XCTAssertEqual(t.currentCount, 500)
        XCTAssertEqual(t.type, .counting)

        let persisted = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: t.id) })
        XCTAssertEqual(persisted.currentCount, 500)

        let events = try db.read { try TaskEvent.filter(Column("taskId") == t.id).fetchAll($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].delta, 500)
        XCTAssertEqual(events[0].occurredAt, TaskEvents.seedEventOccurredAt)
        XCTAssertEqual(events[0].kind, .increment)

        let queued = try db.read {
            try SyncQueueItem.filter(Column("entityId") == t.id).fetchAll($0)
        }
        XCTAssertFalse(queued.isEmpty)
    }

    func test_createCounterTask_withoutStartingCount_writesNoSeedEventAndCountZero() throws {
        let db = try makeDb()
        try seedUser(db)

        let t = try db.createCounterTask(userId: "u1", action: "Read", unit: "pages", startingCount: nil, now: now)

        XCTAssertEqual(t.currentCount, 0)
        XCTAssertEqual(t.title, "Read (pages)")

        let events = try db.read { try TaskEvent.filter(Column("taskId") == t.id).fetchAll($0) }
        XCTAssertTrue(events.isEmpty)
    }

    func test_createCounterTask_rejectsBlankActionOrUnit() throws {
        let db = try makeDb()
        try seedUser(db)

        XCTAssertThrowsError(
            try db.createCounterTask(userId: "u1", action: "  ", unit: "reps", startingCount: nil, now: now)
        )
        XCTAssertThrowsError(
            try db.createCounterTask(userId: "u1", action: "Push-ups", unit: "", startingCount: nil, now: now)
        )
    }

    func test_createCounterTask_rejectsNegativeStartingCount() throws {
        let db = try makeDb()
        try seedUser(db)

        XCTAssertThrowsError(
            try db.createCounterTask(userId: "u1", action: "Push-ups", unit: "reps", startingCount: -1, now: now)
        )
    }

    // MARK: - promoteTaskToCounter

    func test_promoteTaskToCounter_flagsStandaloneCountingTask() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeStandaloneCountingTask())

        let updated = try db.promoteTaskToCounter(taskId: "standalone1", now: now)

        XCTAssertTrue(updated.isCounter)
        XCTAssertEqual(updated.version, 2)

        let persisted = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "standalone1") })
        XCTAssertTrue(persisted.isCounter)
        XCTAssertEqual(persisted.version, 2)

        let queued = try db.read {
            try SyncQueueItem.filter(Column("entityId") == "standalone1").fetchAll($0)
        }
        XCTAssertFalse(queued.isEmpty)
    }

    func test_promoteTaskToCounter_rejectsDerivedTask() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeSourceTask(id: "src1"))
        try db.saveTask(makeMemberTask(sourceId: "src1"))

        XCTAssertThrowsError(try db.promoteTaskToCounter(taskId: "member1", now: now))
    }

    func test_promoteTaskToCounter_rejectsNonCountingTask() throws {
        let db = try makeDb()
        try seedUser(db)
        let normal = Task(
            id: "normal1",
            userId: "u1",
            title: "Do the dishes",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )
        try db.saveTask(normal)

        XCTAssertThrowsError(try db.promoteTaskToCounter(taskId: "normal1", now: now))
    }

    func test_promoteTaskToCounter_rejectsMissingOrDeletedTask() throws {
        let db = try makeDb()
        try seedUser(db)

        XCTAssertThrowsError(try db.promoteTaskToCounter(taskId: "does-not-exist", now: now))

        try db.saveTask(makeStandaloneCountingTask(id: "deleted1", isDeleted: true))
        XCTAssertThrowsError(try db.promoteTaskToCounter(taskId: "deleted1", now: now))
    }

    // MARK: - deleteCounterWithUnlink

    func test_deleteCounterWithUnlink_unlinksMembersWithSnapshotEventThenSoftDeletesSource() throws {
        let db = try makeDb()
        try seedUser(db)
        // source count 40; member baseline 10, maxCount 50 → displayed = 30
        try db.saveTask(makeSourceTask(id: "src1", currentCount: 40))
        try db.saveTask(makeMemberTask(sourceId: "src1", baseline: 10, maxCount: 50))

        try db.deleteCounterWithUnlink(sourceId: "src1", now: now)

        let member = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "member1") })
        XCTAssertNil(member.sharedCounterId)
        XCTAssertNil(member.baseline)
        XCTAssertEqual(member.currentCount, 30)
        XCTAssertFalse(member.isDeleted)
        XCTAssertEqual(member.version, 2)

        let memberEvents = try db.read { try TaskEvent.filter(Column("taskId") == "member1").fetchAll($0) }
        XCTAssertEqual(memberEvents.count, 1)
        XCTAssertEqual(memberEvents[0].delta, 30)
        XCTAssertNotEqual(memberEvents[0].occurredAt, TaskEvents.seedEventOccurredAt)

        let source = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src1") })
        XCTAssertTrue(source.isDeleted)
    }

    func test_deleteCounterWithUnlink_skipsSnapshotEventWhenDisplayedIsZero() throws {
        let db = try makeDb()
        try seedUser(db)
        // source count 5; member baseline 10 > source count → displayed clamps to 0
        try db.saveTask(makeSourceTask(id: "src2", currentCount: 5))
        try db.saveTask(makeMemberTask(id: "member2", sourceId: "src2", baseline: 10, maxCount: 50))

        try db.deleteCounterWithUnlink(sourceId: "src2", now: now)

        let member = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "member2") })
        XCTAssertEqual(member.currentCount, 0)
        XCTAssertNil(member.sharedCounterId)

        let memberEvents = try db.read { try TaskEvent.filter(Column("taskId") == "member2").fetchAll($0) }
        XCTAssertTrue(memberEvents.isEmpty)
    }

    func test_deleteCounterWithUnlink_isNoOpWhenSourceMissingOrAlreadyDeleted() throws {
        let db = try makeDb()
        try seedUser(db)

        // Missing source: must not throw.
        try db.deleteCounterWithUnlink(sourceId: "does-not-exist", now: now)

        try db.saveTask(makeSourceTask(id: "src3", currentCount: 0, isDeleted: true))
        try db.deleteCounterWithUnlink(sourceId: "src3", now: now)

        let source = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src3") })
        XCTAssertTrue(source.isDeleted)
    }

    // MARK: - computeTaskDeletionImpact — counter members

    func test_computeTaskDeletionImpact_enumeratesCounterMembersForSourceTask() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeSourceTask(id: "src4", currentCount: 40))
        try db.saveTask(makeMemberTask(id: "member3", sourceId: "src4"))

        let impact = try db.computeTaskDeletionImpact(taskId: "src4")

        XCTAssertEqual(impact.counterMemberCount, 1)
        XCTAssertEqual(impact.counterMembers.count, 1)
        XCTAssertEqual(impact.counterMembers.first?.id, "member3")
    }

    func test_computeTaskDeletionImpact_reportsZeroForNonSourceTask() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeStandaloneCountingTask())

        let impact = try db.computeTaskDeletionImpact(taskId: "standalone1")

        XCTAssertEqual(impact.counterMemberCount, 0)
        XCTAssertTrue(impact.counterMembers.isEmpty)
    }
}
