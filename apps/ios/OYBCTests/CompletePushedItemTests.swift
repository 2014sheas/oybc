import XCTest
import GRDB
@testable import OYBC

/// Tests for `AppDatabase.completePushedItem` — the D2 (issue #294) atomic fold
/// of sync-queue completion + shared-counter `lastSyncedCount` advancement.
///
/// The advance used to run as a separate write that swallowed its own failure,
/// silently downgrading the next counter conflict from additive merge to
/// increment-losing LWW. Folding it into the completion write means both land
/// together or neither does.
///
/// Each test constructs its own `AppDatabase.makeTestInstance()` (migrated to
/// the production schema) so they don't share state.
final class CompletePushedItemTests: XCTestCase {

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        let database = try AppDatabase.makeTestInstance()
        try seedUser(database)
        return database
    }

    /// Insert the `users` row the `tasks.userId` foreign key references.
    private func seedUser(_ database: AppDatabase, id: String = "u1") throws {
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
        try database.saveUser(user)
    }

    /// Minimal COUNTING task fixture with an explicit `lastSyncedCount`.
    private func makeCountingTask(
        id: String = "task-1",
        currentCount: Int = 12,
        lastSyncedCount: Int? = 3
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: "u1",
            title: "Push-ups",
            description: nil,
            type: .counting,
            action: "Do",
            unit: "reps",
            maxCount: 20,
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
            isCompleted: false,
            completedAt: nil,
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
            lastSyncedCount: lastSyncedCount,
            createdInWizard: false
        )
    }

    private func makeSyncItem(id: String = UUID().uuidString) -> SyncQueueItem {
        return SyncQueueItem(
            id: id,
            entityType: "tasks",
            entityId: "task-1",
            operationType: .update,
            payload: "{}",
            status: .inProgress,
            retryCount: 0,
            lastError: nil,
            createdAt: AppDatabase.currentTimestamp(),
            lastAttemptAt: nil,
            completedAt: nil,
            priority: 0
        )
    }

    private func fetchItem(_ database: AppDatabase, id: String) throws -> SyncQueueItem? {
        return try database.read { db in try SyncQueueItem.fetchOne(db, key: id) }
    }

    // MARK: - Happy advancement

    func testMarksCompletedAndAdvancesLastSyncedCount() throws {
        let db = try makeDatabase()
        let item = makeSyncItem()
        try db.saveSyncItem(item)
        try db.saveTask(makeCountingTask(currentCount: 12, lastSyncedCount: 3))

        try db.completePushedItem(item, countAdvance: (taskId: "task-1", pushedCount: 12))

        let completed = try fetchItem(db, id: item.id)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertNotNil(completed?.completedAt)

        let task = try db.fetchTask(id: "task-1")
        XCTAssertEqual(task?.lastSyncedCount, 12)
    }

    func testNilAdvanceCompletesWithoutTouchingTasks() throws {
        let db = try makeDatabase()
        var item = makeSyncItem()
        item.entityType = "boards"
        item.entityId = "board-1"
        try db.saveSyncItem(item)

        try db.completePushedItem(item, countAdvance: nil)

        let completed = try fetchItem(db, id: item.id)
        XCTAssertEqual(completed?.status, .completed)
    }

    // MARK: - Degradation path (atomic rollback)

    func testRollsBackBothWritesWhenCountAdvanceFails() throws {
        let db = try makeDatabase()
        let item = makeSyncItem()
        try db.saveSyncItem(item)
        try db.saveTask(makeCountingTask(currentCount: 12, lastSyncedCount: 3))

        struct SyntheticFailure: Error {}

        // Force a mid-transaction failure via the test-only seam: the throw fires
        // after the queue-completion write but before the count advance, so a
        // non-atomic implementation would leave the item completed with a stale
        // lastSyncedCount — the exact silent degradation D2 fixes.
        XCTAssertThrowsError(
            try db.completePushedItem(
                item,
                countAdvance: (taskId: "task-1", pushedCount: 12),
                beforeCountAdvance: { throw SyntheticFailure() }
            )
        )

        // Neither write survived: the item is still inProgress and the ancestor
        // is unchanged. The push loop will mark it FAILED and retry.
        let afterFail = try fetchItem(db, id: item.id)
        XCTAssertEqual(afterFail?.status, .inProgress)
        XCTAssertNil(afterFail?.completedAt)

        let task = try db.fetchTask(id: "task-1")
        XCTAssertEqual(task?.lastSyncedCount, 3)
    }

    // MARK: - Idempotency

    func testDoubleAdvanceIsHarmless() throws {
        let db = try makeDatabase()
        let item = makeSyncItem()
        try db.saveSyncItem(item)
        try db.saveTask(makeCountingTask(currentCount: 12, lastSyncedCount: 3))

        try db.completePushedItem(item, countAdvance: (taskId: "task-1", pushedCount: 12))
        try db.completePushedItem(item, countAdvance: (taskId: "task-1", pushedCount: 12))

        let completed = try fetchItem(db, id: item.id)
        XCTAssertEqual(completed?.status, .completed)

        let task = try db.fetchTask(id: "task-1")
        XCTAssertEqual(task?.lastSyncedCount, 12)
    }
}
