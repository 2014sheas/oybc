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
/// which pool(s) supply it. Untoggling a pool (`clearRemovalsForUntoggle`)
/// clears exactly the removal entries whose task is no longer supplied by
/// any REMAINING pulled pool — removals for still-supplied tasks persist.
/// Removal entries for tasks not supplied by any pulled pool are
/// stale-inert: harmless, never an error, cleaned opportunistically on save.
///
/// Canonical design: docs/POOLS_RECURRING.md §Changed: the spawn record
/// (recurrence as board property) — the worked example there is the
/// required P1 unit-test vector set (`OYBCTests/PoolMixTests.swift`).
enum PoolMix {

    /// Resolvable, non-deleted supply for one pool: its own `taskIds`,
    /// filtered to tasks present in `tasksById` and not soft-deleted.
    /// Order preserved.
    private static func resolvablePoolSupply(_ pool: Pool, tasksById: [String: Task]) -> [String] {
        pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted
        }
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

    /// Computes the surviving `removedTaskIds` after the user untoggles
    /// (pulls out) one pool. Clears exactly the removal entries whose task
    /// is no longer supplied by any of the REMAINING pulled pools;
    /// removals for still-supplied tasks persist untouched.
    ///
    /// Supply here is checked structurally — a remaining pool's raw
    /// `taskIds` membership (not filtered by task-deletion) — since this
    /// is a removal-bookkeeping concern, distinct from mix *resolution*
    /// (`resolveMix`, which additionally filters deleted tasks for the
    /// actual spawn mix). A soft-deleted remaining pool contributes no
    /// supply here either, matching derived detachment.
    ///
    /// - Parameters:
    ///   - record: Only `poolIds` and `removedTaskIds` are read.
    ///   - untoggledPoolId: The pool id the user just pulled out.
    ///   - poolsById: Lookup for the remaining pools' `taskIds`.
    /// - Returns: The new `removedTaskIds` array (a subset of the input).
    static func clearRemovalsForUntoggle(
        _ record: PoolMixSource,
        untoggledPoolId: String,
        poolsById: [String: Pool]
    ) -> [String] {
        let remainingPoolIds = (record.poolIds ?? []).filter { $0 != untoggledPoolId }
        var remainingSupply = Set<String>()
        for poolId in remainingPoolIds {
            guard let pool = poolsById[poolId], !pool.isDeleted else { continue }
            for taskId in pool.taskIds { remainingSupply.insert(taskId) }
        }
        return (record.removedTaskIds ?? []).filter { remainingSupply.contains($0) }
    }

    /// True when a spawn record is "legacy shaped" — at most one pool, no
    /// manual additions, no removals. Covers BOTH:
    ///
    ///   - A genuinely un-migrated record (`poolIds`/`manualTaskIds`/
    ///     `removedTaskIds` all absent, `seedTaskIds` still authoritative).
    ///   - A migration- or legacy-create-minted record (`poolIds.count == 1`,
    ///     `manualTaskIds: []`, `removedTaskIds: []`).
    ///
    /// This is the ONLY shape the legacy template editor's write-through
    /// may mutate the linked Pool's `taskIds` for
    /// (docs/POOLS_RECURRING.md §Migration — "seedTaskIds end state"). A
    /// richer shape (2+ pools, any manual additions, or any removals) is
    /// NOT legacy-shaped — the defensive write-through fallback flattens
    /// to `manualTaskIds` and clears `poolIds`/`removedTaskIds` instead of
    /// touching a shared Pool.
    static func isLegacyShapedRecord(_ record: PoolMixSource) -> Bool {
        let poolCount = record.poolIds?.count ?? 0
        let manualCount = record.manualTaskIds?.count ?? 0
        let removedCount = record.removedTaskIds?.count ?? 0
        return poolCount <= 1 && manualCount == 0 && removedCount == 0
    }
}

/// The subset of a spawn record's fields `PoolMix.resolveMix` /
/// `clearRemovalsForUntoggle` / `isLegacyShapedRecord` need. Matches
/// `RecurringBoardTemplate`'s additive P1 fields directly (all optional, so
/// a `RecurringBoardTemplate` — migrated or not — can be passed as-is).
/// Missing fields default to empty per-array, per the "legacy shape"
/// definition above. Mirrors the TS `PoolMixSource` interface.
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
    /// provenance UI ("from Morning Kickstart") and
    /// `clearRemovalsForUntoggle`'s sibling logic.
    let suppliedByPool: [String: [String]]
}
