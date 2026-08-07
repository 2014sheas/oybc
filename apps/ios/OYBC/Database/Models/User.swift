import Foundation
import GRDB

// MARK: - UserPreferences

/// Subset of `CenterSquareType` values allowed as a global default.
/// CHOSEN requires per-board context and isn't a sensible default.
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
/// (`daily | weekly | monthly | yearly | custom | indefinite`) — kept
/// separate from the existing per-board `Timeframe` enum to avoid coupling
/// the preference schema to any future additions.
///
/// `indefinite` is accepted here for decode-safety (a value web can write to
/// `mergeUserPreferences`), even though it isn't currently a selectable
/// option in either platform's preferences UI — see `BoardPreferencesPage.tsx`.
enum DefaultTimeframe: String, Codable {
    case daily
    case weekly
    case monthly
    case yearly
    case custom
    case indefinite
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

    // Riso Phase 5a — Board Preferences sub-page additions.
    // All new fields decode forward-compatibly via the custom `init(from:)`.

    /// Celebration intensity 1–10. Scales confetti count on GREENLOG and
    /// bingo-toast animations. Default 7 ("Full press") per the design spec.
    var celebrationIntensity: Int
    /// Whether device haptics fire on cell completion and bingo detection.
    var haptics: Bool
    /// Whether the user wants a nudge the day before a board expires.
    var expiringReminders: Bool
    /// Whether completed (GREENLOGed) boards are moved out of the list after
    /// one week.
    var autoArchiveCompleted: Bool

    // Notifications (Phase 7 — iOS local reminders). All decode
    // forward-compatibly via the custom `init(from:)`.

    /// Master notifications opt-in. Default `false` — flipping it on drives the
    /// in-context permission priming. The OS permission is the real capability
    /// gate; this is the user's stated intent.
    var notificationsEnabled: Bool
    /// Notify when a new recurring window opens and no core board exists yet.
    /// Default true.
    var recurringWindowReminders: Bool
    /// Whether the daily play reminder fires. Default `false` (opt-in).
    var dailyPlayReminderEnabled: Bool
    /// Daily play reminder time of day, 24h "HH:mm" (local). Default "20:00".
    var dailyPlayReminderTime: String

    static let defaults = UserPreferences(
        weekStartDay: .monday,
        defaultBoardSize: .five,
        defaultCenterType: .free,
        defaultTimeframe: .custom,
        defaultRandomize: true,
        theme: .system,
        // Phase 6.1: default true so the core boards (daily/weekly/monthly/
        // yearly) are immediately discoverable on a fresh account. Per the
        // forward-compat decoder, users who already explicitly toggled these
        // to false on the prefs page keep their explicit choice — only users
        // whose stored prefs are missing these fields auto-upgrade to true.
        recurringDailyEnabled: true,
        recurringWeeklyEnabled: true,
        recurringMonthlyEnabled: true,
        recurringYearlyEnabled: true,
        celebrationIntensity: 7,
        haptics: true,
        expiringReminders: true,
        autoArchiveCompleted: false,
        notificationsEnabled: false,
        recurringWindowReminders: true,
        dailyPlayReminderEnabled: false,
        dailyPlayReminderTime: "20:00"
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
        // Clamp to the valid 1–10 range — a misbehaving peer could push an
        // out-of-range value that would otherwise reach the celebration UI.
        self.celebrationIntensity = max(1, min(10,
            (try? c.decode(Int.self, forKey: .celebrationIntensity))
                ?? Self.defaults.celebrationIntensity))
        self.haptics = (try? c.decode(Bool.self, forKey: .haptics))
            ?? Self.defaults.haptics
        self.expiringReminders = (try? c.decode(Bool.self, forKey: .expiringReminders))
            ?? Self.defaults.expiringReminders
        self.autoArchiveCompleted = (try? c.decode(Bool.self, forKey: .autoArchiveCompleted))
            ?? Self.defaults.autoArchiveCompleted
        self.notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled))
            ?? Self.defaults.notificationsEnabled
        self.recurringWindowReminders = (try? c.decode(Bool.self, forKey: .recurringWindowReminders))
            ?? Self.defaults.recurringWindowReminders
        self.dailyPlayReminderEnabled = (try? c.decode(Bool.self, forKey: .dailyPlayReminderEnabled))
            ?? Self.defaults.dailyPlayReminderEnabled
        // Reject a malformed time — a bad value would otherwise produce an
        // invalid schedule. Falls back to the default rather than a partial parse.
        let decodedTime = (try? c.decode(String.self, forKey: .dailyPlayReminderTime))
            ?? Self.defaults.dailyPlayReminderTime
        self.dailyPlayReminderTime = UserPreferences.isValidReminderTime(decodedTime)
            ? decodedTime
            : Self.defaults.dailyPlayReminderTime
    }

    /// Validates a 24-hour "HH:mm" time-of-day string (00:00–23:59). Mirrors
    /// the `HH_MM_RE` guard in the shared `mergeUserPreferences`.
    static func isValidReminderTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return false }
        return true
    }

    /// Memberwise initialiser preserved explicitly because adding a custom
    /// `init(from:)` suppresses the compiler-synthesised one.
    init(
        weekStartDay: WeekStartDay,
        defaultBoardSize: DefaultBoardSize,
        defaultCenterType: DefaultCenterSquareType,
        defaultTimeframe: DefaultTimeframe,
        defaultRandomize: Bool,
        theme: ThemePreference,
        recurringDailyEnabled: Bool,
        recurringWeeklyEnabled: Bool,
        recurringMonthlyEnabled: Bool,
        recurringYearlyEnabled: Bool,
        celebrationIntensity: Int = 7,
        haptics: Bool = true,
        expiringReminders: Bool = true,
        autoArchiveCompleted: Bool = false,
        notificationsEnabled: Bool = false,
        recurringWindowReminders: Bool = true,
        dailyPlayReminderEnabled: Bool = false,
        dailyPlayReminderTime: String = "20:00"
    ) {
        self.weekStartDay = weekStartDay
        self.defaultBoardSize = defaultBoardSize
        self.defaultCenterType = defaultCenterType
        self.defaultTimeframe = defaultTimeframe
        self.defaultRandomize = defaultRandomize
        self.theme = theme
        self.recurringDailyEnabled = recurringDailyEnabled
        self.recurringWeeklyEnabled = recurringWeeklyEnabled
        self.recurringMonthlyEnabled = recurringMonthlyEnabled
        self.recurringYearlyEnabled = recurringYearlyEnabled
        self.celebrationIntensity = celebrationIntensity
        self.haptics = haptics
        self.expiringReminders = expiringReminders
        self.autoArchiveCompleted = autoArchiveCompleted
        self.notificationsEnabled = notificationsEnabled
        self.recurringWindowReminders = recurringWindowReminders
        self.dailyPlayReminderEnabled = dailyPlayReminderEnabled
        self.dailyPlayReminderTime = dailyPlayReminderTime
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
