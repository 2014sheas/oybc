import Foundation

/// PoolHealth — Task Pools + Recurring Boards Rework (P2). Swift port of
/// `packages/shared/src/algorithms/poolHealth.ts`, case-for-case. Pure
/// functions; no persistence, no platform-specific code beyond Foundation.
/// Both platforms must keep these in lockstep — when the TS version
/// changes, mirror it here in the same PR.
///
/// Health is derived, never stored (docs/POOLS_RECURRING.md §Data model →
/// New entity: Pool): pool cards, roster rows, and (while it exists)
/// template rows all derive from this single source, so a fix here heals
/// every surface at once.
///
/// Canonical design: docs/POOLS_RECURRING.md §Data model (health derived) +
/// §Behavior invariants (fillable floor everywhere).
enum PoolHealth {

    /// A single repeating board (spawn record) that is short on this pool —
    /// i.e. its resolved mix doesn't reach its own fillable floor. Only
    /// `shortBy > 0` templates ever appear as a consumer; a template that
    /// pulls the pool but is otherwise fully supplied is not included.
    struct Consumer: Equatable {
        let templateId: String
        let templateName: String
        let timeframe: Timeframe
        /// The consuming template's board size. Not read by the card's
        /// combined `formatPoolShortSummary` line (which only counts
        /// consumers), but kept on the consumer for any other per-template
        /// rendering.
        let boardSize: Int
        /// How many more resolvable tasks the template's mix needs. Always > 0.
        let shortBy: Int
    }

    /// Result of `computePoolHealth`.
    struct Result: Equatable {
        /// Resolvable (present, non-deleted) count of `pool.taskIds`.
        let taskCount: Int
        /// Every non-deleted, active template that pulls this pool AND is
        /// short on its own fillable floor, in `templates` input order.
        let consumers: [Consumer]
    }

    /// Derives a pool's resolvable task count and the set of repeating
    /// boards (spawn records) that consume it and are short.
    ///
    /// A template is a consumer only when ALL of:
    ///   - not soft-deleted (`isDeleted == false`)
    ///   - active (`isActive == true`) — a paused template can't spawn, so
    ///     a short mix there isn't actionable
    ///   - its `poolIds` includes `pool.id`
    ///   - its resolved mix (`PoolMix.resolveMix`, reused verbatim — no
    ///     reimplementation) falls short of its own fillable floor
    ///     (`recurringTemplateFillableCellCount`)
    ///
    /// Callers compute this ONCE per screen (batched over every pool) —
    /// never per-card (see `PoolsBrowseView` / `PoolEditSheetView`).
    ///
    /// - Parameters:
    ///   - pool: The pool whose health is being derived.
    ///   - templates: Candidate consumers — filtered internally to
    ///     non-deleted + active.
    ///   - poolsById: Lookup for every id in each template's `poolIds`
    ///     (passed to `PoolMix.resolveMix`).
    ///   - tasksById: Lookup for filtering `pool.taskIds` / each
    ///     template's resolved mix.
    static func computePoolHealth(
        _ pool: Pool,
        templates: [RecurringBoardTemplate],
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> Result {
        let taskCount = pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted
        }.count

        var consumers: [Consumer] = []
        for template in templates {
            guard !template.isDeleted, template.isActive else { continue }
            guard (template.poolIds ?? []).contains(pool.id) else { continue }

            let mix = PoolMix.resolveMix(template, poolsById: poolsById, tasksById: tasksById)
            let floor = recurringTemplateFillableCellCount(
                boardSize: template.boardSize,
                centerSquareType: template.centerSquareType
            )
            let shortBy = max(0, floor - mix.taskIds.count)
            guard shortBy > 0 else { continue }

            consumers.append(Consumer(
                templateId: template.id,
                templateName: template.name,
                timeframe: template.timeframe,
                boardSize: template.boardSize,
                shortBy: shortBy
            ))
        }

        return Result(taskCount: taskCount, consumers: consumers)
    }

    /// Formats the single, cross-platform-shared pool-CARD warning line —
    /// board-count syntax, combining every short consumer into one line
    /// instead of one line per consumer (owner decision, 2026-07-20; see
    /// docs/POOLS_RECURRING.md §Surfaces item 1): `""` when there are no
    /// short consumers (render nothing), `"Short on 1 board"` for exactly
    /// one, or `"Short on {N} boards"` for two or more. Web and iOS render
    /// this string verbatim — do not hand-roll the copy on either platform.
    static func formatPoolShortSummary(_ consumers: [Consumer]) -> String {
        if consumers.isEmpty { return "" }
        if consumers.count == 1 { return "Short on 1 board" }
        return "Short on \(consumers.count) boards"
    }
}
