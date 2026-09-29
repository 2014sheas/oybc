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
/// **Per-timeframe size + centre** (docs/POOLS_RECURRING.md §Per-timeframe
/// size + centre, 2026-09-29): `defaultBoardSize` / `defaultCenterType` are
/// optional overrides (GRDB v36 nullable columns); nil = inherit the global
/// `UserPreferences` pair. Resolve through `resolveCoreBoardSetupDefaults`
/// (`Helpers/CoreBoardSetupDefaults.swift`), never by reading them raw. nil
/// ENCODES AS ABSENT on the wire (`encodeIfPresent`), which is what lets the
/// clearable-fields mechanism (`clearableFieldsByCollection["coreBoardDefaults"]`)
/// delete a cleared override on push; an unknown stored/remote value decodes
/// as nil (inherit) rather than failing the row.
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
    /// Per-timeframe board size override (3 / 4 / 5); nil = inherit prefs.
    var defaultBoardSize: DefaultBoardSize?
    /// Per-timeframe centre override (free / none); nil = inherit prefs.
    var defaultCenterType: DefaultCenterSquareType?

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
        case defaultBoardSize, defaultCenterType
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    init(
        id: String,
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        defaultBoardSize: DefaultBoardSize? = nil,
        defaultCenterType: DefaultCenterSquareType? = nil,
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
        self.defaultBoardSize = defaultBoardSize
        self.defaultCenterType = defaultCenterType
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

        // Lenient: absent, NULL, or an out-of-range / unknown value all decode
        // as nil (= inherit prefs) — a peer can never poison a row's shape.
        defaultBoardSize = (try? container.decodeIfPresent(Int.self, forKey: .defaultBoardSize))
            .flatMap { $0 }
            .flatMap(DefaultBoardSize.init(rawValue:))
        defaultCenterType = (try? container.decodeIfPresent(String.self, forKey: .defaultCenterType))
            .flatMap { $0 }
            .flatMap(DefaultCenterSquareType.init(rawValue:))

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

        // nil → key ABSENT (never an explicit null): the sync push then stamps
        // `FieldValue.delete()` for it via the clearable-fields mechanism.
        try container.encodeIfPresent(defaultBoardSize?.rawValue, forKey: .defaultBoardSize)
        try container.encodeIfPresent(defaultCenterType?.rawValue, forKey: .defaultCenterType)

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

/// Tri-state write instruction for a `CoreBoardDefault` override field —
/// the Swift twin of the TS `UpdateCoreBoardDefaultInput`'s
/// `undefined | null | value` on `defaultBoardSize` / `defaultCenterType`.
///
/// - `.keep` — leave the stored value untouched (a pools-only save must
///   never stomp an override; the P5 checkbox path always passes this).
/// - `.set(nil)` / `.clear` — CLEAR back to "inherit prefs" (stored NULL,
///   pushed as a field delete).
/// - `.set(x)` — override with `x`.
///
/// **Sharp edge:** for the centre field ALWAYS write
/// `.set(DefaultCenterSquareType.none)` — a bare `.set(.none)` resolves to
/// `Optional.none` (= `.clear`), silently clearing instead of setting
/// "no free space". Prefer `.clear` for the clear intent so the two never
/// read alike.
enum CoreBoardDefaultFieldPatch<Value> {
    case keep
    case set(Value?)

    /// Clear back to "inherit prefs" — spelled out so it can't be confused
    /// with setting an enum's `.none` case.
    static var clear: Self { .set(nil) }

    /// Applies this patch to a stored optional in place.
    ///
    /// - Parameter stored: The current stored value, mutated for `.set`.
    func apply(to stored: inout Value?) {
        if case .set(let next) = self { stored = next }
    }
}
