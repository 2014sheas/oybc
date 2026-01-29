import Foundation
import GRDB

/// ProgressCounter - Shared cumulative counter across boards
///
/// Matches TypeScript ProgressCounter interface from @oybc/shared
struct ProgressCounter: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var name: String
    var unit: String
    var targetValue: Double
    var currentValue: Double

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "progress_counters"
}

// MARK: - Computed Properties

extension ProgressCounter {
    /// Computed progress percentage
    var progressPercentage: Double {
        guard targetValue > 0 else { return 0 }
        return (currentValue / targetValue) * 100
    }

    /// Check if target is reached
    var isComplete: Bool {
        return currentValue >= targetValue
    }

    /// Remaining amount to reach target
    var remaining: Double {
        return max(0, targetValue - currentValue)
    }
}
