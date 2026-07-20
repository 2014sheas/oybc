import Foundation
import GRDB

/// CoreBoardDefault — Task Pools + Recurring Boards Rework (P1). iOS twin of
/// TypeScript `CoreBoardDefault` in `@oybc/shared`
/// (`packages/shared/src/types/coreBoardDefault.ts`).
///
/// Replaces `DefaultPool` (Phase 6.X). One row per `(userId, timeframe)`.
/// Chosen over `UserPreferences` fields (locked 2026-07-19: small table, not
/// prefs) because prefs sync as a single LWW doc — concurrent prefs writes
/// would race the whole default set — while per-row LWW matches the
/// `DefaultPool` precedent it replaces.
///
/// Defaults **pre-fill** core-board setup (both fields render as plain,
/// editable chips); they never auto-own the board. The "Start every <TF>
/// board with 'X'" checkbox (shown only when pools are attached) persists
/// `corePoolIds` ONLY — never the day's one-off tasks.
///
/// `coreDefaultTaskIds` is authored only in the P7 Board-settings defaults
/// sheet (chips + quick-add) — the field exists synced-but-unwritten from
/// P1 until P7. That's intentional, not a bug.
///
/// `Timeframe.custom` is excluded — same reason as `DefaultPool` /
/// `RecurringBoardTemplate`: a "default" tied to a computed recurring
/// window has no semantic for custom-window boards. Enforced at the shared
/// Zod layer on pull; the iOS write helpers don't accept `.custom` either.
///
/// Both `corePoolIds` and `coreDefaultTaskIds` are stored as JSON-string
/// TEXT columns (same pattern as `Pool.taskIds`).
///
/// Canonical design: docs/POOLS_RECURRING.md §Data model → New entity:
/// CoreBoardDefault.
struct CoreBoardDefault: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var timeframe: Timeframe
    /// Pools that pre-fill core-board setup (union'd as plain chips; never
    /// a board action).
    var corePoolIds: [String]
    /// Individual default tasks, pre-filled as plain chips alongside pool
    /// tasks.
    var coreDefaultTaskIds: [String]

    // Timestamps
    var createdAt: String
    var updatedAt: String

    // Sync metadata
    var lastSyncedAt: String?
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?

    // MARK: - Database Configuration

    static let databaseTableName = "core_board_defaults"

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, timeframe, corePoolIds, coreDefaultTaskIds
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    init(
        id: String,
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int = 1,
        isDeleted: Bool = false,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.timeframe = timeframe
        self.corePoolIds = corePoolIds
        self.coreDefaultTaskIds = coreDefaultTaskIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        timeframe = try container.decode(Timeframe.self, forKey: .timeframe)

        if let jsonString = try container.decodeIfPresent(String.self, forKey: .corePoolIds),
           let data = jsonString.data(using: .utf8) {
            corePoolIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            corePoolIds = []
        }

        if let jsonString = try container.decodeIfPresent(String.self, forKey: .coreDefaultTaskIds),
           let data = jsonString.data(using: .utf8) {
            coreDefaultTaskIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            coreDefaultTaskIds = []
        }

        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSyncedAt = try container.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        version = try container.decode(Int.self, forKey: .version)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(timeframe, forKey: .timeframe)

        if let data = try? JSONEncoder().encode(corePoolIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .corePoolIds)
        } else {
            try container.encode("[]", forKey: .corePoolIds)
        }

        if let data = try? JSONEncoder().encode(coreDefaultTaskIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .coreDefaultTaskIds)
        } else {
            try container.encode("[]", forKey: .coreDefaultTaskIds)
        }

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
