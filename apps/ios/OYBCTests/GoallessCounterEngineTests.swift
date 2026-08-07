import XCTest
import GRDB
@testable import OYBC

/// Tests for the goal-less shared-counter engine (P5 — hub-born counters).
///
/// P5 introduces a `Task.isCounter` flag for hub-born counting tasks that
/// have NO `maxCount` (goal-less accumulators). `incrementSharedCounter`
/// / `decrementSharedCounter` must accept a source with `maxCount == nil`
/// without throwing, and such a source must NEVER auto-complete (there is
/// no threshold to reach). Regular goaled sources must retain the existing
/// latch behavior unchanged.
///
/// Parity target: `apps/web/src/db/operations/__tests__/tasksSharedCounterGoalless.test.ts`.
/// Each test spins up its own `AppDatabase.makeTestInstance()` (in-memory,
/// full migration chain) so tests are isolated and schema-identical to
/// production.
final class GoallessCounterEngineTests: XCTestCase {

    // MARK: - Helpers

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

    /// Goal-less (hub-born) COUNTING source task: `maxCount == nil`,
    /// `isCounter == true`. No `sharedCounterId` → it IS the source.
    private func makeGoallessSourceTask(
        id: String,
        userId: String = "u1",
        currentCount: Int = 0,
        isCompleted: Bool = false,
        completedAt: String? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Push-ups (reps)",
            description: nil,
            type: .counting,
            action: "Push-ups",
            unit: "reps",
            maxCount: nil,
            operatorType: nil,
            threshold: nil,
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
            isCounter: true
        )
    }

    /// Regular goaled COUNTING source task (regression control).
    private func makeGoaledSourceTask(
        id: String,
        userId: String = "u1",
        currentCount: Int = 0,
        maxCount: Int = 5,
        isCompleted: Bool = false
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
            isCounter: false
        )
    }

    // MARK: - 1. Increment a goal-less source

    func test_incrementGoallessSource_doesNotThrow_andNeverAutoCompletes() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoallessSourceTask(id: "src-1", currentCount: 0)
        try db.saveTask(source)

        let result = try db.incrementSharedCounter(sourceTaskId: "src-1", by: 5)
        XCTAssertNotNil(result)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-1") })
        XCTAssertEqual(fetched.currentCount, 5)
        XCTAssertFalse(fetched.isCompleted, "goal-less source must never auto-complete")
    }

    /// Large overshoot still must not complete — there is no threshold at all.
    func test_incrementGoallessSource_largeOvershoot_stillNeverCompletes() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoallessSourceTask(id: "src-overshoot", currentCount: 0)
        try db.saveTask(source)

        _ = try db.incrementSharedCounter(sourceTaskId: "src-overshoot", by: 10_000)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-overshoot") })
        XCTAssertEqual(fetched.currentCount, 10_000)
        XCTAssertFalse(fetched.isCompleted)
    }

    // MARK: - 2. Decrement a goal-less source

    func test_decrementGoallessSource_doesNotThrow() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoallessSourceTask(id: "src-2", currentCount: 3)
        try db.saveTask(source)

        let result = try db.decrementSharedCounter(sourceTaskId: "src-2", by: 2)
        XCTAssertEqual(result.effectiveDelta, 2)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-2") })
        XCTAssertEqual(fetched.currentCount, 1)
    }

    // MARK: - 3. Goaled source latch regression

    /// A regular goaled source must still latch `isCompleted = true` once it
    /// reaches `maxCount` — the goal-less change must not regress this.
    func test_goaledSourceLatch_stillFiresOnIncrement() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoaledSourceTask(id: "src-3", currentCount: 0, maxCount: 5)
        try db.saveTask(source)

        _ = try db.incrementSharedCounter(sourceTaskId: "src-3", by: 5)

        let fetched = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "src-3") })
        XCTAssertTrue(fetched.isCompleted, "goaled source must still latch complete at maxCount (regression)")
    }

    // MARK: - 4. insertIncrementEventRaw honors an occurredAt override

    func test_insertIncrementEventRaw_honorsOccurredAtOverride() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoallessSourceTask(id: "src-4", currentCount: 0)
        try db.saveTask(source)

        let now = AppDatabase.currentTimestamp()
        let seedOccurredAt = "1970-01-01T00:00:00.000Z"

        try db.write { grdb in
            try AppDatabase.insertIncrementEventRaw(
                db: grdb,
                taskId: "src-4",
                delta: 500,
                boardId: nil,
                now: now,
                occurredAt: seedOccurredAt
            )
        }

        let event = try db.read { grdb in
            try TaskEvent.filter(Column("taskId") == "src-4").fetchOne(grdb)
        }
        let unwrapped = try XCTUnwrap(event)
        XCTAssertEqual(unwrapped.occurredAt, seedOccurredAt)
        XCTAssertEqual(unwrapped.createdAt, now)
    }

    /// Omitting `occurredAt` still defaults to `now` (existing call sites unaffected).
    func test_insertIncrementEventRaw_defaultsOccurredAtToNow_whenOmitted() throws {
        let db = try makeDb()
        try seedUser(db)

        let source = makeGoallessSourceTask(id: "src-5", currentCount: 0)
        try db.saveTask(source)

        let now = AppDatabase.currentTimestamp()

        try db.write { grdb in
            try AppDatabase.insertIncrementEventRaw(
                db: grdb,
                taskId: "src-5",
                delta: 3,
                boardId: nil,
                now: now
            )
        }

        let event = try db.read { grdb in
            try TaskEvent.filter(Column("taskId") == "src-5").fetchOne(grdb)
        }
        let unwrapped = try XCTUnwrap(event)
        XCTAssertEqual(unwrapped.occurredAt, now)
    }
}
