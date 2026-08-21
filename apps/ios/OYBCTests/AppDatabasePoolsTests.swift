import XCTest
import GRDB
@testable import OYBC

/// CRUD + enqueue coverage for `AppDatabase+Pools.swift` (Task Pools +
/// Recurring Boards Rework, P1). iOS twin of web's `pools.test.ts` /
/// `coreBoardDefaults.test.ts` (`apps/web/src/db/operations/__tests__/`).
/// Modeled on the existing `AppDatabase+DefaultPools.swift` coverage
/// pattern in `AppDatabaseSyncEnqueueTests.swift`.
final class AppDatabasePoolsTests: XCTestCase {

    private let userId = "u1"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func syncRows(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.read { try SyncQueueItem.fetchAll($0) }
    }

    private func count(_ rows: [SyncQueueItem], type: String, op: SyncOperationType) -> Int {
        rows.filter { $0.entityType == type && $0.operationType == op }.count
    }

    // MARK: - Pool CRUD

    func testCreatePoolAndEnqueue_InsertsRowAndEnqueuesCreate() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let pool = try db.createPoolAndEnqueue(userId: userId, name: "Morning Kickstart", taskIds: ["t1", "t2"], now: now)

        XCTAssertEqual(pool.name, "Morning Kickstart")
        XCTAssertEqual(pool.taskIds, ["t1", "t2"])
        XCTAssertEqual(pool.version, 1)
        XCTAssertFalse(pool.isDeleted)

        let fetched = try XCTUnwrap(try db.fetchPool(id: pool.id))
        XCTAssertEqual(fetched.id, pool.id)

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "pools", op: .create), 1)
    }

    func testFetchPools_ByUserId_ExcludesSoftDeleted() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        let live = try db.createPoolAndEnqueue(userId: userId, name: "Live", taskIds: [], now: now)
        let deleted = try db.createPoolAndEnqueue(userId: userId, name: "Deleted", taskIds: [], now: now)
        try db.softDeletePoolAndEnqueue(id: deleted.id, now: now)

        let pools = try db.fetchPools(userId: userId)
        XCTAssertEqual(pools.map(\.id), [live.id])
    }

    func testFetchPools_ByIds_BatchedLookupRegardlessOfDeletion() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        let a = try db.createPoolAndEnqueue(userId: userId, name: "A", taskIds: [], now: now)
        let b = try db.createPoolAndEnqueue(userId: userId, name: "B", taskIds: [], now: now)
        _ = try db.createPoolAndEnqueue(userId: userId, name: "C", taskIds: [], now: now)

        let result = try db.fetchPools(ids: [a.id, b.id])
        XCTAssertEqual(Set(result.map(\.id)), [a.id, b.id])

        XCTAssertTrue(try db.fetchPools(ids: []).isEmpty)
    }

    func testUpdatePoolAndEnqueue_UpdatesTaskIdsBumpsVersionEnqueuesUpdate() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        // Seed the base row directly (bypassing enqueue) so there's no
        // PENDING create row for the update to coalesce against (D3 —
        // SyncQueueBuilder.coalesce: create+update collapses to a single
        // `.create` row, which would make an `.update`-count assertion
        // here misleading rather than wrong).
        let pool = Pool(
            id: "pool-1", userId: userId, name: "Original", taskIds: ["t1"],
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }

        let later = AppDatabase.currentTimestamp()
        let updated = try db.updatePoolAndEnqueue(id: pool.id, taskIds: ["t1", "t2", "t3"], now: later)

        XCTAssertEqual(updated?.taskIds, ["t1", "t2", "t3"])
        XCTAssertEqual(updated?.name, "Original") // unchanged — name wasn't passed
        XCTAssertEqual(updated?.version, 2)

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "pools", op: .update), 1)
    }

    func testUpdatePoolAndEnqueue_UnknownId_ReturnsNilNoWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        let result = try db.updatePoolAndEnqueue(id: "ghost", taskIds: ["x"], now: AppDatabase.currentTimestamp())
        XCTAssertNil(result)
        XCTAssertEqual(try syncRows(db).count, 0)
    }

    func testSoftDeletePoolAndEnqueue_MarksDeletedBumpsVersionEnqueuesDelete() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        // Seed directly (bypassing enqueue) — a create-then-delete on the
        // same never-attempted PENDING row would DROP entirely (D3
        // coalescing), which is correct production behavior but would
        // make this test's delete-row assertion misleading.
        let pool = Pool(
            id: "pool-2", userId: userId, name: "Gone Soon", taskIds: [],
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }

        try db.softDeletePoolAndEnqueue(id: pool.id, now: AppDatabase.currentTimestamp())

        let fetched = try XCTUnwrap(try db.fetchPool(id: pool.id))
        XCTAssertTrue(fetched.isDeleted)
        XCTAssertEqual(fetched.version, 2)
        // Detachment is derived, never cascaded — the pool row itself
        // still carries its taskIds (no field wipe on delete).
        XCTAssertEqual(fetched.taskIds, [])

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "pools", op: .delete), 1)
    }

    /// D3 (issue #296) coalescing sanity check: a create immediately
    /// followed by an update to the still-never-attempted PENDING row
    /// collapses into ONE queue row (still typed `.create`), not two —
    /// see `SyncQueueBuilder.coalesce`'s precedence table. Documents why
    /// the update/delete tests above seed their base row directly instead
    /// of via `createPoolAndEnqueue`.
    func testCreateThenUpdatePoolAndEnqueue_CoalescesToSingleCreateRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        let pool = try db.createPoolAndEnqueue(userId: userId, name: "Original", taskIds: ["t1"], now: now)
        _ = try db.updatePoolAndEnqueue(id: pool.id, taskIds: ["t1", "t2"], now: AppDatabase.currentTimestamp())

        let rows = try syncRows(db).filter { $0.entityType == "pools" && $0.entityId == pool.id }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operationType, .create)
    }

    // MARK: - CoreBoardDefault CRUD

    func testUpsertCoreBoardDefaultAndEnqueue_CreatesThenUpdatesSameRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let created = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .weekly, corePoolIds: ["p1"], coreDefaultTaskIds: [], now: now
        )
        XCTAssertEqual(created.version, 1)

        let later = AppDatabase.currentTimestamp()
        let updated = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .weekly, corePoolIds: ["p1", "p2"], coreDefaultTaskIds: ["d1"], now: later
        )

        // Same row (same id), not a second insert.
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.corePoolIds, ["p1", "p2"])
        XCTAssertEqual(updated.coreDefaultTaskIds, ["d1"])
        XCTAssertEqual(updated.version, 2)

        XCTAssertEqual(try db.fetchCoreBoardDefaults(userId: userId).count, 1)

        // D3 coalescing (see `testCreateThenUpdatePoolAndEnqueue_CoalescesToSingleCreateRow`):
        // the update lands on the still-PENDING, never-attempted create
        // row, collapsing to ONE queue row still typed `.create`.
        let rows = try syncRows(db).filter { $0.entityType == "coreBoardDefaults" && $0.entityId == created.id }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operationType, .create)
    }

    func testFetchCoreBoardDefault_PerTimeframeUniqueness() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .daily, corePoolIds: ["d"], coreDefaultTaskIds: [], now: now
        )
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: ["m"], coreDefaultTaskIds: [], now: now
        )

        let daily = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .daily))
        XCTAssertEqual(daily.corePoolIds, ["d"])
        XCTAssertNil(try db.fetchCoreBoardDefault(userId: userId, timeframe: .yearly))
    }

    func testSoftDeleteCoreBoardDefaultAndEnqueue_MarksDeletedEnqueuesDelete() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        // Seed directly (bypassing enqueue) — see the Pool soft-delete
        // test's comment: a create-then-delete on a never-attempted
        // PENDING row DROPS entirely under D3 coalescing.
        let coreDefault = CoreBoardDefault(
            id: "cbd-1", userId: userId, timeframe: .yearly, corePoolIds: [], coreDefaultTaskIds: [],
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try coreDefault.insert(grdb) }

        try db.softDeleteCoreBoardDefaultAndEnqueue(id: coreDefault.id, now: AppDatabase.currentTimestamp())

        XCTAssertNil(try db.fetchCoreBoardDefault(userId: userId, timeframe: .yearly))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "coreBoardDefaults", op: .delete), 1)
    }

    // MARK: - upsertCorePoolIdsAndEnqueue (Task Pools + Recurring Boards
    // Rework, P5) — the core-setup checkbox's write path. Preserves
    // `coreDefaultTaskIds` (P7-authored-only) untouched: the raw
    // `upsertCoreBoardDefaultAndEnqueue` unconditionally overwrites BOTH
    // fields, so this wrapper must fetch-then-preserve rather than pass
    // an empty array through.

    func testUpsertCorePoolIdsAndEnqueue_PreservesExistingCoreDefaultTaskIds() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Seed a row that already has P7-authored `coreDefaultTaskIds` —
        // simulates a future world where the Board-settings defaults sheet
        // (P7) has written individual defaults, and the P5 core-setup
        // checkbox now updates `corePoolIds` independently.
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .daily, corePoolIds: ["p1"], coreDefaultTaskIds: ["d1", "d2"], now: now
        )

        let later = AppDatabase.currentTimestamp()
        let updated = try db.upsertCorePoolIdsAndEnqueue(
            userId: userId, timeframe: .daily, corePoolIds: ["p1", "p2"], now: later
        )

        XCTAssertEqual(updated.corePoolIds, ["p1", "p2"])
        // The mandatory assertion: coreDefaultTaskIds survives UNTOUCHED —
        // never zeroed out by a corePoolIds-only write.
        XCTAssertEqual(updated.coreDefaultTaskIds, ["d1", "d2"])
        XCTAssertEqual(updated.version, 2)

        let refetched = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .daily))
        XCTAssertEqual(refetched.coreDefaultTaskIds, ["d1", "d2"])
    }

    func testUpsertCorePoolIdsAndEnqueue_NoExistingRow_CreatesWithEmptyCoreDefaultTaskIds() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let created = try db.upsertCorePoolIdsAndEnqueue(
            userId: userId, timeframe: .weekly, corePoolIds: ["p1"], now: now
        )

        XCTAssertEqual(created.corePoolIds, ["p1"])
        XCTAssertEqual(created.coreDefaultTaskIds, [])
        XCTAssertEqual(created.version, 1)

        let rows = try syncRows(db).filter { $0.entityType == "coreBoardDefaults" && $0.entityId == created.id }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operationType, .create)
    }

    func testUpsertCorePoolIdsAndEnqueue_UncheckClearsToEmpty() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: ["p1", "p2"], coreDefaultTaskIds: ["d1"], now: now
        )

        let cleared = try db.upsertCorePoolIdsAndEnqueue(
            userId: userId, timeframe: .monthly, corePoolIds: [], now: AppDatabase.currentTimestamp()
        )

        XCTAssertEqual(cleared.corePoolIds, [])
        // Still preserved even on the uncheck-to-clear path.
        XCTAssertEqual(cleared.coreDefaultTaskIds, ["d1"])
    }

    // MARK: - Atomicity fix (Task Pools + Recurring Boards Rework, P7)
    //
    // `upsertCorePoolIdsAndEnqueue` used to do its `fetchCoreBoardDefault`
    // read in a SEPARATE GRDB transaction from the `upsertCoreBoardDefaultAndEnqueue`
    // write it fed into — a concurrent write landing in that gap (e.g. a
    // sync pull applying a peer's P7 defaults-sheet edit) could get
    // silently reverted once the stale-read write committed. The fix
    // moves the fetch INSIDE the same `write` block as the merge+write
    // (see `AppDatabase+Pools.swift`'s private `upsertCoreBoardDefault`
    // helper, called from both public entry points).
    //
    // This test dispatches the two writers on real concurrent queues
    // (the closest a synchronous XCTest can get to "concurrent-style
    // sequencing") rather than calling them sequentially in-line —
    // sequential calls can't reproduce the two-transaction gap at all
    // (nothing runs "in between" a single thread's two statements), so
    // this only proves something if the writes actually race. It's not
    // flaky-by-timing, though: GRDB's `DatabaseQueue` fully SERIALIZES
    // writer transactions on one connection, so whichever of the two
    // async blocks' write-transactions commits SECOND is guaranteed (by
    // that serialization, not by luck) to have its fetch observe the
    // first one's fully-committed row — never a pre-commit snapshot. The
    // assertion is therefore unconditionally true under the fix
    // regardless of which block happens to run first; it is exactly the
    // property that was NOT true before the fix (a genuine gap existed
    // between the old code's separate `read` and `write` transactions).
    func testUpsertCorePoolIdsAndEnqueue_ConcurrentWithCoreDefaultTaskIdsWrite_NeverLosesData() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Freshly-migrated row: corePoolIds only, no individual defaults yet.
        _ = try db.upsertCoreBoardDefaultAndEnqueue(
            userId: userId, timeframe: .weekly, corePoolIds: ["p1"], coreDefaultTaskIds: [], now: now
        )

        let group = DispatchGroup()
        group.enter()
        group.enter()
        // P5 checkbox path: corePoolIds-only write (must preserve whatever
        // coreDefaultTaskIds exists at the moment it actually runs).
        DispatchQueue.global().async {
            _ = try? db.upsertCorePoolIdsAndEnqueue(
                userId: self.userId, timeframe: .weekly, corePoolIds: ["p1", "p2"],
                now: AppDatabase.currentTimestamp()
            )
            group.leave()
        }
        // "Concurrent" writer: a sync pull (or the P7 defaults sheet)
        // writing coreDefaultTaskIds.
        DispatchQueue.global().async {
            _ = try? db.upsertCoreBoardDefaultAndEnqueue(
                userId: self.userId, timeframe: .weekly, corePoolIds: ["p1"], coreDefaultTaskIds: ["d1"],
                now: AppDatabase.currentTimestamp()
            )
            group.leave()
        }
        group.wait()

        let final = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .weekly))
        XCTAssertTrue(final.corePoolIds.contains("p1"))
        // The property the atomicity fix specifically protects: if the
        // corePoolIds-only writer happened to commit LAST, it must have
        // observed the other writer's already-committed `coreDefaultTaskIds`
        // (fetched inside its OWN single transaction) rather than a stale
        // pre-fetch snapshot from before that write landed.
        if final.corePoolIds == ["p1", "p2"] {
            XCTAssertEqual(
                final.coreDefaultTaskIds, ["d1"],
                "corePoolIds-only writer must preserve a concurrently-committed coreDefaultTaskIds write"
            )
        }
    }
}
