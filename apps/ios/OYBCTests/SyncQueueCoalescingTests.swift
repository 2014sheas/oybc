import XCTest
import GRDB
@testable import OYBC

/// Tests for D3 (issue #296): per-entity coalescing of PENDING sync-queue rows.
/// N edits to one entity used to enqueue N full-snapshot rows → N Firestore
/// writes. Now a burst collapses to ONE pending row carrying the LAST snapshot,
/// with the operation type resolved per `SyncQueueBuilder.coalesce`.
///
/// Covers both the pure precedence resolver and the transactional
/// `SyncQueueItem.enqueue(_:)` against a fresh in-memory `AppDatabase`.
final class SyncQueueCoalescingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    /// Enqueue a sync item for `(entityType, entityId)` with the given op and a
    /// payload carrying `marker` (so tests can assert the LAST snapshot won).
    private func enqueue(
        _ db: AppDatabase,
        entityType: String = "tasks",
        entityId: String = "e1",
        op: SyncOperationType,
        marker: String
    ) throws {
        try db.write { grdb in
            try SyncQueueBuilder.makeItem(
                entityType: entityType,
                entityId: entityId,
                operationType: op,
                payload: ["marker": marker],
                now: AppDatabase.currentTimestamp()
            ).enqueue(grdb)
        }
    }

    private func pending(
        _ db: AppDatabase,
        entityType: String = "tasks",
        entityId: String = "e1"
    ) throws -> [SyncQueueItem] {
        try db.read { grdb in
            try SyncQueueItem
                .filter(Column("entityType") == entityType)
                .filter(Column("entityId") == entityId)
                .filter(Column("status") == SyncStatus.pending.rawValue)
                .order(Column("createdAt"))
                .fetchAll(grdb)
        }
    }

    private func allRows(
        _ db: AppDatabase,
        entityType: String = "tasks",
        entityId: String = "e1"
    ) throws -> [SyncQueueItem] {
        try db.read { grdb in
            try SyncQueueItem
                .filter(Column("entityType") == entityType)
                .filter(Column("entityId") == entityId)
                .fetchAll(grdb)
        }
    }

    private func marker(_ item: SyncQueueItem) -> String? {
        guard
            let data = item.payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["marker"] as? String
    }

    // MARK: - Pure precedence

    func test_coalesce_precedenceTable() {
        typealias R = SyncQueueBuilder.CoalesceResult
        func c(
            _ existing: SyncOperationType,
            _ incoming: SyncOperationType,
            neverAttempted: Bool = true
        ) -> R {
            SyncQueueBuilder.coalesce(
                existing: existing,
                incoming: incoming,
                existingNeverAttempted: neverAttempted
            )
        }

        // CREATE row
        XCTAssertEqual(c(.create, .create), R.replace(.create))
        XCTAssertEqual(c(.create, .update), R.replace(.create))
        XCTAssertEqual(c(.create, .delete), R.drop)
        // CREATE row whose push was attempted (its setDoc may have landed):
        // must keep the tombstone, never drop.
        XCTAssertEqual(c(.create, .delete, neverAttempted: false), R.replace(.delete))
        // UPDATE row
        XCTAssertEqual(c(.update, .create), R.replace(.create))
        XCTAssertEqual(c(.update, .update), R.replace(.update))
        XCTAssertEqual(c(.update, .delete), R.replace(.delete))
        // DELETE row (resurrection)
        XCTAssertEqual(c(.delete, .create), R.replace(.create))
        XCTAssertEqual(c(.delete, .update), R.replace(.update))
        XCTAssertEqual(c(.delete, .delete), R.replace(.delete))
    }

    // MARK: - Burst coalescing

    func test_burst_collapsesToOneRowWithLastPayload() throws {
        let db = try makeDb()
        try enqueue(db, op: .update, marker: "v1")
        try enqueue(db, op: .update, marker: "v2")
        try enqueue(db, op: .update, marker: "v3")

        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(marker(rows[0]), "v3")
        XCTAssertEqual(rows[0].operationType, .update)
    }

    func test_replace_keepsOriginalPositionAndId() throws {
        let db = try makeDb()
        try enqueue(db, op: .update, marker: "v1")
        let first = try XCTUnwrap(try pending(db).first)

        try enqueue(db, op: .update, marker: "v2")
        let after = try XCTUnwrap(try pending(db).first)

        XCTAssertEqual(after.id, first.id)
        XCTAssertEqual(after.createdAt, first.createdAt)
        XCTAssertEqual(marker(after), "v2")
    }

    // MARK: - Precedence at the DB layer

    func test_createThenUpdate_staysCreate() throws {
        let db = try makeDb()
        try enqueue(db, op: .create, marker: "v1")
        try enqueue(db, op: .update, marker: "v2")

        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operationType, .create)
        XCTAssertEqual(marker(rows[0]), "v2")
    }

    func test_updateThenDelete_becomesDelete() throws {
        let db = try makeDb()
        try enqueue(db, op: .update, marker: "v1")
        try enqueue(db, op: .delete, marker: "gone")

        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operationType, .delete)
    }

    func test_createThenDelete_dropsRowEntirely() throws {
        let db = try makeDb()
        try enqueue(db, op: .create, marker: "v1")
        try enqueue(db, op: .delete, marker: "gone")

        XCTAssertEqual(try pending(db).count, 0)
        XCTAssertEqual(try allRows(db).count, 0)
    }

    func test_attemptedCreateThenDelete_keepsDeleteTombstone() throws {
        // A pending CREATE whose push was attempted (lastAttemptAt set —
        // e.g. setDoc landed but the completion write failed, then the row
        // was promoted back to pending). The server may hold a live doc, so
        // the delete must be kept as a tombstone rather than dropped.
        let db = try makeDb()
        try db.write { grdb in
            var item = SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: "e1",
                operationType: .create, payload: ["marker": "v1"],
                now: AppDatabase.currentTimestamp()
            )
            item.retryCount = 1
            item.lastAttemptAt = AppDatabase.currentTimestamp()
            try item.save(grdb)
        }

        try enqueue(db, op: .delete, marker: "gone")

        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operationType, .delete)
    }

    func test_replace_preservesLastAttemptAt_soLaterDeleteCannotDrop() throws {
        // Attempted CREATE → an edit (UPDATE) coalesces into it → then a
        // DELETE. The intermediate replace must not erase the attempt
        // evidence, otherwise the delete would wrongly drop the row.
        let db = try makeDb()
        let attemptedAt = AppDatabase.currentTimestamp()
        try db.write { grdb in
            var item = SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: "e1",
                operationType: .create, payload: ["marker": "v1"],
                now: AppDatabase.currentTimestamp()
            )
            item.retryCount = 1
            item.lastAttemptAt = attemptedAt
            try item.save(grdb)
        }

        try enqueue(db, op: .update, marker: "v2")
        let afterUpdate = try XCTUnwrap(try pending(db).first)
        XCTAssertEqual(afterUpdate.lastAttemptAt, attemptedAt)

        try enqueue(db, op: .delete, marker: "gone")
        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operationType, .delete)
    }

    func test_deleteThenCreate_resurrectsAsCreate() throws {
        let db = try makeDb()
        try enqueue(db, op: .delete, marker: "gone")
        try enqueue(db, op: .create, marker: "back")

        let rows = try pending(db)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].operationType, .create)
        XCTAssertEqual(marker(rows[0]), "back")
    }

    // MARK: - Never coalesce across in-progress / failed

    func test_inProgressRow_notCoalesced_appendsNewPending() throws {
        let db = try makeDb()
        try db.write { grdb in
            var item = SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: "e1",
                operationType: .update, payload: ["marker": "v1"],
                now: AppDatabase.currentTimestamp()
            )
            item.status = .inProgress
            try item.save(grdb)
        }

        try enqueue(db, op: .update, marker: "v2")

        let all = try allRows(db)
        XCTAssertEqual(all.count, 2)
        let inflight = try XCTUnwrap(all.first { $0.status == .inProgress })
        XCTAssertEqual(marker(inflight), "v1")
        let pend = try pending(db)
        XCTAssertEqual(pend.count, 1)
        XCTAssertEqual(marker(pend[0]), "v2")
    }

    func test_failedRow_notCoalesced_appendsNewPending() throws {
        let db = try makeDb()
        try db.write { grdb in
            var item = SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: "e1",
                operationType: .update, payload: ["marker": "v1"],
                now: AppDatabase.currentTimestamp()
            )
            item.status = .failed
            item.retryCount = 2
            item.lastError = "boom"
            try item.save(grdb)
        }

        try enqueue(db, op: .update, marker: "v2")

        let all = try allRows(db)
        XCTAssertEqual(all.count, 2)
        let failed = try XCTUnwrap(all.first { $0.status == .failed })
        XCTAssertEqual(failed.retryCount, 2)
        XCTAssertEqual(failed.lastError, "boom")
        let pend = try pending(db)
        XCTAssertEqual(pend.count, 1)
        XCTAssertEqual(marker(pend[0]), "v2")
    }

    // MARK: - Cross-entity isolation

    func test_differentEntities_notCoalesced() throws {
        let db = try makeDb()
        try enqueue(db, entityType: "tasks", entityId: "e1", op: .update, marker: "a")
        try enqueue(db, entityType: "tasks", entityId: "e2", op: .update, marker: "b")
        try enqueue(db, entityType: "boards", entityId: "e1", op: .update, marker: "c")

        XCTAssertEqual(try pending(db, entityType: "tasks", entityId: "e1").count, 1)
        XCTAssertEqual(try pending(db, entityType: "tasks", entityId: "e2").count, 1)
        XCTAssertEqual(try pending(db, entityType: "boards", entityId: "e1").count, 1)
    }
}
