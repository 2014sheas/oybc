import Foundation
import GRDB

/// SyncQueue - Offline sync queue for tracking pending sync operations
///
/// Matches TypeScript SyncQueueItem interface from @oybc/shared
struct SyncQueueItem: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var entityType: String
    var entityId: String

    // Operation details
    var operationType: SyncOperationType
    var payload: String // JSON string

    // Status tracking
    var status: SyncStatus
    var retryCount: Int
    var lastError: String?

    // Timestamps
    var createdAt: String // ISO8601
    var lastAttemptAt: String? // ISO8601
    var completedAt: String? // ISO8601

    // Priority (higher = more important)
    var priority: Int

    // MARK: - Database Configuration

    static let databaseTableName = "sync_queue"
}

// MARK: - Enums

enum SyncOperationType: String, Codable, DatabaseValueConvertible {
    case create
    case update
    case delete
}

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

// MARK: - Retry Backoff

/// Mirror of `packages/shared/src/constants/syncRetry.ts`. Swift can't
/// import the TypeScript module, so the schedule is duplicated here —
/// keep the two in lockstep when changing.
enum SyncRetry {
    /// Maximum retry attempts for a sync operation (mirrors
    /// `MAX_SYNC_RETRIES` in @oybc/shared).
    static let maxRetries: Int = 5

    /// Exponential backoff schedule (milliseconds) indexed by
    /// retryCount - 1.
    static let backoffMs: [Int] = [
        30 * 1_000,         // first retry: 30s after failure
        2 * 60 * 1_000,     // second:      2 min
        10 * 60 * 1_000,    // third:       10 min
        30 * 60 * 1_000,    // fourth:      30 min
        60 * 60 * 1_000,    // fifth:       1 hour (cap)
    ]

    /// Returns true when a FAILED sync queue item has waited long
    /// enough since its last attempt to be re-promoted to PENDING.
    /// Mirrors `isFailedItemEligibleForRetry` in @oybc/shared.
    static func isFailedItemEligibleForRetry(
        retryCount: Int,
        lastAttemptAtMs: Int?,
        nowMs: Int
    ) -> Bool {
        let idx = max(0, min(retryCount - 1, backoffMs.count - 1))
        let backoff = backoffMs[idx]
        guard let lastAttemptAtMs else { return true }
        return nowMs - lastAttemptAtMs >= backoff
    }
}

// MARK: - Helpers

extension SyncQueueItem {
    /// Check if item is stale (created more than 24 hours ago)
    var isStale: Bool {
        guard let createdDate = ISO8601DateFormatter().date(from: createdAt) else {
            return false
        }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        return createdDate < dayAgo
    }
}
