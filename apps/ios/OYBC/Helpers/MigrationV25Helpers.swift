import Foundation
import GRDB

/// First-launch data-migration helpers for GRDB v25 (Task Pools +
/// Recurring Boards Rework, P1; docs/POOLS_RECURRING.md §Migration). Twin
/// of web's Dexie `runMigrationV16` (`apps/web/src/db/operations/migrationV16.ts`).
/// See `AppDatabase.swift`'s v25 registration for the full design
/// rationale; this file holds the implementation so the migrator closure
/// stays short (mirrors `MigrationV7Helpers.swift`'s split).
///
/// Both steps below are idempotent by construction (state-based — no
/// separate "migration completed" marker table), matching the
/// `v20`/`v22` Windowed Completion backfill precedent:
///
///   1. `migrateDefaultPools` only reads `!isDeleted` `DefaultPool` rows.
///      A second run sees every row already soft-deleted by the first
///      run, so it does nothing.
///   2. `migrateRecurringBoardTemplates` only reads templates where
///      `poolIds IS NULL`. A second run sees every row already stamped
///      with a `poolIds` array (this migration always stamps a length-1
///      array) by the first run, so it does nothing.
enum MigrationV25Helpers {

    static func run(_ db: Database, now: String) throws {
        try migrateDefaultPools(db, now: now)
        try migrateRecurringBoardTemplates(db, now: now)
    }

    /// "<Timeframe> default" pool-naming label. `DefaultPool`/
    /// `CoreBoardDefault` both exclude `.custom`/`.indefinite` at the
    /// write-helper layer, so those two are unreachable here — included
    /// only so the map is total over `Timeframe` (exhaustiveness), mirroring
    /// web's `TIMEFRAME_DEFAULT_LABEL`.
    private static let timeframeDefaultLabel: [Timeframe: String] = [
        .daily: "Daily",
        .weekly: "Weekly",
        .monthly: "Monthly",
        .yearly: "Yearly",
        .custom: "Custom",
        .indefinite: "Ongoing",
    ]

    /// Step 1: each non-deleted `DefaultPool` row → a `Pool` named
    /// "<Timeframe> default" + a `CoreBoardDefault` row for that timeframe
    /// with `corePoolIds: [newPool.id]`, `coreDefaultTaskIds: []`. The
    /// `DefaultPool` row is then soft-deleted (tombstone drains to
    /// Firestore via the push path; `defaultPools` joins
    /// `legacyPullSkipCollections` in SyncService.swift).
    private static func migrateDefaultPools(_ db: Database, now: String) throws {
        let defaultPools = try DefaultPool
            .filter(Column("isDeleted") == false)
            .fetchAll(db)

        for dp in defaultPools {
            let label = timeframeDefaultLabel[dp.timeframe] ?? dp.timeframe.rawValue
            let pool = Pool(
                id: AppDatabase.generateUUID(),
                userId: dp.userId,
                name: "\(label) default",
                taskIds: dp.taskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            let coreDefault = CoreBoardDefault(
                id: AppDatabase.generateUUID(),
                userId: dp.userId,
                timeframe: dp.timeframe,
                corePoolIds: [pool.id],
                coreDefaultTaskIds: [],
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )

            try pool.insert(db)
            try coreDefault.insert(db)

            var tombstone = dp
            tombstone.isDeleted = true
            tombstone.deletedAt = now
            tombstone.updatedAt = now
            tombstone.version += 1
            try tombstone.update(db)

            try enqueueMigrationSync(
                db, entityType: "pools", entityId: pool.id,
                operationType: .create, payload: pool, now: now
            )
            try enqueueMigrationSync(
                db, entityType: "coreBoardDefaults", entityId: coreDefault.id,
                operationType: .create, payload: coreDefault, now: now
            )
            try enqueueMigrationSync(
                db, entityType: "defaultPools", entityId: tombstone.id,
                operationType: .delete, payload: tombstone, now: now
            )
        }
    }

    /// Step 2: each `RecurringBoardTemplate` whose `poolIds` column IS
    /// NULL (the "genuinely un-migrated" half of
    /// `PoolMix.isLegacyShapedRecord`'s two cases) has its `seedTaskIds`
    /// extracted into a `Pool` named "<template name> pool"; the template
    /// is stamped with `poolIds: [newPool.id]`, `manualTaskIds: []`,
    /// `removedTaskIds: []`. `seedTaskIds` itself is left VERBATIM
    /// (decode-compat, the `lastSyncedCount` precedent) and is never read
    /// live post-migration. Deliberately not filtered by `isDeleted` —
    /// every `RecurringBoardTemplate` row gets its `seedTaskIds` carried
    /// forward, matching the doc's unconditional "Each
    /// RecurringBoardTemplate →" framing (an already-deleted template's
    /// minted pool is simply inert, same as the template itself).
    private static func migrateRecurringBoardTemplates(_ db: Database, now: String) throws {
        let templates = try RecurringBoardTemplate
            .filter(Column("poolIds") == nil)
            .fetchAll(db)

        for template in templates {
            let pool = Pool(
                id: AppDatabase.generateUUID(),
                userId: template.userId,
                name: "\(template.name) pool",
                taskIds: template.seedTaskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try pool.insert(db)

            var updated = template
            updated.poolIds = [pool.id]
            updated.manualTaskIds = []
            updated.removedTaskIds = []
            updated.updatedAt = now
            updated.version += 1
            try updated.update(db)

            try enqueueMigrationSync(
                db, entityType: "pools", entityId: pool.id,
                operationType: .create, payload: pool, now: now
            )
            try enqueueMigrationSync(
                db, entityType: "recurringBoardTemplates", entityId: updated.id,
                operationType: .update, payload: updated, now: now
            )
        }
    }

    /// Enqueue a sync-queue row directly via raw SQL — mirrors
    /// `v14`/`v20`'s migration-tx-local sync inserts. The migration owns
    /// its own transaction, and every row minted here is a brand-new id
    /// with no pre-existing PENDING row to coalesce against, so
    /// `SyncQueueBuilder`'s coalescing `enqueue(db)` machinery isn't
    /// needed.
    private static func enqueueMigrationSync<T: Encodable>(
        _ db: Database,
        entityType: String,
        entityId: String,
        operationType: SyncOperationType,
        payload: T,
        now: String
    ) throws {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"
        try db.execute(sql: """
            INSERT INTO sync_queue
                (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
            VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, 0)
            """, arguments: [UUID().uuidString, entityType, entityId, operationType.rawValue, payloadStr, now])
    }
}
