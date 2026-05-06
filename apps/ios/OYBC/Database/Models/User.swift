import Foundation
import GRDB

// MARK: - UserPreferences

/// Subset of `CenterSquareType` values allowed as a global default.
/// CHOSEN / CUSTOM_FREE require per-board context and aren't sensible defaults
/// (the CUSTOM_FREE display text is captured by `defaultCenterCustomName`).
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

/// Board timeframe default. Mirrors the `Timeframe` enum in @oybc/shared
/// (`daily | weekly | monthly | yearly | custom`) — kept separate from the
/// existing per-board `Timeframe` enum to avoid coupling the preference
/// schema to any future additions.
enum DefaultTimeframe: String, Codable {
    case daily
    case weekly
    case monthly
    case yearly
    case custom
}

/// App appearance override. `system` follows the OS appearance; `light`/`dark`
/// force a specific theme across devices.
enum ThemePreference: String, Codable {
    case light
    case dark
    case system
}

/// Synced per-user preferences. Round-trips through Firestore as JSON and
/// mirrors the TypeScript `UserPreferences` interface in `@oybc/shared`.
///
/// Storage note: the `preferences` column is a JSON TEXT blob, so adding
/// new fields here does NOT require a GRDB migration — the JSON encoder
/// handles new keys, and `init(from:)` below provides forward-compat
/// fallbacks for older payloads missing them.
struct UserPreferences: Codable, Equatable {
    var weekStartDay: WeekStartDay
    var defaultBoardSize: DefaultBoardSize
    var defaultCenterType: DefaultCenterSquareType
    var defaultTimeframe: DefaultTimeframe
    var defaultRandomize: Bool
    var defaultCenterCustomName: String
    var theme: ThemePreference
    // Recurring boards (Phase 6.1) — when enabled, the Boards and Create tabs
    // surface a prominent "core boards" section inviting the user to create a
    // board for the current window. Default `true` so the feature is
    // discoverable on a fresh account (opt-out semantics — see
    // `defaults` below). Users who explicitly toggled them off keep their
    // explicit choice via the `init(from:)` decoder, which falls back to the
    // post-6.1d `true` defaults only when keys are *missing* from the payload.
    var recurringDailyEnabled: Bool
    var recurringWeeklyEnabled: Bool
    var recurringMonthlyEnabled: Bool
    var recurringYearlyEnabled: Bool

    static let defaults = UserPreferences(
        weekStartDay: .monday,
        defaultBoardSize: .five,
        defaultCenterType: .free,
        defaultTimeframe: .custom,
        defaultRandomize: true,
        defaultCenterCustomName: "",
        theme: .system,
        // Phase 6.1: default true so the core boards (daily/weekly/monthly/
        // yearly) are immediately discoverable on a fresh account. Per the
        // forward-compat decoder, users who already explicitly toggled these
        // to false on the prefs page keep their explicit choice — only users
        // whose stored prefs are missing these fields auto-upgrade to true.
        recurringDailyEnabled: true,
        recurringWeeklyEnabled: true,
        recurringMonthlyEnabled: true,
        recurringYearlyEnabled: true
    )

    /// Returns a complete preferences object by filling missing fields from
    /// `defaults`. Used when decoding records that pre-date the `preferences`
    /// column or that come from a misbehaving peer.
    static func merge(_ partial: UserPreferences?) -> UserPreferences {
        partial ?? .defaults
    }

    // MARK: - Codable (forward-compatible decode)

    /// Custom decoder that falls back to `.defaults` for any missing or
    /// malformed field, so a user row written by an older client (with fewer
    /// preference keys) decodes cleanly without clobbering the values that
    /// are present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.weekStartDay = (try? c.decode(WeekStartDay.self, forKey: .weekStartDay))
            ?? Self.defaults.weekStartDay
        self.defaultBoardSize = (try? c.decode(DefaultBoardSize.self, forKey: .defaultBoardSize))
            ?? Self.defaults.defaultBoardSize
        self.defaultCenterType = (try? c.decode(DefaultCenterSquareType.self, forKey: .defaultCenterType))
            ?? Self.defaults.defaultCenterType
        self.defaultTimeframe = (try? c.decode(DefaultTimeframe.self, forKey: .defaultTimeframe))
            ?? Self.defaults.defaultTimeframe
        self.defaultRandomize = (try? c.decode(Bool.self, forKey: .defaultRandomize))
            ?? Self.defaults.defaultRandomize
        self.defaultCenterCustomName = (try? c.decode(String.self, forKey: .defaultCenterCustomName))
            ?? Self.defaults.defaultCenterCustomName
        self.theme = (try? c.decode(ThemePreference.self, forKey: .theme))
            ?? Self.defaults.theme
        self.recurringDailyEnabled = (try? c.decode(Bool.self, forKey: .recurringDailyEnabled))
            ?? Self.defaults.recurringDailyEnabled
        self.recurringWeeklyEnabled = (try? c.decode(Bool.self, forKey: .recurringWeeklyEnabled))
            ?? Self.defaults.recurringWeeklyEnabled
        self.recurringMonthlyEnabled = (try? c.decode(Bool.self, forKey: .recurringMonthlyEnabled))
            ?? Self.defaults.recurringMonthlyEnabled
        self.recurringYearlyEnabled = (try? c.decode(Bool.self, forKey: .recurringYearlyEnabled))
            ?? Self.defaults.recurringYearlyEnabled
    }

    /// Memberwise initialiser preserved explicitly because adding a custom
    /// `init(from:)` suppresses the compiler-synthesised one.
    init(
        weekStartDay: WeekStartDay,
        defaultBoardSize: DefaultBoardSize,
        defaultCenterType: DefaultCenterSquareType,
        defaultTimeframe: DefaultTimeframe,
        defaultRandomize: Bool,
        defaultCenterCustomName: String,
        theme: ThemePreference,
        recurringDailyEnabled: Bool,
        recurringWeeklyEnabled: Bool,
        recurringMonthlyEnabled: Bool,
        recurringYearlyEnabled: Bool
    ) {
        self.weekStartDay = weekStartDay
        self.defaultBoardSize = defaultBoardSize
        self.defaultCenterType = defaultCenterType
        self.defaultTimeframe = defaultTimeframe
        self.defaultRandomize = defaultRandomize
        self.defaultCenterCustomName = defaultCenterCustomName
        self.theme = theme
        self.recurringDailyEnabled = recurringDailyEnabled
        self.recurringWeeklyEnabled = recurringWeeklyEnabled
        self.recurringMonthlyEnabled = recurringMonthlyEnabled
        self.recurringYearlyEnabled = recurringYearlyEnabled
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
