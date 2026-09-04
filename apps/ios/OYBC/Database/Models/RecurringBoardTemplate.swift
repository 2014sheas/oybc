import Foundation
import GRDB

/// RecurringBoardTemplate — Phase 6.2 (Preset-pool Recurring Boards).
///
/// User-curated task pool that automatically creates a fresh board every window
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
///
/// - **P1 (Task Pools + Recurring Boards Rework)** generalizes the task
///   source: `seedTaskIds` is RETIRED (migrated, then decode-compat only —
///   never read live post-migration; see `PoolMix.swift` +
///   docs/POOLS_RECURRING.md §Migration "seedTaskIds end state"). The mix
///   is `poolIds` / `manualTaskIds` / `removedTaskIds`, resolved via
///   `PoolMix.resolveMix`. All three are **tri-state, null-preserving**
///   (mirrors `lastSpawnedWindowKey`'s force-encode-null pattern, NOT
///   `seedTaskIds`'s always-`[]` pattern): `nil` means "genuinely
///   un-migrated" (the field is absent on the wire); `[]` is a real empty
///   array. `RecurringBoardTemplate` conforms to `PoolMixSource` (see
///   `PoolMix.swift`) so it can be passed to `resolveMix` /
///   `clearRemovalsForUntoggle` directly.
///
/// - **P4** made this the ONLY shape `persistRecurringTemplate`
///   (`BoardWizardPersist.swift`) ever writes, for both fresh-create AND
///   edit — the P1→P3 shape-scoped legacy write-through
///   (`PoolMix.isLegacyShapedRecord`, which still exists as a pure helper
///   for the retired call site's shape check and its own unit tests, but
///   is no longer read by any production write path) is retired. A
///   fresh-create no longer mints a Pool at all; an own-mix, zero-pool
///   repeating board is first-class.
struct RecurringBoardTemplate: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var name: String
    var timeframe: Timeframe
    var boardSize: Int
    var centerSquareType: CenterSquareType
    var isRandomized: Bool
    var seedTaskIds: [String]

    // P1 — generalized task source (see type doc above). `nil` ⇒ absent on
    // the wire (genuinely un-migrated); `[]` ⇒ present-but-empty.
    var poolIds: [String]?
    var manualTaskIds: [String]?
    var removedTaskIds: [String]?

    // Board Sources rework (docs/BOARD_SOURCES.md, P1) — the canonical
    // persisted task-source shape going forward. Same tri-state contract
    // as the trio above (`nil` ⇒ pre-stamp record; read through
    // `BoardSources.sourcesForRecord`), stored as a JSON-string TEXT
    // column (migration v30). During P1 every write stamps BOTH this and
    // the trio; `manualTaskIds` stays live in both models.
    var sources: [BoardSource]?

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
        case centerSquareType, isRandomized
        case seedTaskIds
        case poolIds, manualTaskIds, removedTaskIds
        case sources
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
        isRandomized: Bool,
        seedTaskIds: [String],
        poolIds: [String]? = nil,
        manualTaskIds: [String]? = nil,
        removedTaskIds: [String]? = nil,
        sources: [BoardSource]? = nil,
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
        self.isRandomized = isRandomized
        self.seedTaskIds = seedTaskIds
        self.poolIds = poolIds
        self.manualTaskIds = manualTaskIds
        self.removedTaskIds = removedTaskIds
        self.sources = sources
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
        isRandomized = try container.decode(Bool.self, forKey: .isRandomized)

        // Decode seedTaskIds from JSON-string TEXT column.
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .seedTaskIds),
           let data = jsonString.data(using: .utf8) {
            seedTaskIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            seedTaskIds = []
        }

        // P1 — decode poolIds/manualTaskIds/removedTaskIds tri-state:
        // column NULL or absent ⇒ nil (genuinely un-migrated); a JSON
        // string (even "[]") ⇒ that array, distinguishing "no pool yet"
        // from "not migrated at all". Unlike seedTaskIds (always `[]` on
        // decode failure), a malformed JSON string here also decodes to
        // nil rather than `[]` — never silently manufacture a "migrated,
        // empty" shape from corrupt data.
        poolIds = Self.decodeOptionalStringArray(container, forKey: .poolIds)
        manualTaskIds = Self.decodeOptionalStringArray(container, forKey: .manualTaskIds)
        removedTaskIds = Self.decodeOptionalStringArray(container, forKey: .removedTaskIds)

        // Board Sources P1 — same tri-state contract as the trio: column
        // NULL/absent OR malformed JSON ⇒ nil (pre-stamp record — never
        // silently manufacture a "stamped, empty" shape); a valid JSON
        // string (even "[]") ⇒ that array.
        if let jsonString = (try? container.decodeIfPresent(String.self, forKey: .sources)) ?? nil,
           let data = jsonString.data(using: .utf8) {
            sources = try? JSONDecoder().decode([BoardSource].self, from: data)
        } else {
            sources = nil
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

    /// Decodes an optional JSON-string TEXT column into `[String]?`,
    /// preserving the tri-state distinction P1's `poolIds` / `manualTaskIds`
    /// / `removedTaskIds` need: `nil` when the key is absent/NULL (never
    /// written a JSON string in the first place) OR the stored string
    /// fails to parse; the decoded array (possibly `[]`) when a JSON
    /// string is present and valid. Never manufactures `[]` from a missing
    /// key — that would collapse "genuinely un-migrated" into "migrated,
    /// empty", which `PoolMix.isLegacyShapedRecord` depends on being
    /// distinguishable at the (`nil` poolIds, absent seedTaskIds fallback)
    /// vs (`poolIds: []`) boundary. Used by all three P1 fields; not
    /// applicable to `seedTaskIds`, which intentionally always defaults to
    /// `[]`.
    private static func decodeOptionalStringArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String]? {
        guard let jsonString = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(name, forKey: .name)
        try container.encode(timeframe, forKey: .timeframe)
        try container.encode(boardSize, forKey: .boardSize)
        try container.encode(centerSquareType, forKey: .centerSquareType)
        try container.encode(isRandomized, forKey: .isRandomized)

        // Encode seedTaskIds as JSON-string TEXT column.
        if let data = try? JSONEncoder().encode(seedTaskIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .seedTaskIds)
        } else {
            try container.encode("[]", forKey: .seedTaskIds)
        }

        // P1 — encode poolIds/manualTaskIds/removedTaskIds as JSON-string
        // TEXT columns (same mechanism as seedTaskIds), but OMIT the key
        // entirely when nil rather than force-encoding null. Unlike
        // `lastSpawnedWindowKey` (whose shared Zod type is `string | null`,
        // a required-but-nullable key), these three are `.optional()` in
        // the shared Zod schema — `T[] | undefined`, NOT `T[] | null` — so
        // writing an explicit `null` would fail a peer's pull-side Zod
        // parse. Omission is what "genuinely un-migrated" means on the
        // wire, matching the decode side's tri-state contract above.
        if let poolIds = poolIds {
            if let data = try? JSONEncoder().encode(poolIds),
               let jsonString = String(data: data, encoding: .utf8) {
                try container.encode(jsonString, forKey: .poolIds)
            } else {
                try container.encode("[]", forKey: .poolIds)
            }
        }
        if let manualTaskIds = manualTaskIds {
            if let data = try? JSONEncoder().encode(manualTaskIds),
               let jsonString = String(data: data, encoding: .utf8) {
                try container.encode(jsonString, forKey: .manualTaskIds)
            } else {
                try container.encode("[]", forKey: .manualTaskIds)
            }
        }
        if let removedTaskIds = removedTaskIds {
            if let data = try? JSONEncoder().encode(removedTaskIds),
               let jsonString = String(data: data, encoding: .utf8) {
                try container.encode(jsonString, forKey: .removedTaskIds)
            } else {
                try container.encode("[]", forKey: .removedTaskIds)
            }
        }

        // Board Sources P1 — JSON-string TEXT column, key OMITTED when nil
        // (`.optional()` in the shared Zod schema — an explicit null would
        // fail a peer's pull-side parse; omission = "pre-stamp" on the
        // wire, matching the decode tri-state).
        if let sources = sources {
            if let data = try? JSONEncoder().encode(sources),
               let jsonString = String(data: data, encoding: .utf8) {
                try container.encode(jsonString, forKey: .sources)
            } else {
                try container.encode("[]", forKey: .sources)
            }
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
