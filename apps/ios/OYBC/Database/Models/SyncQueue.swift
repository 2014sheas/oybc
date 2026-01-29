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

// MARK: - Helpers

extension SyncQueueItem {
    /// Check if item should be retried
    var shouldRetry: Bool {
        return status == .failed && retryCount < 3
    }

    /// Check if item is stale (created more than 24 hours ago)
    var isStale: Bool {
        guard let createdDate = ISO8601DateFormatter().date(from: createdAt) else {
            return false
        }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        return createdDate < dayAgo
    }
}
