import Foundation

/// BoardSource — Board Sources rework (docs/BOARD_SOURCES.md, P1). Swift
/// twin of `packages/shared/src/types/boardSource.ts` — keep in sync.
///
/// One pulled source feeding a board's task list: a **pool** or another
/// **board**, with a two-handle range (how many of its tasks land on the
/// board), per-board exclusions, and (boards only) a done/not-done filter.
/// Stored as an element of the JSON-string `sources` column on
/// `recurring_board_templates` and inside the wizard-draft blob
/// (`Board.recurringDraftMix`, v2). NOT a GRDB record — it only ever
/// lives inside a JSON column.
///
/// `max == nil` is the **"all" latch** (the default): the cap tracks the
/// source's live available count. Encoding is custom so `max` round-trips
/// as an EXPLICIT JSON `null` (never an omitted key) — web's blob/schema
/// checks require the key present, and the synthesized Codable would drop
/// a nil optional.
struct BoardSource: Codable, Equatable {
    enum Kind: String, Codable {
        case pool
        case board
    }

    /// Board-source member filter. `.all` = every square; `.todo` = only
    /// squares not yet complete in the source board's window. Pools are
    /// always `.all` (carried but ignored for pools).
    enum Filter: String, Codable {
        case all
        case todo
    }

    /// `Pool.id` (kind `.pool`) or the pulled `Board.id` (kind `.board`).
    var sourceId: String
    var kind: Kind
    /// Range minimum — "guarantee at least this many". Clamped defensively
    /// at resolve time; 0 = no guarantee (the default).
    var min: Int
    /// Range maximum — nil = the "all" latch (see type doc).
    var max: Int?
    /// Per-board exclusions; the saved pool/board is never modified.
    /// Stale-inert entries (ids the supply doesn't contain) are harmless.
    var excludedTaskIds: [String]
    var filter: Filter

    enum CodingKeys: String, CodingKey {
        case sourceId, kind, min, max, excludedTaskIds, filter
    }

    init(
        sourceId: String,
        kind: Kind,
        min: Int = 0,
        max: Int? = nil,
        excludedTaskIds: [String] = [],
        filter: Filter = .all
    ) {
        self.sourceId = sourceId
        self.kind = kind
        self.min = min
        self.max = max
        self.excludedTaskIds = excludedTaskIds
        self.filter = filter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try container.decode(String.self, forKey: .sourceId)
        kind = try container.decode(Kind.self, forKey: .kind)
        min = try container.decode(Int.self, forKey: .min)
        // JSON `null` and an absent key both decode to nil (lenient — the
        // TS encoder always writes the key, `null` for the "all" latch).
        max = try container.decodeIfPresent(Int.self, forKey: .max)
        excludedTaskIds = try container.decode([String].self, forKey: .excludedTaskIds)
        filter = try container.decode(Filter.self, forKey: .filter)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(kind, forKey: .kind)
        try container.encode(min, forKey: .min)
        // Force-encode `null` for the "all" latch — web's shape check
        // requires the key to be present (`max === null || number`).
        if let max = max {
            try container.encode(max, forKey: .max)
        } else {
            try container.encodeNil(forKey: .max)
        }
        try container.encode(excludedTaskIds, forKey: .excludedTaskIds)
        try container.encode(filter, forKey: .filter)
    }
}
