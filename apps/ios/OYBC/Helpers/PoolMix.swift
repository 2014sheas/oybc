import Foundation

/// PoolMix — Task Pools + Recurring Boards Rework (P1). Swift port of
/// `packages/shared/src/algorithms/poolMix.ts`, case-for-case. Pure
/// functions; no persistence, no platform-specific code beyond Foundation.
/// Both platforms must keep these in lockstep — when the TS version
/// changes, mirror it here in the same PR.
///
/// **Mix = (union(pools' resolvable tasks) − removedTaskIds) + manualTaskIds.**
/// Evaluation order is normative: removals subtract from the pool union
/// FIRST, then the manual layer adds — so a task id present in BOTH
/// `manualTaskIds` and `removedTaskIds` is IN the mix (manual wins;
/// removals only ever suppress pool-sourced supply). Deleted pools and
/// deleted tasks are skipped at resolution time (derived detachment — no
/// cascade write, no LWW race). Deterministic order: first-seen pool order
/// (in `poolIds` order, then within each pool's own `taskIds` order),
/// followed by any manual-only task ids in `manualTaskIds` order.
///
/// **Removals semantics** (flat `[String]`, no per-pool attribution): a
/// removal entry suppresses that task from the pool union regardless of
/// which pool(s) supply it. Removal entries for tasks not supplied by any pulled pool are
/// stale-inert: harmless, never an error, cleaned opportunistically on save.
///
/// Canonical design: docs/POOLS_RECURRING.md §Changed: the spawn record
/// (recurrence as board property) — the worked example there is the
/// required P1 unit-test vector set (`OYBCTests/PoolMixTests.swift`).
enum PoolMix {

    /// Resolvable, non-deleted supply for one pool: its own `taskIds`,
    /// filtered to tasks present in `tasksById`, not soft-deleted, and
    /// supply-eligible (`BoardSources.isSourceSupplyTask` — achievements
    /// are banned from pools, owner decision 2026-09-10; matches
    /// `poolSourceSupplyById` so the legacy mix/health layer never counts
    /// what the sources layer won't deal). Order preserved.
    private static func resolvablePoolSupply(_ pool: Pool, tasksById: [String: Task]) -> [String] {
        pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted && BoardSources.isSourceSupplyTask(task)
        }
    }

    /// Wizard "PULL IN A POOL" action (P3) — computes the taskIds to ADD to
    /// the wizard's flat `selectedTaskIds` when the user toggles a pool ON.
    ///
    /// Returns the pool's resolvable supply minus anything currently
    /// suppressed by `removedTaskIds` — a removal persists across a fresh
    /// pull (clearing a removal is an untoggle-time concern, never a
    /// pull-time one).
    ///
    /// TS twin: `poolMix.ts`'s `resolvePoolPullAdditions` — keep in sync.
    ///
    /// - Parameters:
    ///   - poolId: The pool being pulled in.
    ///   - removedTaskIds: The wizard's current removal bookkeeping.
    ///   - poolsById: Lookup for `poolId`. Missing or soft-deleted ⇒ no additions.
    ///   - tasksById: Lookup used to filter the pool's `taskIds` to resolvable tasks.
    /// - Returns: Task ids to union into the selection, in the pool's own stored order.
    static func resolvePoolPullAdditions(
        _ poolId: String,
        removedTaskIds: [String],
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> [String] {
        guard let pool = poolsById[poolId], !pool.isDeleted else { return [] }
        let removedSet = Set(removedTaskIds)
        return resolvablePoolSupply(pool, tasksById: tasksById).filter { !removedSet.contains($0) }
    }

    /// Resolves a spawn record's `poolIds` / `manualTaskIds` /
    /// `removedTaskIds` into the concrete mix per the normative formula
    /// (see type doc above).
    ///
    /// - Parameters:
    ///   - record: The record's pool-mix fields — a `RecurringBoardTemplate`
    ///     may be passed directly (it conforms to `PoolMixSource`). Missing
    ///     arrays are treated as empty.
    ///   - poolsById: Lookup for every id in `record.poolIds`. A missing or
    ///     soft-deleted entry is skipped (derived detachment) — never an
    ///     error.
    ///   - tasksById: Lookup for filtering each pool's `taskIds` to
    ///     currently-resolvable (non-deleted, present) tasks. NOT applied
    ///     to `manualTaskIds` — the manual layer is caller-curated (the
    ///     wizard/roster UI only lets a user pick live tasks) and passes
    ///     through verbatim, mirroring `buildSpawnPlacement`'s "caller
    ///     filters" contract.
    static func resolveMix(
        _ record: PoolMixSource,
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> ResolveMixResult {
        let poolIds = record.poolIds ?? []
        let manualTaskIds = record.manualTaskIds ?? []
        let removedTaskIds = record.removedTaskIds ?? []
        let removedSet = Set(removedTaskIds)
        let manualSet = Set(manualTaskIds)

        // Build the pool union in first-seen order, and the per-pool
        // supply map.
        var suppliedByPool: [String: [String]] = [:]
        var unionOrder: [String] = []
        var unionSeen = Set<String>()

        for poolId in poolIds {
            guard let pool = poolsById[poolId], !pool.isDeleted else { continue }
            // A duplicate poolId in `poolIds` re-derives the same supply —
            // harmless, just overwrites the map entry with an identical
            // value.
            let supply = resolvablePoolSupply(pool, tasksById: tasksById)
            suppliedByPool[poolId] = supply
            for taskId in supply where !unionSeen.contains(taskId) {
                unionSeen.insert(taskId)
                unionOrder.append(taskId)
            }
        }

        // Subtract removals (unless the manual layer overrides — manual
        // wins), then append any manual-only ids not already present.
        var resultSeen = Set<String>()
        var taskIds: [String] = []

        for taskId in unionOrder {
            if removedSet.contains(taskId) && !manualSet.contains(taskId) { continue }
            taskIds.append(taskId)
            resultSeen.insert(taskId)
        }
        for taskId in manualTaskIds where !resultSeen.contains(taskId) {
            taskIds.append(taskId)
            resultSeen.insert(taskId)
        }

        return ResolveMixResult(taskIds: taskIds, suppliedByPool: suppliedByPool)
    }

    /// `PoolSchema.name` is bounded to 120 chars (`z.string().min(1).max(120)`,
    /// `schemas.ts`) — mirrored by the write-helper layer here. Every site
    /// that MINTS a Pool by appending a fixed suffix word to a source name
    /// (a `RecurringBoardTemplate.name` — itself bounded to 120 — or a
    /// fixed timeframe label) must clamp the source FIRST, or the appended
    /// result can exceed 120 and fail schema validation on the next
    /// device's pull — the doc never lands there, silently, since the
    /// mint itself succeeds locally (no local validation on write).
    ///
    /// Used by the P1 migration's two mint sites (`MigrationV25Helpers.swift`
    /// / `migrationV16.ts`, `" default"` / `" pool"` suffixes). Swift twin
    /// of `poolMix.ts`'s `clampMintedPoolName` — keep them in sync.
    ///
    /// - Parameters:
    ///   - sourceName: The un-suffixed source text (template name / timeframe label).
    ///   - suffix: The word appended after a single space (e.g. `"pool"`, `"default"`).
    ///   - maxLen: The schema's max length. Defaults to `PoolSchema`'s 120.
    /// - Returns: `"<clamped sourceName> <suffix>"`, guaranteed
    ///   `.utf16.count <= maxLen`.
    ///
    /// - Note: `PoolSchema.name` is `z.string().max(120)`, which measures
    ///   **UTF-16 code units** (JS string length). We clamp by the same unit
    ///   — NOT Swift `Character`s — so a non-BMP-heavy name (emoji, ZWJ
    ///   sequences) can't mint a name iOS thinks is ≤120 but web rejects on
    ///   pull as >120, stranding the pool doc on the peer. Characters are
    ///   accumulated whole so a surrogate pair is never split mid-clamp.
    static func clampMintedPoolName(_ sourceName: String, suffix: String, maxLen: Int = 120) -> String {
        let suffixWithSpace = " \(suffix)"
        let maxSourceUnits = max(0, maxLen - suffixWithSpace.utf16.count)
        let units = Array(sourceName.utf16)
        guard units.count > maxSourceUnits else { return "\(sourceName)\(suffixWithSpace)" }
        var end = maxSourceUnits
        // If the last kept unit is a high surrogate (0xD800–0xDBFF), its low
        // partner is being cut — drop the whole char instead of splitting it.
        if end > 0, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        let clampedSource = String(decoding: units[0..<end], as: UTF16.self)
        return "\(clampedSource)\(suffixWithSpace)"
    }
}

/// One freshly-spawned board's provenance breakdown — how many of the
/// dealt cells came from the pool union vs. the manual layer. Powers the
/// Board-screen spawn-success note (Task Pools + Recurring Boards Rework,
/// P6 — docs/POOLS_RECURRING.md §Surfaces item 7).
struct SpawnProvenanceSummary {
    /// Cells actually dealt onto the board (excludes the FREE-center cell,
    /// which is never a Task placement).
    let dealt: Int
    /// The achievable pool size the deal was drawn from — may exceed `dealt`
    /// (loose-fit: extras shuffle in per window, per docs/POOLS_RECURRING.md
    /// §Behavior invariants).
    let mixSize: Int
    /// Of the dealt cells, how many came from the pool union (i.e. NOT in
    /// `manualTaskIds`).
    let poolSourcedCount: Int
    /// Of the dealt cells, how many came from the manual layer.
    let manualSourcedCount: Int
}

extension PoolMix {
    /// Sources-native spawn-provenance summary (loose-ends sweep
    /// 2026-09-09) for records that may carry board-kind sources or
    /// ranges: `mixSize` is the honest achievable pool size (caps, cap
    /// overlap, counter-family rule). (The legacy pool-trio overload was
    /// deleted in the 2026-09 audit — it had no production caller.) TS
    /// twin: `summarizeSpawnProvenanceFromSupplies`.
    ///
    /// - Parameters:
    ///   - supplies: The record's resolved source supplies (the SAME
    ///     platform resolution the spawn used — pool + board kinds).
    ///   - manualTaskIds: The record's hand-added layer.
    ///   - counterFamilyByTaskId: `BoardSources.buildCounterFamilyMap` over
    ///     the task universe (so `mixSize` counts a counter family once).
    ///   - dealtTaskIds: Task ids actually placed on the spawned board.
    /// - Returns: The dealt/mix counts split by pool-sourced vs manual-sourced.
    static func summarizeSpawnProvenance(
        supplies: [BoardSources.Supply],
        manualTaskIds: [String],
        counterFamilyByTaskId: [String: String],
        dealtTaskIds: [String]
    ) -> SpawnProvenanceSummary {
        let manualSet = Set(manualTaskIds)
        let manualSourcedCount = dealtTaskIds.filter { manualSet.contains($0) }.count
        return SpawnProvenanceSummary(
            dealt: dealtTaskIds.count,
            mixSize: BoardSources.computeAchievablePoolSize(
                supplies: supplies,
                manualTaskIds: manualTaskIds,
                counterFamilyByTaskId: counterFamilyByTaskId
            ).size,
            poolSourcedCount: dealtTaskIds.count - manualSourcedCount,
            manualSourcedCount: manualSourcedCount
        )
    }

    /// Renders a `SpawnProvenanceSummary` into the Board-screen note copy,
    /// e.g. `"Picked 8 of 10 — 7 from the pool, 1 added today"`.
    ///
    /// Deliberate wording deviation from docs/POOLS_RECURRING.md §Surfaces
    /// item 7's illustrative example ("9 from **defaults**") — that phrasing
    /// is specific to the P5 `CoreBoardDefault` feature. This note is
    /// generic to ANY freshly-spawned board, including a "repeat this
    /// board" spawn (100% manual, no pool involved), so it always says
    /// "from the pool" for pool-sourced cells. "added today" is verbatim
    /// per the copy rules ("from" never "deals from").
    static func formatSpawnProvenanceNote(_ summary: SpawnProvenanceSummary) -> String {
        var parts: [String] = []
        // "pulled in" (not "from the pool") — squares can come from pulled
        // BOARDS too since Board Sources; the wizard's own verb is "pull".
        if summary.poolSourcedCount > 0 { parts.append("\(summary.poolSourcedCount) pulled in") }
        if summary.manualSourcedCount > 0 { parts.append("\(summary.manualSourcedCount) added today") }
        let breakdown = parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
        return "Picked \(summary.dealt) of \(summary.mixSize)\(breakdown)"
    }
}

/// The subset of a spawn record's fields `PoolMix.resolveMix` needs.
/// Matches `RecurringBoardTemplate`'s additive P1 fields directly (all
/// optional, so a `RecurringBoardTemplate` — migrated or not — can be
/// passed as-is). Missing fields default to empty per-array. Mirrors the TS
/// `PoolMixSource` interface.
protocol PoolMixSource {
    var poolIds: [String]? { get }
    var manualTaskIds: [String]? { get }
    var removedTaskIds: [String]? { get }
}

extension RecurringBoardTemplate: PoolMixSource {}

/// Result of `PoolMix.resolveMix`.
struct ResolveMixResult {
    /// The resolved mix, deduplicated, in deterministic order: first-seen
    /// pool order, then any manual-only ids in `manualTaskIds` order. This
    /// is the array the spawn path hands to `buildSpawnPlacement`'s pool
    /// (after a task-id → `Task` lookup) exactly as `seedTaskIds` used to
    /// be.
    let taskIds: [String]
    /// Per-pulled-pool resolvable supply — that pool's own `taskIds`,
    /// filtered to non-deleted tasks, in the pool's own stored order.
    /// Keyed by pool id; a pulled pool that is missing from `poolsById` or
    /// soft-deleted has NO entry (not an empty-array entry) — it
    /// contributed nothing, matching derived detachment. Powers
    /// provenance UI ("from Morning Kickstart").
    let suppliedByPool: [String: [String]]
}
