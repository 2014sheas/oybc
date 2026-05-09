import Foundation
import GRDB

/// RecurringBoardTemplate — Phase 6.2 (Preset-pool Recurring Boards).
///
/// User-curated task pool that auto-spawns a fresh board every window
/// when the user opens the Boards tab. iOS twin of TypeScript
/// `RecurringBoardTemplate` in `@oybc/shared`.
///
/// Design notes:
///
/// - `seedTaskIds` is stored as a JSON-string TEXT column (mirror of
///   `Board.completedLineIds` pattern) since SQLite has no native array
///   type. Custom `init(from:)` + `encode(to:)` handle the round-trip.
///
/// - `lastSpawnedWindowKey` is the `startDate` (local ISO8601) of the
///   most recently spawned window. Compared to the current window's
///   `startDate` from `computeTimeframeBoundaries(...)` for idempotent
///   spawning. `nil` ⇒ never spawned ⇒ next Boards-tab open spawns the
///   current window immediately.
///
/// - `Timeframe.custom` and `CenterSquareType.chosen` are excluded at
///   the form layer (and validated by the shared Zod schema on pull).
///   The model itself accepts them; the spawn path returns
///   `unsupported_timeframe` / `unsupported_center` and skips spawn.
struct RecurringBoardTemplate: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var name: String
    var timeframe: Timeframe
    var boardSize: Int
    var centerSquareType: CenterSquareType
    var centerSquareCustomName: String?
    var isRandomized: Bool
    var seedTaskIds: [String]

    // Spawn state
    var lastSpawnedWindowKey: String?
    var isActive: Bool

    // Timestamps
    var createdAt: String
    var updatedAt: String

    // Sync metadata
    var lastSyncedAt: String?
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?

    // MARK: - Database Configuration

    static let databaseTableName = "recurring_board_templates"

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, name, timeframe, boardSize
        case centerSquareType, centerSquareCustomName, isRandomized
        case seedTaskIds
        case lastSpawnedWindowKey, isActive
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    init(
        id: String,
        userId: String,
        name: String,
        timeframe: Timeframe,
        boardSize: Int,
        centerSquareType: CenterSquareType,
        centerSquareCustomName: String? = nil,
        isRandomized: Bool,
        seedTaskIds: [String],
        lastSpawnedWindowKey: String? = nil,
        isActive: Bool,
        createdAt: String,
        updatedAt: String,
        lastSyncedAt: String? = nil,
        version: Int = 1,
        isDeleted: Bool = false,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.timeframe = timeframe
        self.boardSize = boardSize
        self.centerSquareType = centerSquareType
        self.centerSquareCustomName = centerSquareCustomName
        self.isRandomized = isRandomized
        self.seedTaskIds = seedTaskIds
        self.lastSpawnedWindowKey = lastSpawnedWindowKey
        self.isActive = isActive
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
        name = try container.decode(String.self, forKey: .name)
        timeframe = try container.decode(Timeframe.self, forKey: .timeframe)
        boardSize = try container.decode(Int.self, forKey: .boardSize)
        centerSquareType = try container.decode(CenterSquareType.self, forKey: .centerSquareType)
        centerSquareCustomName = try container.decodeIfPresent(String.self, forKey: .centerSquareCustomName)
        isRandomized = try container.decode(Bool.self, forKey: .isRandomized)

        // Decode seedTaskIds from JSON-string TEXT column.
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .seedTaskIds),
           let data = jsonString.data(using: .utf8) {
            seedTaskIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            seedTaskIds = []
        }

        lastSpawnedWindowKey = try container.decodeIfPresent(String.self, forKey: .lastSpawnedWindowKey)
        isActive = try container.decode(Bool.self, forKey: .isActive)
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
        try container.encode(name, forKey: .name)
        try container.encode(timeframe, forKey: .timeframe)
        try container.encode(boardSize, forKey: .boardSize)
        try container.encode(centerSquareType, forKey: .centerSquareType)
        try container.encodeIfPresent(centerSquareCustomName, forKey: .centerSquareCustomName)
        try container.encode(isRandomized, forKey: .isRandomized)

        // Encode seedTaskIds as JSON-string TEXT column.
        if let data = try? JSONEncoder().encode(seedTaskIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .seedTaskIds)
        } else {
            try container.encode("[]", forKey: .seedTaskIds)
        }

        // `lastSpawnedWindowKey` is `String?` on iOS but `string | null`
        // (NOT `string | undefined`) in the shared Zod schema. The default
        // Optional encode behavior would *omit* the key when nil, which a
        // web peer's RecurringBoardTemplateSchema parse would reject as a
        // missing required field. Force-encode `null` so the wire payload
        // matches the shared contract.
        if let lastSpawnedWindowKey = lastSpawnedWindowKey {
            try container.encode(lastSpawnedWindowKey, forKey: .lastSpawnedWindowKey)
        } else {
            try container.encodeNil(forKey: .lastSpawnedWindowKey)
        }
        try container.encode(isActive, forKey: .isActive)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
