import Foundation
import GRDB

extension AppDatabase {
    // MARK: - DefaultPools (Phase 6.X)

    /// Fetch all non-deleted DefaultPools for a user. Used by the
    /// Profile editor to render the per-timeframe summary.
    func fetchDefaultPools(userId: String) throws -> [DefaultPool] {
        return try read { db in
            try DefaultPool
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the (at-most-one) non-deleted DefaultPool for
    /// `(userId, timeframe)`. Returns nil when the user has no pool for
    /// this timeframe. Used by the wizard's banner-launch prefill path.
    func fetchDefaultPool(userId: String, timeframe: Timeframe) throws -> DefaultPool? {
        return try read { db in
            try DefaultPool
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
        }
    }

    /// Insert / update a pool. Caller is responsible for bumping
    /// `version` + `updatedAt` (mirror of `saveRecurringBoardTemplate`).
    func saveDefaultPool(_ pool: DefaultPool) throws {
        try write { db in
            try pool.save(db)
        }
    }

    /// Atomic upsert by `(userId, timeframe)`. Preferred UI-side entry
    /// point — guarantees per-timeframe uniqueness without leaking the
    /// create-vs-update decision to callers.
    @discardableResult
    func upsertDefaultPool(userId: String, timeframe: Timeframe, taskIds: [String]) throws -> DefaultPool {
        return try write { db in
            let now = Self.currentTimestamp()
            if var existing = try DefaultPool
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
            {
                existing.taskIds = taskIds
                existing.updatedAt = now
                existing.version += 1
                try existing.update(db)
                return existing
            }
            let pool = DefaultPool(
                id: Self.generateUUID(),
                userId: userId,
                timeframe: timeframe,
                taskIds: taskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try pool.insert(db)
            return pool
        }
    }

    /// Soft-delete a DefaultPool. The Profile editor's "Clear pool"
    /// action calls this — distinct from saving an empty taskIds list
    /// (which keeps the row, just empties the pool).
    func softDeleteDefaultPool(id: String) throws {
        try write { db in
            guard var pool = try DefaultPool.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            pool.isDeleted = true
            pool.deletedAt = now
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
        }
    }

    // MARK: - Atomic save + sync-enqueue (templates & pools)
    //
    // Mirror of `saveTaskAndEnqueueUpdate`: the model write and its
    // sync-queue item live in ONE transaction so a crash between them
    // can't leave the local row ahead of Firestore with no recovery.

    /// Atomic upsert by `(userId, timeframe)` + sync-enqueue. Preferred
    /// UI entry point — guarantees per-timeframe uniqueness AND that the
    /// change is queued for sync (`saveDefaultPool` does neither).
    @discardableResult
    func upsertDefaultPoolAndEnqueue(
        userId: String,
        timeframe: Timeframe,
        taskIds: [String],
        now: String
    ) throws -> DefaultPool {
        return try write { db in
            let pool: DefaultPool
            let op: SyncOperationType
            if var existing = try DefaultPool
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
            {
                existing.taskIds = taskIds
                existing.updatedAt = now
                existing.version += 1
                try existing.update(db)
                pool = existing
                op = .update
            } else {
                let fresh = DefaultPool(
                    id: Self.generateUUID(),
                    userId: userId,
                    timeframe: timeframe,
                    taskIds: taskIds,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                )
                try fresh.insert(db)
                pool = fresh
                op = .create
            }
            try SyncQueueBuilder.makeItem(
                entityType: "defaultPools",
                entityId: pool.id,
                operationType: op,
                payload: pool,
                now: now
            ).enqueue(db)
            return pool
        }
    }

    /// Soft-delete a pool and enqueue the delete op atomically.
    func softDeleteDefaultPoolAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var pool = try DefaultPool.fetchOne(db, key: id) else { return }
            pool.isDeleted = true
            pool.deletedAt = now
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "defaultPools",
                entityId: pool.id,
                operationType: .delete,
                payload: pool,
                now: now
            ).enqueue(db)
        }
    }

}
