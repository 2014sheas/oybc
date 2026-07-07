import Foundation
import GRDB

extension AppDatabase {
    // MARK: - SyncQueue

    func fetchPendingSyncItems() throws -> [SyncQueueItem] {
        return try read { db in
            try SyncQueueItem
                .filter(Column("status") == SyncStatus.pending.rawValue)
                .order(Column("priority").desc, Column("createdAt"))
                .fetchAll(db)
        }
    }

    func saveSyncItem(_ item: SyncQueueItem) throws {
        try write { db in
            try item.save(db)
        }
    }

    func deleteSyncItem(id: String) throws {
        try write { db in
            try SyncQueueItem.deleteOne(db, key: id)
        }
    }

    /// Reset sync queue items left in `inProgress` from a force-quit
    /// or crashed push back to `pending`. Mirrors the equivalent reset
    /// at the top of the web `pushSync`.
    ///
    /// Only items whose `lastAttemptAt` is older than `staleAfter`
    /// (default 60 s) are reset, so a concurrent push currently
    /// processing an item won't have its row yanked out from under it.
    /// 60 s is a generous upper bound on how long a single Firestore
    /// write should take; anything older is genuinely stuck.
    ///
    /// `SyncService.pushSync` also has an `isSyncing` guard preventing
    /// concurrent pushes, but this staleness check is belt-and-
    /// suspenders for the case where `pushSync` is called from
    /// `fullSync` while another caller is mid-flight (rare, but the
    /// MainActor reentrancy model allows it via async suspension).
    @discardableResult
    func resetStaleInProgressSyncItems(staleAfter: TimeInterval = 60) throws -> Int {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let cutoffISO = Self.isoFormatter.string(from: cutoff)

        return try write { db in
            let inProgress = try SyncQueueItem
                .filter(Column("status") == SyncStatus.inProgress.rawValue)
                .fetchAll(db)

            var resetCount = 0
            for var item in inProgress {
                // No lastAttemptAt = item entered IN_PROGRESS before that
                // field was tracked (or via direct write); treat as stale.
                let isStale: Bool
                if let lastAttemptAt = item.lastAttemptAt {
                    isStale = lastAttemptAt < cutoffISO
                } else {
                    isStale = true
                }
                guard isStale else { continue }

                item.status = .pending
                try item.save(db)
                resetCount += 1
            }
            return resetCount
        }
    }

    /// Promote FAILED sync queue items back to `pending` when their
    /// exponential-backoff window has elapsed and they're under the
    /// retry cap. Items at or above `MAX_SYNC_RETRIES` are left FAILED
    /// indefinitely; they require a fresh enqueue or a manual retry
    /// from the playground SyncDashboard.
    ///
    /// Called at the top of `SyncService.pushSync`. The GRDB
    /// `ValueObservation` on PENDING count re-fires when items are
    /// promoted, which triggers the push-on-enqueue debounce — so
    /// promotion implicitly schedules a fresh push without an explicit
    /// kick.
    @discardableResult
    func promoteEligibleFailedSyncItems() throws -> Int {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return try write { db in
            let failed = try SyncQueueItem
                .filter(Column("status") == SyncStatus.failed.rawValue)
                .fetchAll(db)

            var promoted = 0
            for var item in failed {
                if item.retryCount >= SyncRetry.maxRetries { continue }
                let lastAttemptAtMs: Int? = item.lastAttemptAt
                    .flatMap { Self.parseISO8601($0) }
                    .map { Int($0.timeIntervalSince1970 * 1000) }
                guard SyncRetry.isFailedItemEligibleForRetry(
                    retryCount: item.retryCount,
                    lastAttemptAtMs: lastAttemptAtMs,
                    nowMs: nowMs
                ) else { continue }

                item.status = .pending
                item.lastError = nil
                try item.save(db)
                promoted += 1
            }
            return promoted
        }
    }
}

// MARK: - Sync Queries

extension AppDatabase {
    /// Fetch entities that need syncing (modified since last sync)
    func fetchUnsyncedBoards(userId: String) throws -> [Board] {
        return try read { db in
            try Board
                .filter(Column("userId") == userId)
                .filter(Column("updatedAt") > Column("lastSyncedAt") || Column("lastSyncedAt") == nil)
                .fetchAll(db)
        }
    }

    /// Mark entity as synced
    func markBoardSynced(id: String) throws {
        try write { db in
            var board = try Board.fetchOne(db, key: id)
            board?.lastSyncedAt = Self.currentTimestamp()
            try board?.update(db)
        }
    }
}

// MARK: - Cross-Board Queries (for Achievements)

extension AppDatabase {
    /// Count boards with at least one bingo by timeframe
    func countBingos(userId: String, timeframe: Timeframe) throws -> Int {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .filter(Column("timeframe") == timeframe.rawValue)
                .filter(Column("linesCompleted") > 0)
                .fetchCount(db)
        }
    }

    /// Count completed boards by timeframe
    func countCompletedBoards(userId: String, timeframe: Timeframe) throws -> Int {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .filter(Column("timeframe") == timeframe.rawValue)
                .filter(Column("status") == BoardStatus.completed.rawValue)
                .fetchCount(db)
        }
    }

}

// MARK: - Utilities

extension AppDatabase {
    /// Generate UUID for new entities
    static func generateUUID() -> String {
        return UUID().uuidString.lowercased()
    }

    /// Shared ISO8601 formatter. `ISO8601DateFormatter` is expensive
    /// to instantiate (~10–50ms on first use) and identical across
    /// every call site that just wants `Date.now` in ISO8601 — hoist
    /// it to a single static so write transactions don't pay the cost
    /// per row. `Foundation` documents the type as thread-safe.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Get current ISO8601 timestamp.
    static func currentTimestamp() -> String {
        return isoFormatter.string(from: Date())
    }

    /// Parse an ISO8601 string back to a `Date` (or nil). Used by the
    /// sync-pull validators.
    static func parseISO8601(_ s: String) -> Date? {
        return isoFormatter.date(from: s)
    }

    /// Errors raised by `AppDatabase` operations.
    enum AppDatabaseError: LocalizedError {
        /// A payload that was encoded by `JSONEncoder` couldn't be converted
        /// to a UTF-8 string for storage as a sync-queue item.
        case payloadEncoding(String)

        var errorDescription: String? {
            switch self {
            case .payloadEncoding(let msg): return msg
            }
        }
    }
}
