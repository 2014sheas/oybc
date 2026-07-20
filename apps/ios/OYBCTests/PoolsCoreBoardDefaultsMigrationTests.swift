import XCTest
import GRDB
@testable import OYBC

/// Migration-idempotency + shape coverage for GRDB v25 (Task Pools +
/// Recurring Boards Rework, P1; docs/POOLS_RECURRING.md §Migration). Twin
/// of web's Dexie `runMigrationV16` Vitest suite.
///
/// `AppDatabase.makeTestInstance()` runs the FULL migrator (v1...v25)
/// against a fresh, empty in-memory database, so v25 is always a no-op at
/// construction time (there's nothing to migrate yet). To exercise the
/// migration's actual backfill logic, these tests seed legacy-shaped rows
/// (a `DefaultPool`, a `RecurringBoardTemplate` with no `poolIds`) directly
/// against an already-migrated instance, then invoke
/// `MigrationV25Helpers.run` a SECOND time manually — mirroring
/// `SealingTests.swift`'s `sealExpiredBoardsAtMigration` re-invocation
/// pattern. A third invocation proves idempotency (run-twice = no-op).
final class PoolsCoreBoardDefaultsMigrationTests: XCTestCase {

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

    // MARK: - Step 1: DefaultPool → Pool + CoreBoardDefault

    func testMigrateDefaultPools_MintsPoolAndCoreBoardDefault_TombstonesOriginal() throws {
        let db = try makeDb()
        try seedUser(db)

        let dp = try db.upsertDefaultPool(userId: userId, timeframe: .daily, taskIds: ["t1", "t2"])
        let now = AppDatabase.currentTimestamp()
        try db.write { try MigrationV25Helpers.run($0, now: now) }

        // Original DefaultPool is soft-deleted.
        XCTAssertNil(try db.fetchDefaultPool(userId: userId, timeframe: .daily))
        let allDefaultPools = try db.read { try DefaultPool.fetchAll($0) }
        XCTAssertEqual(allDefaultPools.count, 1)
        XCTAssertTrue(allDefaultPools[0].isDeleted)
        XCTAssertEqual(allDefaultPools[0].id, dp.id)

        // A Pool was minted named "Daily default" carrying the same taskIds.
        let pools = try db.fetchPools(userId: userId)
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools[0].name, "Daily default")
        XCTAssertEqual(pools[0].taskIds, ["t1", "t2"])

        // A CoreBoardDefault row exists for .daily, pointing at the minted pool.
        let coreDefault = try XCTUnwrap(try db.fetchCoreBoardDefault(userId: userId, timeframe: .daily))
        XCTAssertEqual(coreDefault.corePoolIds, [pools[0].id])
        XCTAssertEqual(coreDefault.coreDefaultTaskIds, [])

        // Sync rows enqueued for all three writes.
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "pools", op: .create), 1)
        XCTAssertEqual(count(rows, type: "coreBoardDefaults", op: .create), 1)
        XCTAssertEqual(count(rows, type: "defaultPools", op: .delete), 1)
    }

    func testMigrateDefaultPools_RunTwice_IsNoOp() throws {
        let db = try makeDb()
        try seedUser(db)
        _ = try db.upsertDefaultPool(userId: userId, timeframe: .weekly, taskIds: ["a"])
        let now = AppDatabase.currentTimestamp()

        try db.write { try MigrationV25Helpers.run($0, now: now) }
        XCTAssertEqual(try db.fetchPools(userId: userId).count, 1)

        // Second run: the DefaultPool row is already isDeleted, so the
        // migration's `!isDeleted` filter sees nothing to migrate.
        try db.write { try MigrationV25Helpers.run($0, now: now) }
        XCTAssertEqual(try db.fetchPools(userId: userId).count, 1)
        XCTAssertEqual(try db.fetchCoreBoardDefaults(userId: userId).count, 1)
    }

    func testMigrateDefaultPools_MultipleTimeframes_EachGetsOwnPoolAndDefault() throws {
        let db = try makeDb()
        try seedUser(db)
        _ = try db.upsertDefaultPool(userId: userId, timeframe: .daily, taskIds: ["d1"])
        _ = try db.upsertDefaultPool(userId: userId, timeframe: .monthly, taskIds: ["m1", "m2"])
        let now = AppDatabase.currentTimestamp()
        try db.write { try MigrationV25Helpers.run($0, now: now) }

        let pools = try db.fetchPools(userId: userId)
        XCTAssertEqual(Set(pools.map(\.name)), ["Daily default", "Monthly default"])
        XCTAssertEqual(try db.fetchCoreBoardDefaults(userId: userId).count, 2)
    }

    // MARK: - Step 2: RecurringBoardTemplate.seedTaskIds → Pool

    private func makeLegacyTemplate(id: String, name: String, seedTaskIds: [String]) -> RecurringBoardTemplate {
        let now = AppDatabase.currentTimestamp()
        return RecurringBoardTemplate(
            id: id, userId: userId, name: name, timeframe: .weekly, boardSize: 3,
            centerSquareType: .free, isRandomized: false, seedTaskIds: seedTaskIds,
            // poolIds/manualTaskIds/removedTaskIds all default nil — the
            // "genuinely un-migrated" shape the v25 migration targets.
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
    }

    func testMigrateTemplates_SeedTaskIdsExtractedToPool_TemplateStampedWithPoolIds() throws {
        let db = try makeDb()
        try seedUser(db)
        let template = makeLegacyTemplate(id: "tpl-1", name: "Morning Routine", seedTaskIds: ["s1", "s2", "s3"])
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()
        try db.write { try MigrationV25Helpers.run($0, now: now) }

        let pools = try db.fetchPools(userId: userId)
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools[0].name, "Morning Routine pool")
        XCTAssertEqual(pools[0].taskIds, ["s1", "s2", "s3"])

        let updated = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-1"))
        XCTAssertEqual(updated.poolIds, [pools[0].id])
        XCTAssertEqual(updated.manualTaskIds, [])
        XCTAssertEqual(updated.removedTaskIds, [])
        // seedTaskIds left verbatim (decode-compat only, never read live post-migration).
        XCTAssertEqual(updated.seedTaskIds, ["s1", "s2", "s3"])
        XCTAssertEqual(updated.version, template.version + 1)

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "pools", op: .create), 1)
        XCTAssertEqual(count(rows, type: "recurringBoardTemplates", op: .update), 1)
    }

    func testMigrateTemplates_RunTwice_IsNoOp() throws {
        let db = try makeDb()
        try seedUser(db)
        let template = makeLegacyTemplate(id: "tpl-2", name: "Weekly Reset", seedTaskIds: ["a", "b"])
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        try db.write { try MigrationV25Helpers.run($0, now: now) }
        XCTAssertEqual(try db.fetchPools(userId: userId).count, 1)

        // Second run: poolIds is now non-nil, so the migration's
        // `Column("poolIds") == nil` filter sees nothing to migrate.
        try db.write { try MigrationV25Helpers.run($0, now: now) }
        XCTAssertEqual(try db.fetchPools(userId: userId).count, 1)
        let updated = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-2"))
        // Version only bumped once (by the first run).
        XCTAssertEqual(updated.version, template.version + 1)
    }

    func testMigrateTemplates_AlreadyMigratedTemplate_SkippedByPoolIdsFilter() throws {
        // A template already carrying poolIds (e.g. legacy-created via the
        // P1 wizard rewire, or a second-launch scenario) must NOT be
        // re-migrated — its Pool is the shared source of truth and must
        // never be silently overwritten by a second seedTaskIds extraction.
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        let alreadyMigrated = RecurringBoardTemplate(
            id: "tpl-3", userId: userId, name: "Already Migrated", timeframe: .monthly, boardSize: 3,
            centerSquareType: .free, isRandomized: false, seedTaskIds: ["stale"],
            poolIds: ["existing-pool"], manualTaskIds: [], removedTaskIds: [],
            isActive: true, createdAt: now, updatedAt: now, version: 1
        )
        try db.saveRecurringBoardTemplate(alreadyMigrated)
        try db.write { try MigrationV25Helpers.run($0, now: now) }

        // No pool minted — the template's poolIds filter excluded it.
        XCTAssertEqual(try db.fetchPools(userId: userId).count, 0)
        let unchanged = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl-3"))
        XCTAssertEqual(unchanged.poolIds, ["existing-pool"])
        XCTAssertEqual(unchanged.version, 1)
    }

    func testMigrateTemplates_SoftDeletedTemplate_StillMigrated() throws {
        // Deliberately not filtered by isDeleted — matches the doc's
        // unconditional "Each RecurringBoardTemplate →" framing.
        let db = try makeDb()
        try seedUser(db)
        var template = makeLegacyTemplate(id: "tpl-4", name: "Gone", seedTaskIds: ["g1"])
        template.isDeleted = true
        template.deletedAt = AppDatabase.currentTimestamp()
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()
        try db.write { try MigrationV25Helpers.run($0, now: now) }

        XCTAssertEqual(try db.fetchPools(userId: userId).count, 1)
        let updated = try db.fetchRecurringBoardTemplate(id: "tpl-4")
        XCTAssertNotNil(updated?.poolIds)
        XCTAssertTrue(updated?.isDeleted ?? false)
    }

    // MARK: - Combined run idempotency (both steps together)

    func testFullMigration_RunThreeTimes_CountsStable() throws {
        let db = try makeDb()
        try seedUser(db)
        _ = try db.upsertDefaultPool(userId: userId, timeframe: .yearly, taskIds: ["y1"])
        let template = makeLegacyTemplate(id: "tpl-5", name: "Yearly Reset", seedTaskIds: ["r1", "r2"])
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        try db.write { try MigrationV25Helpers.run($0, now: now) }
        let firstRunPoolCount = try db.fetchPools(userId: userId).count
        XCTAssertEqual(firstRunPoolCount, 2) // one from DefaultPool, one from the template

        try db.write { try MigrationV25Helpers.run($0, now: now) }
        try db.write { try MigrationV25Helpers.run($0, now: now) }
        XCTAssertEqual(try db.fetchPools(userId: userId).count, firstRunPoolCount)
        XCTAssertEqual(try db.fetchCoreBoardDefaults(userId: userId).count, 1)
    }

    // MARK: - Sync row helpers (mirror AppDatabaseSyncEnqueueTests' pattern)

    private func syncRows(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.read { try SyncQueueItem.fetchAll($0) }
    }

    private func count(_ rows: [SyncQueueItem], type: String, op: SyncOperationType) -> Int {
        rows.filter { $0.entityType == type && $0.operationType == op }.count
    }
}
