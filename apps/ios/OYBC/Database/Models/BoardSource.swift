import Foundation

/// How far a rolled target may wander from its nominal value — Board
/// Sources §Member rules (docs/BOARD_SOURCES.md, B1). Swift twin of the
/// TS `VaryLevel` union (`0 | 1 | 2`); the raw values ARE the wire format,
/// so the case names may change but the numbers never can.
///
/// `.off` = the target is exactly what the rule says; `.little` = ±20%;
/// `.lot` = ±50% (see `BoardSources.varyRange`).
enum VaryLevel: Int, Codable {
    case off = 0
    case little = 1
    case lot = 2
}

/// A rule for ONE part of a compound member — either a child of a Split-up
/// member or a child of a One-square compound. Swift twin of
/// `BoardSourcePartRule` in `packages/shared/src/types/boardSource.ts`.
///
/// All three fields are optional and stale-inert: a rule naming a child the
/// compound no longer has simply does nothing. `target` is honoured on
/// **board** sources only (a pool member offers vary / split /
/// part-exclusion and nothing else).
struct BoardSourcePartRule: Codable, Equatable {
    /// Explicit per-part target, overriding the pro-rated auto target.
    var target: Int?
    /// Per-part dice; overrides the member-level `vary` when present.
    var vary: VaryLevel?
    /// Split-up only: leave this part off the board. The last-part guard
    /// means excluding EVERY part is treated as excluding none.
    var excluded: Bool?

    init(target: Int? = nil, vary: VaryLevel? = nil, excluded: Bool? = nil) {
        self.target = target
        self.vary = vary
        self.excluded = excluded
    }
}

/// A rule for ONE member of a pulled source — Board Sources §Member rules
/// (docs/BOARD_SOURCES.md, B1). Swift twin of `BoardSourceMemberRule` in
/// `packages/shared/src/types/boardSource.ts`.
///
/// Every field is optional; an absent rule (or an all-nil one) means "place
/// this member as-is". `split == true` on a compound member with children
/// contributes those children INSTEAD of the compound (see
/// `BoardSources.applyMemberRules`); otherwise the compound stays One-square
/// and its `parts` re-target its children in place.
struct BoardSourceMemberRule: Codable, Equatable {
    /// Explicit target for a counting member; board sources only.
    var target: Int?
    /// Member-level dice. Deliberately IGNORED in split mode — a split
    /// part reads its own part rule instead.
    var vary: VaryLevel?
    /// Split up: contribute this compound's children instead of itself.
    var split: Bool?
    /// childTaskId → its part rule.
    var parts: [String: BoardSourcePartRule]?

    init(
        target: Int? = nil,
        vary: VaryLevel? = nil,
        split: Bool? = nil,
        parts: [String: BoardSourcePartRule]? = nil
    ) {
        self.target = target
        self.vary = vary
        self.split = split
        self.parts = parts
    }
}

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
    /// §Member rules (B1) — per-member rules keyed by task id. `nil` (and
    /// `[:]`) means "no rules"; both encode with the key OMITTED so a
    /// rule-less source serialises byte-identically to a pre-B1 blob.
    /// Stale-inert: a rule for an id this source doesn't supply is ignored.
    var memberRules: [String: BoardSourceMemberRule]?

    enum CodingKeys: String, CodingKey {
        case sourceId, kind, min, max, excludedTaskIds, filter
        case memberRules
    }

    init(
        sourceId: String,
        kind: Kind,
        min: Int = 0,
        max: Int? = nil,
        excludedTaskIds: [String] = [],
        filter: Filter = .all,
        memberRules: [String: BoardSourceMemberRule]? = nil
    ) {
        self.sourceId = sourceId
        self.kind = kind
        self.min = min
        self.max = max
        self.excludedTaskIds = excludedTaskIds
        self.filter = filter
        self.memberRules = memberRules
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
        // §Member rules (B1) — absent on every pre-B1 blob; lenient so an
        // old six-field source keeps decoding unchanged.
        memberRules = try container.decodeIfPresent(
            [String: BoardSourceMemberRule].self,
            forKey: .memberRules
        )
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
        // Omit the key entirely when there are no rules (nil OR empty) —
        // `.optional()` in the shared Zod schema, and it keeps a rule-less
        // source's blob byte-identical to what pre-B1 clients wrote.
        if let memberRules = memberRules, !memberRules.isEmpty {
            try container.encode(memberRules, forKey: .memberRules)
        }
    }
}
