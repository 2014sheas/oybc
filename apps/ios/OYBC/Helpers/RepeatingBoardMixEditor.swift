import Foundation

/// RepeatingBoardMixEditor — Task Pools + Recurring Boards Rework (P7),
/// docs/POOLS_RECURRING.md §Surfaces item 9 ("roster edit sheet").
///
/// Pure, testable extraction of `RepeatingBoardEditSheetView`'s pool-toggle
/// and task-chip mutators. Operates DIRECTLY on a `RecurringBoardTemplate`'s
/// native `poolIds` / `manualTaskIds` / `removedTaskIds` fields — unlike
/// `BoardWizardViewModel.pullPool`/`untogglePool` (which maintain a
/// separate flat `selectedTaskIds` the wizard's own UI needs for
/// drag-reorder / center-pinning), the roster editor has no such derived
/// selection to keep in sync: the displayed mix is simply
/// `PoolMix.resolveMix(template, ...)`, recomputed live from these three
/// fields on every render. So a pool toggle only ever needs to mutate
/// `poolIds` (+ `removedTaskIds` on untoggle) — never re-derives the
/// union/removal math itself, always delegates to `PoolMix`.
///
/// Every function returns a NEW `RecurringBoardTemplate` (never mutates in
/// place) so the view can assign straight back to its `@State private var
/// draft`.
///
/// Board Creation Split (PR B) retired `RepeatingBoardEditSheetView` (Board
/// Settings' "Edit tasks" now opens the full `BoardWizardView` in edit mode
/// instead), so this helper currently has no production caller — left in
/// place (with `RepeatingBoardMixEditorTests` still guarding it) as a
/// deferred cleanup rather than deleted alongside the view it was
/// extracted from, since a future roster-only quick-edit surface could
/// still want this exact pure logic.
enum RepeatingBoardMixEditor {

    /// Pull a pool in — appends to `poolIds` if not already present and
    /// the pool is resolvable (present, non-deleted). No-op (returns
    /// `template` unchanged) otherwise.
    static func pullPool(
        _ poolId: String,
        into template: RecurringBoardTemplate,
        poolsById: [String: Pool]
    ) -> RecurringBoardTemplate {
        guard poolsById[poolId]?.isDeleted == false else { return template }
        var ids = template.poolIds ?? []
        guard !ids.contains(poolId) else { return template }
        ids.append(poolId)
        var updated = template
        updated.poolIds = ids
        return updated
    }

    /// Untoggle a pool — drops it from `poolIds` and clears exactly the
    /// removal entries no longer supplied by any REMAINING pulled pool
    /// (`PoolMix.clearRemovalsForUntoggle` — the same call
    /// `BoardWizardViewModel.untogglePool` makes). The manual layer is
    /// never touched.
    static func untogglePool(
        _ poolId: String,
        from template: RecurringBoardTemplate,
        poolsById: [String: Pool]
    ) -> RecurringBoardTemplate {
        var updated = template
        updated.removedTaskIds = PoolMix.clearRemovalsForUntoggle(
            template, untoggledPoolId: poolId, poolsById: poolsById
        )
        updated.poolIds = (template.poolIds ?? []).filter { $0 != poolId }
        return updated
    }

    /// Removes ONE task from the displayed mix regardless of its source
    /// (manual or pool-sourced) — mirrors the wizard Tasks step's
    /// per-row remove (`BoardWizardViewModel.toggleTaskSelection`'s
    /// deselect branch): drop it from `manualTaskIds` if present, and if
    /// it's still supplied by a currently-attached pool, record a
    /// removal so it doesn't silently reappear from that pool's supply.
    static func removeTaskFromMix(
        _ taskId: String,
        from template: RecurringBoardTemplate,
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> RecurringBoardTemplate {
        var updated = template
        var manual = updated.manualTaskIds ?? []
        manual.removeAll { $0 == taskId }
        updated.manualTaskIds = manual
        if isSuppliedByAttachedPool(taskId, template: updated, poolsById: poolsById, tasksById: tasksById) {
            var removed = updated.removedTaskIds ?? []
            if !removed.contains(taskId) { removed.append(taskId) }
            updated.removedTaskIds = removed
        }
        return updated
    }

    /// Adds a task to the manual layer, clearing any stale removal for it
    /// — re-adding a previously-removed task should actually show it
    /// (manual always wins per `PoolMix.resolveMix`'s formula).
    static func addManualTask(
        _ taskId: String,
        to template: RecurringBoardTemplate
    ) -> RecurringBoardTemplate {
        var updated = template
        var manual = updated.manualTaskIds ?? []
        if !manual.contains(taskId) { manual.append(taskId) }
        updated.manualTaskIds = manual
        var removed = updated.removedTaskIds ?? []
        removed.removeAll { $0 == taskId }
        updated.removedTaskIds = removed
        return updated
    }

    /// True when `taskId` is in the resolvable supply of any pool
    /// currently attached to `template` — a non-deleted pool in
    /// `template.poolIds` whose raw `taskIds` contains it, and the task
    /// itself isn't soft-deleted. Mirrors
    /// `BoardWizardViewModel.isSuppliedByPulledPool`.
    static func isSuppliedByAttachedPool(
        _ taskId: String,
        template: RecurringBoardTemplate,
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> Bool {
        if let task = tasksById[taskId], task.isDeleted { return false }
        for poolId in (template.poolIds ?? []) {
            guard let pool = poolsById[poolId], !pool.isDeleted else { continue }
            if pool.taskIds.contains(taskId) { return true }
        }
        return false
    }
}
