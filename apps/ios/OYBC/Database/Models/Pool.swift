import Foundation
import GRDB

/// Pool — Task Pools + Recurring Boards Rework (P1). iOS twin of TypeScript
/// `Pool` in `@oybc/shared` (`packages/shared/src/types/pool.ts`).
///
/// A user-named collection of task REFERENCES (never copies) that lives in
/// the Tasks tab as a first-class entity (P2+). Any board — one-off, core,
/// or repeating — may *draw from* a pool at creation; pools themselves carry
/// NO board actions (locked): no "use in board", no FEEDS control, no
/// default pinning (docs/POOLS_RECURRING.md §Surfaces item 1).
///
/// - A task may belong to many pools. Deleting a pool never deletes its
///   tasks. **Detachment is derived, not cascaded**: mix resolution
///   (`PoolMix.resolveMix`) and core-defaults resolution simply skip
///   `isDeleted` pools at read time — no multi-record cascade write, no LWW
///   race.
/// - **Health is derived, never stored**: resolvable non-deleted `taskIds`
///   count vs a consumer's `fillableCellCount`.
/// - `taskIds` is stored as a JSON-string TEXT column (same pattern as
///   `RecurringBoardTemplate.seedTaskIds` and `Board.completedLineIds`)
///   since SQLite has no native array type.
/// - `memberVary` (pool-level default dice, docs/BOARD_SOURCES.md §Member
///   rules → *Pool-level defaults*, 2026-10-06) is a JSON-string TEXT column
///   added in GRDB v38 (nullable; the `manualTaskVary` codec). A missing /
///   NULL column decodes to `[:]` and the encoder ALWAYS writes the map, so
///   the wire doc carries `memberVary: {}` for a pool without defaults —
///   web's `PoolSchema` defaults a missing key to `{}` the same way.
///
/// Canonical design: docs/POOLS_RECURRING.md §Data model → New entity: Pool.
struct Pool: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Configuration
    var name: String
    /// Ordered task ID references into the task library — never copies.
    /// Soft-deleted tasks are NOT auto-removed from this list; consumers
    /// (`PoolMix.resolveMix`, core-defaults resolution) filter at read time.
    var taskIds: [String]
    /// Task id → default dice level. Only `.little` / `.lot` are ever stored
    /// (`BoardSources.prunePoolMemberVary` drops `.off`, as `withMemberRule`
    /// prunes a `vary: 0` off a source rule); an id missing from the map has
    /// no default. Read by `BoardSources.seedMemberRulesFromPool` (the
    /// Sources sheet) and `BoardSources.effectiveMemberRules` (spawn /
    /// prefill fallback).
    var memberVary: [String: VaryLevel]

    // Timestamps
    var createdAt: String
    var updatedAt: String

    // Sync metadata
    var lastSyncedAt: String?
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?

    // MARK: - Database Configuration

    static let databaseTableName = "pools"

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, name, taskIds, memberVary
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }

    init(
        id: String,
        userId: String,
        name: String,
        taskIds: [String],
        memberVary: [String: VaryLevel] = [:],
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
        self.taskIds = taskIds
        self.memberVary = memberVary
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

        // Decode taskIds from JSON-string TEXT column (mirror of
        // DefaultPool.taskIds / RecurringBoardTemplate.seedTaskIds).
        if let jsonString = try container.decodeIfPresent(String.self, forKey: .taskIds),
           let data = jsonString.data(using: .utf8) {
            taskIds = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            taskIds = []
        }

        // Pool-level default dice — JSON-string TEXT column (v38). A row
        // written before the column existed (NULL) or a pulled doc without
        // the key decodes to an EMPTY map; same tri-state-tolerant read as
        // `RecurringBoardTemplate.manualTaskVary`, collapsed onto `[:]`.
        if let jsonString = (try? container.decodeIfPresent(String.self, forKey: .memberVary)) ?? nil,
           let data = jsonString.data(using: .utf8) {
            memberVary = (try? JSONDecoder().decode([String: VaryLevel].self, from: data)) ?? [:]
        } else {
            memberVary = [:]
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
        try container.encode(name, forKey: .name)

        // Encode taskIds as JSON-string TEXT column.
        if let data = try? JSONEncoder().encode(taskIds),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .taskIds)
        } else {
            try container.encode("[]", forKey: .taskIds)
        }

        // ALWAYS written (`{}` when empty) so a clear propagates as an
        // overwrite on the wire, never as a field delete.
        if let data = try? JSONEncoder().encode(memberVary),
           let jsonString = String(data: data, encoding: .utf8) {
            try container.encode(jsonString, forKey: .memberVary)
        } else {
            try container.encode("{}", forKey: .memberVary)
        }

        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(version, forKey: .version)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
