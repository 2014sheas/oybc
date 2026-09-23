import Foundation
import GRDB

/// RecurringBoardTemplate — a repeating board: spawns a fresh board for
/// each new window when the user opens the Boards tab (lazy detection only).
/// iOS twin of `RecurringBoardTemplate` in `@oybc/shared` (see its doc);
/// canonical design: docs/BOARD_SOURCES.md §Data model.
///
/// - Task source: `sources` + `manualTaskIds` (hand-added layer) +
///   `manualTaskVary` (dice for hand-added counting members), resolved live
///   at every spawn via `BoardSources.sourcesForRecord` →
///   `BoardSources.selectBoardTasks` (`AppDatabase+RecurringTemplates.swift`).
/// - `poolIds` / `removedTaskIds`: a derived mirror of `sources`; the spawn
///   reads it only through `sourcesForRecord`, but pool-health / deck-preview
///   (`PoolHealth`, `RepeatingBoardMixEditor`) still read it directly.
/// - `seedTaskIds`: never read by the spawn; still read by un-migrated
///   hydration, the Task-detail templates-referencing query
///   (`fetchTemplatesReferencingTask`), and the roster loading fallbacks —
///   note it is a creation-time snapshot the edit path leaves stale (audit
///   follow-up).
/// - The optional fields are **tri-state, null-preserving**: `nil` ⇒ absent
///   on the wire (pre-stamp), `[]` ⇒ present-but-empty. Array fields are
///   JSON-string TEXT columns (custom `init(from:)` / `encode(to:)`).
/// - `lastSpawnedWindowKey` is the local-ISO `startDate` of the last spawned
///   window (idempotent spawning); `nil` ⇒ spawn on next Boards-tab open.
/// - `.custom` timeframe / `.chosen` center are excluded at the form layer;
///   the spawn path skips them (`unsupported_timeframe` / `_center`).
/// - Conforms to `PoolMixSource` so `PoolHealth` can still pass it to
///   `PoolMix.resolveMix`.
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

    // Legacy trio (see type doc): `poolIds`/`removedTaskIds` are the derived
    // mirror of `sources`, `manualTaskIds` is live. `nil` ⇒ absent on the
    // wire; `[]` ⇒ empty.
    var poolIds: [String]?
    var manualTaskIds: [String]?
    var removedTaskIds: [String]?

    // Canonical task source (docs/BOARD_SOURCES.md). Same tri-state
    // contract (`nil` ⇒ pre-stamp record; read through
    // `BoardSources.sourcesForRecord`); JSON-string TEXT column (v30).
    var sources: [BoardSource]?

    // Board Sources §Member rules (docs/BOARD_SOURCES.md, B1) — dice for
    // HAND-ADDED counting members on a repeating board (source members
    // carry their dice inside `BoardSource.memberRules`). Same tri-state
    // JSON-string TEXT contract as `sources` (migration v31): `nil` ⇒
    // absent/pre-stamp, a valid JSON object (even `{}`) ⇒ that map.
    var manualTaskVary: [String: VaryLevel]?

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
        case manualTaskVary
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
        manualTaskVary: [String: VaryLevel]? = nil,
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
        self.manualTaskVary = manualTaskVary
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

        // §Member rules B1 — same tri-state contract as `sources`.
        if let jsonString = (try? container.decodeIfPresent(String.self, forKey: .manualTaskVary)) ?? nil,
           let data = jsonString.data(using: .utf8) {
            manualTaskVary = try? JSONDecoder().decode([String: VaryLevel].self, from: data)
        } else {
            manualTaskVary = nil
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

        // §Member rules B1 — JSON-string TEXT column, key OMITTED when nil
        // (same `.optional()` wire contract as `sources` above).
        if let manualTaskVary = manualTaskVary {
            if let data = try? JSONEncoder().encode(manualTaskVary),
               let jsonString = String(data: data, encoding: .utf8) {
                try container.encode(jsonString, forKey: .manualTaskVary)
            } else {
                try container.encode("{}", forKey: .manualTaskVary)
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
