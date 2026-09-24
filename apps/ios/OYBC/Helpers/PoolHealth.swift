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
    /// i.e. its ACHIEVABLE pool (every source + hand-adds, as the spawn
    /// resolves them) doesn't reach its own fillable floor. Only
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
        /// How many more tasks the template's achievable pool needs. Always > 0.
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

    /// One candidate consumer, PRE-RESOLVED: the template plus the size of
    /// the pool its next spawn could actually deal from. The size is
    /// DB-derived (board-kind sources need live boards), so the pure health
    /// function never computes it — callers resolve it through the
    /// sources-native roster path (`AppDatabase.fetchTemplateSupplyResolution`
    /// → `RecurringBoardTemplatesViewModel.computeRosterHealth`), i.e.
    /// `computeAchievablePoolSize` over every source (pool AND board kinds,
    /// ranges, exclusions, the done-filter, Split-up expansion, counter
    /// families) plus the resolvable hand-added layer. Web twin:
    /// `PoolHealthTemplateSupply`.
    struct TemplateSupply {
        let template: RecurringBoardTemplate
        /// Distinct tasks the template's next spawn could deal from.
        let achievableSize: Int
    }

    /// Whether `template` pulls `poolId` — one of its sources is that pool
    /// (kind `.pool`, `sourceId == poolId`). Read through
    /// `BoardSources.sourcesForRecord`, so an un-migrated v1 record's
    /// `poolIds` still count via the decode-time `[0, all]` mapping, but a
    /// record WITH `sources` is judged by them alone (its `poolIds` mirror
    /// is never consulted). Web twin: `templateConsumesPool`.
    ///
    /// - Parameters:
    ///   - template: The candidate consumer.
    ///   - poolId: The pool in question.
    /// - Returns: `true` when a pool-kind source names `poolId`.
    static func templateConsumesPool(_ template: RecurringBoardTemplate, poolId: String) -> Bool {
        BoardSources.sourcesForRecord(
            sources: template.sources,
            poolIds: template.poolIds,
            removedTaskIds: template.removedTaskIds
        ).contains { $0.kind == .pool && $0.sourceId == poolId }
    }

    /// Derives a pool's resolvable task count and the set of repeating
    /// boards (spawn records) that consume it and are short.
    ///
    /// A template is a consumer only when ALL of:
    ///   - not soft-deleted (`isDeleted == false`)
    ///   - active (`isActive == true`) — a paused template can't spawn, so
    ///     a short pool there isn't actionable
    ///   - one of its sources is this pool (`templateConsumesPool`)
    ///   - its pre-resolved `achievableSize` falls short of its own
    ///     fillable floor (`recurringTemplateFillableCellCount`)
    ///
    /// Callers compute this ONCE per screen (batched over every pool, via
    /// `computePoolHealthByPoolId`) — never per-card.
    ///
    /// - Parameters:
    ///   - pool: The pool whose health is being derived.
    ///   - templates: Candidate consumers with their resolved achievable
    ///     size — filtered internally to non-deleted + active + pulls-this-pool.
    ///   - tasksById: Lookup for filtering `pool.taskIds` into the card's
    ///     task count.
    /// - Returns: The pool's task count and its short consumers.
    static func computePoolHealth(
        _ pool: Pool,
        templates: [TemplateSupply],
        tasksById: [String: Task]
    ) -> Result {
        // Supply-eligible only (`isSourceSupplyTask` — achievements are
        // banned from pools) so the card's count and warnings agree with
        // what the wizard/spawn can actually pull.
        let taskCount = pool.taskIds.filter { taskId in
            guard let task = tasksById[taskId] else { return false }
            return !task.isDeleted && BoardSources.isSourceSupplyTask(task)
        }.count

        var consumers: [Consumer] = []
        for supply in templates {
            let template = supply.template
            guard !template.isDeleted, template.isActive else { continue }
            guard templateConsumesPool(template, poolId: pool.id) else { continue }

            let floor = recurringTemplateFillableCellCount(
                boardSize: template.boardSize,
                centerSquareType: template.centerSquareType
            )
            let shortBy = max(0, floor - supply.achievableSize)
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

    /// Batches `computePoolHealth` across every pool on a surface (the
    /// Pools browse cards, the pool picker's rows) — one pass over
    /// already-loaded lookups, never a per-card query. Twin of web's
    /// `computePoolHealthByPoolId` (`components/pools/poolHealthBatch.ts`).
    ///
    /// A template with no entry in `achievableTaskIdsByTemplateId` (still
    /// loading — pass `nil` for the whole map) is left out, so a surface
    /// never flashes a warning before its supplies resolve.
    ///
    /// - Parameters:
    ///   - pools: Every pool on the surface.
    ///   - templates: Candidate consumers (the user's repeating boards).
    ///   - achievableTaskIdsByTemplateId: The roster's achievable pick per
    ///     template (`RecurringBoardTemplatesViewModel.mixByTemplateId` /
    ///     `resolveAchievableTaskIds`), or `nil` while it loads.
    ///   - tasksById: id → Task, for each pool card's task count.
    /// - Returns: pool id → that pool's health.
    static func computePoolHealthByPoolId(
        pools: [Pool],
        templates: [RecurringBoardTemplate],
        achievableTaskIdsByTemplateId: [String: [String]]?,
        tasksById: [String: Task]
    ) -> [String: Result] {
        let supplies: [TemplateSupply] = templates.compactMap { template in
            guard let achievable = achievableTaskIdsByTemplateId?[template.id] else { return nil }
            return TemplateSupply(template: template, achievableSize: achievable.count)
        }
        var result: [String: Result] = [:]
        for pool in pools {
            result[pool.id] = computePoolHealth(pool, templates: supplies, tasksById: tasksById)
        }
        return result
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

    // MARK: - Pool-size preview (consumed by `PoolEditSheetView`; the
    // wizard Preview "deck" surface that also shared this was retired in
    // the sources rework). Lives here rather than in the view — originally
    // extracted per docs/POOLS_RECURRING.md §Surfaces item 2 (owner
    // decision, 2026-07-20: the short branch drops the missing-count and
    // board-size detail).

    /// The floor a deck-preview line measures a task count against, plus
    /// the board size used in the "fills a S×S" copy when healthy.
    struct DeckFloor: Equatable {
        let boardSize: Int
        let floor: Int
    }

    /// Fallback floor when there are no consuming templates yet — the
    /// 3×3-FREE-center default (8 tasks).
    static let defaultDeckFloor = DeckFloor(
        boardSize: 3,
        floor: recurringTemplateFillableCellCount(boardSize: 3, centerSquareType: .free)
    )

    /// The floor the Pool-edit sheet's deck-preview line measures against:
    /// the SMALLEST fillable floor among the pool's active, non-deleted
    /// consumers (a pool-kind source naming it — `templateConsumesPool`,
    /// never the `poolIds` mirror), or `defaultDeckFloor` when there are
    /// none. Mirrors web's `poolDeckPreview.ts`.
    static func computeDeckFloor(templates: [RecurringBoardTemplate], poolId: String) -> DeckFloor {
        var best: DeckFloor?
        for template in templates {
            guard !template.isDeleted, template.isActive else { continue }
            guard templateConsumesPool(template, poolId: poolId) else { continue }
            let floor = recurringTemplateFillableCellCount(
                boardSize: template.boardSize, centerSquareType: template.centerSquareType
            )
            if best == nil || floor < best!.floor {
                best = DeckFloor(boardSize: template.boardSize, floor: floor)
            }
        }
        return best ?? defaultDeckFloor
    }

    /// `"{N} tasks in the pool · fills a {S}×{S}"` / `"· short on required
    /// tasks"` — byte-identical to web's `formatDeckPreview` (owner
    /// decision, 2026-07-20: the short branch drops the missing-count and
    /// board-size detail; "in the deck" → "in the pool" in the
    /// sources-rework copy convergence). Consumed by `PoolEditSheetView`
    /// (deckFloor = the smallest consuming board's floor, via
    /// `computeDeckFloor`).
    static func formatDeckPreview(taskCount: Int, deckFloor: DeckFloor) -> String {
        let base = "\(taskCount) task\(taskCount == 1 ? "" : "s") in the pool"
        if taskCount >= deckFloor.floor {
            return "\(base) · fills a \(deckFloor.boardSize)×\(deckFloor.boardSize)"
        }
        return "\(base) · short on required tasks"
    }
}
