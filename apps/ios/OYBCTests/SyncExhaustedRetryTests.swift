import XCTest
import GRDB
@testable import OYBC

/// Tests for the D1 exhausted-item recovery ops on `AppDatabase` (issue #292):
/// `countExhaustedSyncItems` and `retryExhaustedSyncItems`, plus the
/// promote-after-reset behaviour.
///
/// Each test constructs its own in-memory `AppDatabase.makeTestInstance()`
/// so they don't share state. Mirrors the web
/// `exhaustedSyncItems.test.ts` coverage.
final class SyncExhaustedRetryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        return try AppDatabase.makeTestInstance()
    }

    /// Build a SyncQueueItem fixture with the given status / retryCount.
    private func makeSyncItem(
        id: String = UUID().uuidString,
        status: SyncStatus,
        retryCount: Int = 0,
        lastError: String? = nil,
        lastAttemptAt: Date? = nil
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
            lastError: lastError ?? (status == .failed ? "synthetic" : nil),
            createdAt: isoFormatter.string(from: Date()),
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

    // MARK: - countExhaustedSyncItems

    func testCountsOnlyFailedItemsAtOrAboveRetryCap() throws {
        let db = try makeDatabase()
        try db.saveSyncItem(makeSyncItem(id: "exhausted-1", status: .failed, retryCount: SyncRetry.maxRetries))
        try db.saveSyncItem(makeSyncItem(id: "exhausted-2", status: .failed, retryCount: SyncRetry.maxRetries + 2))
        try db.saveSyncItem(makeSyncItem(id: "still-retrying", status: .failed, retryCount: SyncRetry.maxRetries - 1))
        try db.saveSyncItem(makeSyncItem(id: "pending", status: .pending, retryCount: 0))
        try db.saveSyncItem(makeSyncItem(id: "completed", status: .completed, retryCount: SyncRetry.maxRetries))

        XCTAssertEqual(try db.countExhaustedSyncItems(), 2)
    }

    func testCountIsZeroWhenNothingStuck() throws {
        let db = try makeDatabase()
        try db.saveSyncItem(makeSyncItem(id: "below-cap", status: .failed, retryCount: SyncRetry.maxRetries - 1))

        XCTAssertEqual(try db.countExhaustedSyncItems(), 0)
    }

    // MARK: - retryExhaustedSyncItems

    func testResetsExhaustedItemsToFreshPendingAndLeavesOthers() throws {
        let db = try makeDatabase()
        try db.saveSyncItem(makeSyncItem(id: "exhausted-1", status: .failed, retryCount: SyncRetry.maxRetries, lastError: "boom"))
        try db.saveSyncItem(makeSyncItem(id: "still-retrying", status: .failed, retryCount: SyncRetry.maxRetries - 1))

        let reset = try db.retryExhaustedSyncItems()
        XCTAssertEqual(reset, 1)

        let recovered = try fetchItem(db, id: "exhausted-1")
        XCTAssertEqual(recovered?.status, .pending)
        XCTAssertEqual(recovered?.retryCount, 0)
        XCTAssertNil(recovered?.lastError)

        // The under-cap FAILED item is untouched.
        let untouched = try fetchItem(db, id: "still-retrying")
        XCTAssertEqual(untouched?.status, .failed)
        XCTAssertEqual(untouched?.retryCount, SyncRetry.maxRetries - 1)

        XCTAssertEqual(try db.countExhaustedSyncItems(), 0)
    }

    // MARK: - promote-after-reset

    func testResetItemIsEligibleForPromotionAfterAFreshFailure() throws {
        let db = try makeDatabase()
        // An exhausted item: promote refuses it (at the cap).
        try db.saveSyncItem(makeSyncItem(
            id: "reset-me",
            status: .failed,
            retryCount: SyncRetry.maxRetries,
            lastAttemptAt: Date().addingTimeInterval(-24 * 60 * 60)
        ))
        XCTAssertEqual(try db.promoteEligibleFailedSyncItems(), 0, "Capped item must not promote.")

        // Reset it → fresh PENDING, drainable by the push loop.
        XCTAssertEqual(try db.retryExhaustedSyncItems(), 1)
        XCTAssertEqual(try fetchItem(db, id: "reset-me")?.status, .pending)
        XCTAssertEqual(try db.countExhaustedSyncItems(), 0)

        // Simulate the push failing once after the reset (retryCount → 1,
        // attempted long ago). It is now a normal FAILED item again and,
        // being past its first backoff window, is promote-eligible — proving
        // the reset returned it to the normal retry machinery.
        var failedAgain = try XCTUnwrap(fetchItem(db, id: "reset-me"))
        failedAgain.status = .failed
        failedAgain.retryCount = 1
        let iso = ISO8601DateFormatter()
        failedAgain.lastAttemptAt = iso.string(from: Date().addingTimeInterval(-60)) // 60s ago, past 30s window
        try db.saveSyncItem(failedAgain)

        XCTAssertEqual(try db.promoteEligibleFailedSyncItems(), 1, "Reset item should re-enter normal backoff/promotion.")
        XCTAssertEqual(try fetchItem(db, id: "reset-me")?.status, .pending)
    }
}
