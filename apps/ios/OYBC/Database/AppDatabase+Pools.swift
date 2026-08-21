import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Pools (Task Pools + Recurring Boards Rework, P1)
    //
    // CRUD modeled on `AppDatabase+DefaultPools.swift`; the only structural
    // difference is that a Pool is user-named (many per user, no
    // `(userId, timeframe)` uniqueness) rather than one-per-timeframe.

    /// Fetch all non-deleted pools for a user. Used by the Tasks-tab Pools
    /// segment (P2) and by the legacy template write-through / migration
    /// to look up a specific pool's current `taskIds`.
    func fetchPools(userId: String) throws -> [Pool] {
        return try read { db in
            try Pool
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch a single pool by id (regardless of `isDeleted`).
    func fetchPool(id: String) throws -> Pool? {
        return try read { db in
            try Pool.fetchOne(db, key: id)
        }
    }

    /// Fetch multiple pools by id in one query, regardless of `isDeleted`
    /// (callers that need to distinguish should check the returned rows).
    /// Used by `PoolMix.resolveMix` callers (spawn path, wizard
    /// template-mix hydration, template attention/preview) that already
    /// have a `poolIds` array and need a `poolsById` lookup.
    func fetchPools(ids: [String]) throws -> [Pool] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Pool
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
        }
    }

    /// Insert / update a pool. Caller is responsible for bumping
    /// `version` + `updatedAt`.
    func savePool(_ pool: Pool) throws {
        try write { db in
            try pool.save(db)
        }
    }

    /// Create a new pool + enqueue its sync op atomically (mirrors
    /// `saveTaskAndEnqueueUpdate`: the model write and its sync-queue item
    /// live in ONE transaction so a crash between them can't leave the
    /// local row ahead of Firestore with no recovery).
    @discardableResult
    func createPoolAndEnqueue(userId: String, name: String, taskIds: [String], now: String) throws -> Pool {
        try write { db in
            let pool = Pool(
                id: Self.generateUUID(),
                userId: userId,
                name: name,
                taskIds: taskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try pool.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "pools",
                entityId: pool.id,
                operationType: .create,
                payload: pool,
                now: now
            ).enqueue(db)
            return pool
        }
    }

    /// Update an existing pool's `name` and/or `taskIds` + enqueue its
    /// sync op atomically. Bumps `version` + `updatedAt`. Returns nil (no
    /// write) when the id doesn't exist.
    @discardableResult
    func updatePoolAndEnqueue(
        id: String,
        name: String? = nil,
        taskIds: [String]? = nil,
        now: String
    ) throws -> Pool? {
        try write { db in
            guard var pool = try Pool.fetchOne(db, key: id) else { return nil }
            if let name = name { pool.name = name }
            if let taskIds = taskIds { pool.taskIds = taskIds }
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "pools",
                entityId: pool.id,
                operationType: .update,
                payload: pool,
                now: now
            ).enqueue(db)
            return pool
        }
    }

    /// Soft-delete a pool and enqueue the delete op atomically. Never
    /// cascades to the tasks it references, and never cascades to
    /// consumers (spawn records / core defaults) that pulled it in —
    /// detachment is derived at read time (`PoolMix.resolveMix` /
    /// core-defaults resolution skip `isDeleted` pools), matching `Pool`'s
    /// docstring.
    func softDeletePoolAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var pool = try Pool.fetchOne(db, key: id) else { return }
            pool.isDeleted = true
            pool.deletedAt = now
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "pools",
                entityId: pool.id,
                operationType: .delete,
                payload: pool,
                now: now
            ).enqueue(db)
        }
    }

    // MARK: - CoreBoardDefaults (Task Pools + Recurring Boards Rework, P1)
    //
    // Replaces `DefaultPool`. One row per `(userId, timeframe)`. CRUD
    // modeled on `AppDatabase+DefaultPools.swift`'s upsert pattern.

    /// Fetch all non-deleted CoreBoardDefault rows for a user. Used by the
    /// P7 Board-settings page's per-timeframe summary.
    func fetchCoreBoardDefaults(userId: String) throws -> [CoreBoardDefault] {
        return try read { db in
            try CoreBoardDefault
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the (at-most-one) non-deleted CoreBoardDefault for
    /// `(userId, timeframe)`. Returns nil when the user hasn't set one up.
    /// Used by the core-board setup prefill path (P5).
    func fetchCoreBoardDefault(userId: String, timeframe: Timeframe) throws -> CoreBoardDefault? {
        return try read { db in
            try CoreBoardDefault
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
        }
    }

    /// Atomic upsert by `(userId, timeframe)` + sync-enqueue. Preferred
    /// entry point — guarantees per-timeframe uniqueness AND that the
    /// change is queued for sync. NOT used by the P1 migration
    /// (`MigrationV25Helpers.migrateDefaultPools`) — that migration
    /// constructs + inserts `CoreBoardDefault` rows directly inside its own
    /// upgrade transaction (it needs a deterministic, uuidv5-derived id,
    /// not a fresh upsert), and enqueues sync via its own
    /// `enqueueMigrationSync` raw-SQL helper.
    @discardableResult
    func upsertCoreBoardDefaultAndEnqueue(
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        now: String
    ) throws -> CoreBoardDefault {
        return try write { db in
            try Self.upsertCoreBoardDefault(
                db: db,
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: coreDefaultTaskIds,
                now: now
            )
        }
    }

    /// Task Pools + Recurring Boards Rework (P5) — writes `corePoolIds`
    /// ONLY, preserving whatever `coreDefaultTaskIds` already exists.
    ///
    /// `upsertCoreBoardDefaultAndEnqueue` unconditionally overwrites BOTH
    /// fields on every call — there's no partial-update variant. But
    /// `coreDefaultTaskIds` is P7-authored-only (individual default tasks,
    /// set from the Board-settings defaults sheet); the core-setup
    /// checkbox (P5, docs/POOLS_RECURRING.md §Surfaces item 6) only ever
    /// persists `corePoolIds`. Calling the raw upsert directly from the
    /// checkbox path would silently zero out `coreDefaultTaskIds` the
    /// moment it exists — this wrapper reads the current row's
    /// `coreDefaultTaskIds` and passes it straight through unchanged.
    ///
    /// **Atomicity (P7 hardening)**: the fetch-existing-then-write used to
    /// be two separate GRDB transactions (a `read` here, then a nested
    /// `write` inside `upsertCoreBoardDefaultAndEnqueue`) — a concurrent
    /// sync pull landing between them could revert `coreDefaultTaskIds` to
    /// a value that was already stale by the time this write committed.
    /// The fetch now happens INSIDE the same `write` block as the upsert
    /// (via the shared `Self.upsertCoreBoardDefault` helper), so the whole
    /// read-merge-write is one transaction.
    @discardableResult
    func upsertCorePoolIdsAndEnqueue(
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        now: String
    ) throws -> CoreBoardDefault {
        return try write { db in
            let existingTaskIds = try CoreBoardDefault
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)?.coreDefaultTaskIds ?? []
            return try Self.upsertCoreBoardDefault(
                db: db,
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: existingTaskIds,
                now: now
            )
        }
    }

    /// Shared read-merge-write body for both `CoreBoardDefault` upsert
    /// entry points above — MUST be called from inside an existing `write`
    /// block (never opens its own transaction) so a caller that needs to
    /// read something else first (e.g. `upsertCorePoolIdsAndEnqueue`'s
    /// existing `coreDefaultTaskIds`) can do so in the SAME transaction as
    /// the write, closing the two-transaction race described above.
    private static func upsertCoreBoardDefault(
        db: Database,
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        now: String
    ) throws -> CoreBoardDefault {
        let coreDefault: CoreBoardDefault
        let op: SyncOperationType
        if var existing = try CoreBoardDefault
            .filter(
                Column("userId") == userId
                    && Column("timeframe") == timeframe.rawValue
                    && Column("isDeleted") == false
            )
            .fetchOne(db)
        {
            existing.corePoolIds = corePoolIds
            existing.coreDefaultTaskIds = coreDefaultTaskIds
            existing.updatedAt = now
            existing.version += 1
            try existing.update(db)
            coreDefault = existing
            op = .update
        } else {
            let fresh = CoreBoardDefault(
                id: Self.generateUUID(),
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: coreDefaultTaskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try fresh.insert(db)
            coreDefault = fresh
            op = .create
        }
        try SyncQueueBuilder.makeItem(
            entityType: "coreBoardDefaults",
            entityId: coreDefault.id,
            operationType: op,
            payload: coreDefault,
            now: now
        ).enqueue(db)
        return coreDefault
    }

    /// Soft-delete a CoreBoardDefault row and enqueue the delete op
    /// atomically.
    func softDeleteCoreBoardDefaultAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var coreDefault = try CoreBoardDefault.fetchOne(db, key: id) else { return }
            coreDefault.isDeleted = true
            coreDefault.deletedAt = now
            coreDefault.updatedAt = now
            coreDefault.version += 1
            try coreDefault.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "coreBoardDefaults",
                entityId: coreDefault.id,
                operationType: .delete,
                payload: coreDefault,
                now: now
            ).enqueue(db)
        }
    }
}
