import Foundation
import GRDB
@testable import OYBC

/// Test-only DefaultPool helpers. `DefaultPool` (Phase 6.X) was superseded
/// by `Pool` + `CoreBoardDefault` in the pools rework. The only production
/// code still touching its rows (the v25 migration in `MigrationV25Helpers`
/// and `SyncService`'s drain-only push of legacy rows) goes through GRDB
/// directly, so the old `AppDatabase+DefaultPools.swift` API had no
/// production caller. The migration tests
/// (`PoolsCoreBoardDefaultsMigrationTests`) still seed and read legacy rows
/// through these three, so they moved here (2026-09 audit).
extension AppDatabase {
    /// Fetch the (at-most-one) non-deleted DefaultPool for
    /// `(userId, timeframe)`. Returns nil when the user has no pool for
    /// this timeframe.
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

    /// Atomic upsert by `(userId, timeframe)` — guarantees per-timeframe
    /// uniqueness (no sync enqueue).
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
}
