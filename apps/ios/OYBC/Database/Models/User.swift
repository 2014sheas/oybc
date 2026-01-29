import Foundation
import GRDB

/// User - User profile and authentication
///
/// Matches TypeScript User interface from @oybc/shared
struct User: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var email: String
    var displayName: String?
    var photoURL: String?

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata
    var lastSyncedAt: String? // ISO8601
    var version: Int

    // MARK: - Database Configuration

    static let databaseTableName = "users"

    static let boards = hasMany(Board.self)
    static let tasks = hasMany(Task.self)
    static let progressCounters = hasMany(ProgressCounter.self)
}
