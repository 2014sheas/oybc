import XCTest
import GRDB
@testable import OYBC

/// Tests for the sync-queue maintenance operations on `AppDatabase` —
/// `promoteEligibleFailedSyncItems`, `resetStaleInProgressSyncItems`,
/// and the preference-write `updateUserPreferences` flow.
///
/// Each test method constructs its own `AppDatabase.makeTestInstance()`
/// so they don't share state. The migrator runs through to v5 inside
/// the factory, so the schema matches production.
final class SyncQueueMaintenanceTests: XCTestCase {

    // MARK: - Helpers

    /// Spin up a fresh in-memory database. Each test gets its own.
    private func makeDatabase() throws -> AppDatabase {
        return try AppDatabase.makeTestInstance()
    }

    /// Insert a User row matching what `AuthService.upsertLocalUser`
    /// would produce on first sign-in. Some operations (notably
    /// `updateUserPreferences`) only do work when the row exists.
    private func seedUser(_ database: AppDatabase, id: String = "user-test-1") throws {
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

    /// Build a SyncQueueItem fixture with the given status / retryCount /
    /// lastAttemptAt. Defaults match the shape `addToSyncQueue` would
    /// produce for a synthetic test row.
    private func makeSyncItem(
        id: String = UUID().uuidString,
        status: SyncStatus,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil,
        createdAt: Date = Date()
    ) -> SyncQueueItem {
        let isoFormatter = ISO8601DateFormatter()
        return SyncQueueItem(
            id: id,
            entityType: "tasks",
            entityId: "fake-entity-\(id)",
            operationType: .update,
            payload: "{}",
            status: status,
            retryCount: retryCount,
            lastError: status == .failed ? "synthetic" : nil,
            createdAt: isoFormatter.string(from: createdAt),
            lastAttemptAt: lastAttemptAt.map { isoFormatter.string(from: $0) },
            completedAt: nil,
            priority: 0
        )
    }

    private func fetchItem(_ database: AppDatabase, id: String) throws -> SyncQueueItem? {
        return try database.read { db in
            try SyncQueueItem.fetchOne(db, key: id)
        }
    }

    // MARK: - promoteEligibleFailedSyncItems

    func testPromotesFailedItemPastBackoffWindow() throws {
        let db = try makeDatabase()
        let id = "promote-eligible"
        let item = makeSyncItem(
            id: id,
            status: .failed,
            retryCount: 1,
            lastAttemptAt: Date().addingTimeInterval(-31) // 31s ago: past 30s first-retry window
        )
        try db.saveSyncItem(item)

        let promoted = try db.promoteEligibleFailedSyncItems()
        XCTAssertEqual(promoted, 1, "Eligible item should be promoted.")

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .pending)
        XCTAssertNil(after?.lastError, "Promotion should clear the previous error so it doesn't stick around stale.")
    }

    func testDoesNotPromoteFailedItemInsideBackoffWindow() throws {
        let db = try makeDatabase()
        let id = "promote-not-yet"
        let item = makeSyncItem(
            id: id,
            status: .failed,
            retryCount: 1,
            lastAttemptAt: Date().addingTimeInterval(-5) // 5s ago: well under 30s window
        )
        try db.saveSyncItem(item)

        let promoted = try db.promoteEligibleFailedSyncItems()
        XCTAssertEqual(promoted, 0)

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .failed)
    }

    func testNeverPromotesItemAtOrAboveRetryCap() throws {
        let db = try makeDatabase()
        let id = "promote-capped"
        // retryCount at the cap (5), with lastAttemptAt very long ago.
        // Even with infinite elapsed time, a capped item should never be
        // re-promoted — it requires a fresh enqueue or manual retry.
        let item = makeSyncItem(
            id: id,
            status: .failed,
            retryCount: SyncRetry.maxRetries,
            lastAttemptAt: Date().addingTimeInterval(-24 * 60 * 60) // 1 day ago
        )
        try db.saveSyncItem(item)

        let promoted = try db.promoteEligibleFailedSyncItems()
        XCTAssertEqual(promoted, 0)

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .failed)
        XCTAssertEqual(after?.retryCount, SyncRetry.maxRetries)
    }

    // MARK: - resetStaleInProgressSyncItems

    func testResetsInProgressItemOlderThanThreshold() throws {
        let db = try makeDatabase()
        let id = "in-progress-stale"
        let item = makeSyncItem(
            id: id,
            status: .inProgress,
            lastAttemptAt: Date().addingTimeInterval(-90) // 90s ago: past default 60s threshold
        )
        try db.saveSyncItem(item)

        let resetCount = try db.resetStaleInProgressSyncItems()
        XCTAssertEqual(resetCount, 1)

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .pending)
    }

    func testDoesNotResetRecentlyAttemptedInProgressItem() throws {
        let db = try makeDatabase()
        let id = "in-progress-fresh"
        let item = makeSyncItem(
            id: id,
            status: .inProgress,
            lastAttemptAt: Date().addingTimeInterval(-5) // 5s ago: well under 60s threshold
        )
        try db.saveSyncItem(item)

        let resetCount = try db.resetStaleInProgressSyncItems()
        XCTAssertEqual(resetCount, 0, "Recent IN_PROGRESS items must not be yanked from an active push.")

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .inProgress)
    }

    func testResetsInProgressItemWithNoLastAttemptTimestamp() throws {
        let db = try makeDatabase()
        let id = "in-progress-no-attempt"
        // Items that somehow ended up IN_PROGRESS without a
        // `lastAttemptAt` (legacy / direct-write) should be treated as
        // stale — there's no evidence they're actively being processed.
        let item = makeSyncItem(id: id, status: .inProgress, lastAttemptAt: nil)
        try db.saveSyncItem(item)

        let resetCount = try db.resetStaleInProgressSyncItems()
        XCTAssertEqual(resetCount, 1)

        let after = try fetchItem(db, id: id)
        XCTAssertEqual(after?.status, .pending)
    }

    // MARK: - updateUserPreferences

    func testUpdateUserPreferencesBumpsVersionAndEnqueuesSyncItem() throws {
        let db = try makeDatabase()
        let userId = "user-prefs-test"
        try seedUser(db, id: userId)

        let originalUser = try db.fetchUser(id: userId)
        let originalVersion = originalUser?.version ?? 0

        let updatedUser = try db.updateUserPreferences(userId: userId) { current in
            var next = current
            next.theme = .dark
            next.weekStartDay = .sunday
            return next
        }

        // Returned User reflects the change. Version bumping is the
        // real conflict-resolution invariant sync relies on; the
        // `updatedAt` field is also rewritten but at whole-second ISO
        // resolution so a seed + update within the same real second
        // produces the same string (fine in production — users don't
        // make preference writes microseconds apart — but flaky to
        // assert on in a back-to-back test).
        XCTAssertNotNil(updatedUser)
        XCTAssertEqual(updatedUser?.version, originalVersion + 1)
        XCTAssertFalse(updatedUser?.updatedAt.isEmpty ?? true, "updatedAt must be non-empty after a preference write.")
        let prefs = updatedUser?.decodedPreferences
        XCTAssertEqual(prefs?.theme, .dark)
        XCTAssertEqual(prefs?.weekStartDay, .sunday)

        // A SyncQueueItem of type `users` was enqueued in the same
        // transaction.
        let queueItems = try db.read { db in
            try SyncQueueItem
                .filter(Column("entityType") == "users")
                .filter(Column("entityId") == userId)
                .fetchAll(db)
        }
        XCTAssertEqual(queueItems.count, 1, "Exactly one queue entry should be created per call.")
        XCTAssertEqual(queueItems.first?.operationType, .update)
        XCTAssertEqual(queueItems.first?.status, .pending)

        // Payload should be parseable JSON containing the new prefs.
        // `XCTUnwrap` produces a readable failure and skips the rest of
        // the test body; force-unwrapping after `XCTAssertNotNil` would
        // crash the whole test run and obscure the actual failure.
        let payloadData = try XCTUnwrap(
            queueItems.first?.payload.data(using: .utf8),
            "Expected the enqueued sync item to carry a UTF-8 payload."
        )
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
            "Payload must be a JSON object."
        )
        XCTAssertNotNil(parsed["preferences"], "Payload must include the preferences object so the remote write applies them.")
    }

    func testUpdateUserPreferencesIsNoOpForUnknownUser() throws {
        let db = try makeDatabase()
        // Don't seed any user.

        let result = try db.updateUserPreferences(userId: "does-not-exist") { current in
            var next = current
            next.theme = .dark
            return next
        }

        XCTAssertNil(result, "Updating prefs for a missing user must return nil rather than creating a row.")

        let queueItems = try db.read { db in
            try SyncQueueItem.fetchAll(db)
        }
        XCTAssertTrue(queueItems.isEmpty, "Missing-user update must not enqueue a sync item against a non-existent row.")
    }
}
