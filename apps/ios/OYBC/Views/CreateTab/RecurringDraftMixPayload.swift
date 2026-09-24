import Foundation

/// Wizard pool-mix persistence payloads — extracted from
/// `BoardWizardViewModel.swift` in the Board Sources rework (P1) so the
/// frozen god-file shrinks instead of growing (ROADMAP B6 posture).

/// Minimal `PoolMixSource` wrapper for the wizard's raw pool-mix state,
/// which isn't itself a `RecurringBoardTemplate`. Used by
/// `BoardWizardViewModel`'s `PoolMix.resolveMix` call. (Pre-P4 it also fed
/// `BoardWizardPersist.persistRecurringTemplate`'s shape-scoped legacy
/// write-through, which P4 retired — persistence now reads
/// `pulledPoolIds`/`manualTaskIds`/`removedTaskIds` directly.)
/// Mirrors the ad-hoc fixture pattern `OYBCTests/PoolMixTests.swift`'s
/// `PoolMixInput` already uses. Internal (not `private`) so both files see it.
struct WizardPoolMixRecord: PoolMixSource {
    var poolIds: [String]?
    var manualTaskIds: [String]?
    var removedTaskIds: [String]?
}

/// Board Creation Split (PR B) — the JSON payload snapshotted into
/// `Board.recurringDraftMix` so a wizard draft's FULL pool mix survives a
/// save/resume round-trip. A pool can be larger than its grid (overfill is
/// the variety mechanism, per docs/POOLS_RECURRING.md §Behavior
/// invariants), so the placed `BoardTask` rows alone would silently
/// truncate the pool on resume — this payload is the source of truth for
/// resuming a draft's selection instead.
///
/// **v2 (Board Sources P1, docs/BOARD_SOURCES.md):** the payload gains
/// `v: 2` + `sources` (the canonical shape) and is now written for
/// ONE-OFF drafts too. The legacy trio is still written alongside (an old
/// client decodes it unchanged); a v1 blob decodes forward by deriving
/// `sources` from the trio (`BoardSources.sourcesFromMixFields` — the
/// same `[0, all]` mapping web's codec uses). Web twin:
/// `apps/web/src/db/recurringDraftMix.ts`.
struct RecurringDraftMixPayload: Codable {
    var poolIds: [String]
    var manualTaskIds: [String]
    var removedTaskIds: [String]
    /// Board Sources P1 — canonical sources shape. Always populated on
    /// `decoded(from:)` (derived from the trio for a v1 blob); derived at
    /// `encoded()` time when constructed without one (the wizard UI can
    /// only express [0, all] pool pulls until P2).
    var sources: [BoardSource]?
    /// §Member rules B1 (inert) — dice for hand-added counting members,
    /// keyed by task id. Always present on decode (`[:]` default) and
    /// OMITTED from the encoded blob when empty, so an existing draft
    /// re-encodes byte-identically. The blob version stays `2`: this is a
    /// purely additive key an older client ignores.
    var manualTaskVary: [String: VaryLevel]

    private enum CodingKeys: String, CodingKey {
        case v, poolIds, manualTaskIds, removedTaskIds, sources
        case manualTaskVary
    }

    init(
        poolIds: [String],
        manualTaskIds: [String],
        removedTaskIds: [String],
        sources: [BoardSource]? = nil,
        manualTaskVary: [String: VaryLevel] = [:]
    ) {
        self.poolIds = poolIds
        self.manualTaskIds = manualTaskIds
        self.removedTaskIds = removedTaskIds
        self.sources = sources
        self.manualTaskVary = manualTaskVary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        poolIds = try container.decode([String].self, forKey: .poolIds)
        manualTaskIds = try container.decode([String].self, forKey: .manualTaskIds)
        removedTaskIds = try container.decode([String].self, forKey: .removedTaskIds)
        // v1 blobs (or a corrupt sources value) → nil here; `decoded(from:)`
        // derives from the trio so consumers always see a populated array.
        sources = try? container.decodeIfPresent([BoardSource].self, forKey: .sources)
        // Absent (every pre-B1 blob) or malformed → no dice. Ruling R11:
        // Swift's `VaryLevel: Int` decode rejects the WHOLE map on one
        // out-of-range level where web's codec drops only the bad key —
        // both converge to "no dice" for that key, and B3 only ever writes
        // valid levels, so the difference is unobservable in practice.
        let decodedVary = try? container.decodeIfPresent(
            [String: VaryLevel].self,
            forKey: .manualTaskVary
        )
        manualTaskVary = decodedVary ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .v)
        try container.encode(poolIds, forKey: .poolIds)
        try container.encode(manualTaskIds, forKey: .manualTaskIds)
        try container.encode(removedTaskIds, forKey: .removedTaskIds)
        let resolvedSources = sources ?? BoardSources.sourcesFromMixFields(
            poolIds: poolIds,
            removedTaskIds: removedTaskIds
        )
        try container.encode(resolvedSources, forKey: .sources)
        // §Member rules — THE rule for an empty `manualTaskVary`, on either
        // record and on either platform: OMIT it (final review M2). An
        // existing draft's blob is then unchanged, and the four write sites
        // (this blob ↔ web's `encodeRecurringDraftMix`; the
        // `RecurringBoardTemplate` CREATE on both platforms) agree. Decoders
        // read a missing key as "no dice", so nothing depends on the
        // difference — but one rule stated once beats four judgement calls.
        // (The `RecurringBoardTemplate` UPDATE path is the deliberate
        // exception: there an empty map means "clear the dice", which an
        // omission can't say.)
        if !manualTaskVary.isEmpty {
            try container.encode(manualTaskVary, forKey: .manualTaskVary)
        }
    }

    /// Encodes to the JSON string stored on `Board.recurringDraftMix`.
    /// Returns nil on an encoding failure so the caller can omit the
    /// field entirely, matching the rest of the codebase's JSON-string
    /// column encode-fallback posture (never a garbage/partial string).
    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes from `Board.recurringDraftMix`. Returns an all-empty mix
    /// (never nil) for a missing or malformed string so hydration always
    /// has a well-formed shape to resolve against — an empty mix just
    /// means "no tasks yet", not an error. `sources` is always populated
    /// (derived from the trio for v1 blobs).
    static func decoded(from jsonString: String?) -> RecurringDraftMixPayload {
        guard let jsonString, let data = jsonString.data(using: .utf8),
              var payload = try? JSONDecoder().decode(RecurringDraftMixPayload.self, from: data)
        else {
            return RecurringDraftMixPayload(
                poolIds: [], manualTaskIds: [], removedTaskIds: [], sources: [],
                manualTaskVary: [:]
            )
        }
        if payload.sources == nil {
            payload.sources = BoardSources.sourcesFromMixFields(
                poolIds: payload.poolIds,
                removedTaskIds: payload.removedTaskIds
            )
        }
        return payload
    }
}

