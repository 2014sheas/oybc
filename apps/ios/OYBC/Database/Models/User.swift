import Foundation
import GRDB

// MARK: - UserPreferences

/// Subset of `CenterSquareType` values allowed as a global default.
/// CHOSEN / CUSTOM_FREE require per-board context and aren't sensible defaults.
enum DefaultCenterSquareType: String, Codable {
    case free
    case none
}

enum WeekStartDay: String, Codable {
    case monday
    case sunday
}

enum DefaultBoardSize: Int, Codable {
    case three = 3
    case four = 4
    case five = 5
}

/// Synced per-user preferences. Round-trips through Firestore as JSON and
/// mirrors the TypeScript `UserPreferences` interface in `@oybc/shared`.
struct UserPreferences: Codable, Equatable {
    var weekStartDay: WeekStartDay
    var defaultBoardSize: DefaultBoardSize
    var defaultCenterType: DefaultCenterSquareType

    static let defaults = UserPreferences(
        weekStartDay: .monday,
        defaultBoardSize: .five,
        defaultCenterType: .free
    )

    /// Returns a complete preferences object by filling missing fields from
    /// `defaults`. Used when decoding records that pre-date the `preferences`
    /// column or that come from a misbehaving peer.
    static func merge(_ partial: UserPreferences?) -> UserPreferences {
        partial ?? .defaults
    }
}

// MARK: - User

/// User - User profile and authentication
///
/// Matches TypeScript User interface from @oybc/shared
struct User: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var email: String
    var displayName: String?
    var photoURL: String?

    // Synced preferences (JSON-encoded column; nil on pre-v5 rows).
    var preferences: String?

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

    // MARK: - Preferences accessors

    /// Decoded `UserPreferences`, with defaults filled in for missing /
    /// malformed / legacy (`nil`) values. Never throws.
    var decodedPreferences: UserPreferences {
        guard let json = preferences, let data = json.data(using: .utf8) else {
            return .defaults
        }
        return (try? JSONDecoder().decode(UserPreferences.self, from: data)) ?? .defaults
    }

    /// Encodes `UserPreferences` back into the JSON string column. Returns
    /// `nil` only on an unrecoverable encode failure (shouldn't happen for
    /// this shape, but keeps the call sites safe).
    static func encodePreferences(_ prefs: UserPreferences) -> String? {
        guard let data = try? JSONEncoder().encode(prefs) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
