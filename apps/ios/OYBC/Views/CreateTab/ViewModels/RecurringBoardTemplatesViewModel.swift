import Foundation
import Observation

/// Owns the user's non-deleted recurring board templates ("repeating
/// boards" in P7 user-facing copy — the underlying type/table name is
/// unchanged). iOS twin of the web `useRecurringBoardTemplates` hook
/// (Phase 6.2b).
///
/// Loading is imperative — the view calls `reloadAsync(userId:)` on
/// appear and after any save/delete from the form. Mirrors the pattern
/// used by `ParentBoardTasksViewModel`.
///
/// **P7 (Task Pools + Recurring Boards Rework)**: this used to be
/// instantiated only by the retired `Views/ProfileTab/RecurringTemplatesView.swift`
/// page. That page is gone (folded into `BoardSettingsView`'s
/// "Repeating boards" roster section), but every computed property here
/// (`templates`, `attentionByTemplateId`, `poolPreviewByTemplateId`,
/// `poolPreviewOverflowByTemplateId`, `mixByTemplateId`) is exactly what
/// the roster needs too, so this VM was ADAPTED in place (reused
/// verbatim, not reinvented) rather than deleted — `BoardSettingsView`
/// now owns the single live instance.
@Observable
final class RecurringBoardTemplatesViewModel {

    // MARK: - State

    var templates: [RecurringBoardTemplate] = []
    var loadError: String?

    /// Per-template CURRENT resolved pool-mix task ids, keyed by template
    /// id. P1 (Task Pools + Recurring Boards Rework,
    /// docs/POOLS_RECURRING.md §Migration "seedTaskIds end state" —
    /// "never read after P1" is unconditional) — this used to be computed
    /// implicitly by walking `template.seedTaskIds` directly inside
    /// `computeAttention`/`computePoolPreview`. That went stale the first
    /// time the legacy-editor write-through ran (it edits the linked
    /// Pool's `taskIds`, not this field), which could show a WRONG
    /// pool-health badge or preview chip row. Batched (one `fetchPools`
    /// call for every template's pools, not N calls) — mirrors the
    /// boards-list perf lesson. iOS twin of web's `useTemplateMixes`.
    var mixByTemplateId: [String: [String]] = [:]

    /// Per-template "needs attention" reason, keyed by template id.
    /// Recomputed on every reload by resolving each template's CURRENT
    /// mix (`mixByTemplateId`) against the user's live task library and
    /// running `validateSpawnPool`. iOS twin of web's
    /// `attentionByTemplateId` (`RecurringTemplatesPage.tsx`): a mix id
    /// that no longer resolves in the library is treated as
    /// `hasDeletedTasks` (soft-delete is the only realistic cause, since
    /// the form can't add unknown ids), otherwise the validation failure
    /// reason is surfaced. Absent key ⇒ healthy, no badge.
    var attentionByTemplateId: [String: SpawnAttentionReason] = [:]

    /// First-3 resolved task titles (in mix order) per template, for the
    /// card's pool-preview chip row (issue #321). Unresolved ids (e.g. a
    /// soft-deleted task) are skipped rather than rendered as blank chips.
    /// A template with zero resolvable titles has no entry here.
    var poolPreviewByTemplateId: [String: [String]] = [:]

    /// Count of additional resolved titles beyond the first 3, for the
    /// card's "+{k} more" overflow chip. Absent (or 0) ⇒ no overflow chip.
    var poolPreviewOverflowByTemplateId: [String: Int] = [:]

    // MARK: - Race-condition guard
    //
    // Mirrors `ParentBoardTasksViewModel`: increments on every reload,
    // commits only if no newer reload has started in the meantime.
    @ObservationIgnored private var latestSeq: UInt64 = 0

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    func reload(userId: String) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestSeq &+= 1
            return latestSeq
        }

        do {
            let result = try database.fetchRecurringBoardTemplates(userId: userId)
            // Loose-ends sweep (2026-09-09) — SOURCES-NATIVE roster health:
            // resolve every template's supplies (pool + board kinds, the
            // 'todo' filter applied, dead board sources flagged) and
            // compute counts/attention from the honest ACHIEVABLE pool
            // size — the spawn pass's static twin, `sourceBoardMissing`
            // included. Replaces the legacy-trio resolveMix pair, under
            // which a board-source-only repeating board showed a spurious
            // warning and "0 tasks". Web twin: `useTemplateRosterHealth`.
            let liveTasks = try database.fetchTasks(userId: userId)
            let tasksById = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            let perTemplateSources = result.map { t in
                (template: t, sources: BoardSources.sourcesForRecord(
                    sources: t.sources, poolIds: t.poolIds, removedTaskIds: t.removedTaskIds
                ))
            }
            let allPoolIds = Set(perTemplateSources.flatMap { entry in
                entry.sources.filter { $0.kind == .pool }.map { $0.sourceId }
            })
            let pools = try database.fetchPools(ids: Array(allPoolIds))
            let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

            let allBoardIds = Set(perTemplateSources.flatMap { entry in
                entry.sources.filter { $0.kind == .board }.map { $0.sourceId }
            })
            let sourceBoards = try database.fetchBoards(ids: Array(allBoardIds))
            let boardById = Dictionary(uniqueKeysWithValues: sourceBoards.map { ($0.id, $0) })

            var resolutionByTemplateId: [String: TemplateSupplyResolution] = [:]
            for entry in perTemplateSources {
                var supplies: [BoardSources.Supply] = []
                var deadBoardSourceIds: [String] = []
                for source in entry.sources {
                    if source.kind == .pool {
                        supplies.append(BoardSources.Supply(
                            source: source,
                            supplyTaskIds: BoardSources.poolSourceSupplyById(
                                source.sourceId, poolsById: poolsById, tasksById: tasksById
                            )
                        ))
                        continue
                    }
                    let board = boardById[source.sourceId]
                    if board == nil || board!.isDeleted || board!.status == .archived {
                        deadBoardSourceIds.append(source.sourceId)
                        supplies.append(BoardSources.Supply(source: source, supplyTaskIds: []))
                        continue
                    }
                    let info = (try? database.fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil
                    var raw = info?.supplyTaskIds ?? []
                    if source.filter == .todo, let done = info?.doneTaskIds {
                        raw.removeAll { done.contains($0) }
                    }
                    supplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
                }
                let t = entry.template
                let isUnmigrated = t.sources == nil && t.poolIds == nil
                    && t.manualTaskIds == nil && t.removedTaskIds == nil
                resolutionByTemplateId[t.id] = TemplateSupplyResolution(
                    supplies: supplies,
                    deadBoardSourceIds: deadBoardSourceIds,
                    manualTaskIds: isUnmigrated ? t.seedTaskIds : (t.manualTaskIds ?? [])
                )
            }

            let (mixByTemplateId, attention) = Self.computeRosterHealth(
                templates: result,
                resolutionByTemplateId: resolutionByTemplateId,
                tasksById: tasksById
            )
            let (preview, overflow) = Self.computePoolPreview(
                templates: result, liveTasks: liveTasks, mixByTemplateId: mixByTemplateId
            )
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.templates = result
                self.mixByTemplateId = mixByTemplateId
                self.attentionByTemplateId = attention
                self.poolPreviewByTemplateId = preview
                self.poolPreviewOverflowByTemplateId = overflow
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestSeq else { return }
                self.loadError = "Failed to load recurring templates: \(error.localizedDescription)"
                self.templates = []
                self.mixByTemplateId = [:]
                self.attentionByTemplateId = [:]
                self.poolPreviewByTemplateId = [:]
                self.poolPreviewOverflowByTemplateId = [:]
            }
        }
    }

    /// Per-template sources resolution input for `computeRosterHealth`
    /// (loose-ends sweep 2026-09-09). Web twin: `TemplateSupplyResolution`
    /// (`db/operations/boardSources.ts`).
    struct TemplateSupplyResolution {
        let supplies: [BoardSources.Supply]
        let deadBoardSourceIds: [String]
        let manualTaskIds: [String]
    }

    /// Sources-native roster health — the spawn pass's static twin
    /// (supersedes the legacy `computeTemplateMixes` + `computeAttention`
    /// pair): mix = the honest ACHIEVABLE pick (ranges, cap overlap, the
    /// counter-family rule); attention = dead board source →
    /// `.sourceBoardMissing`, deleted hand-add → `.hasDeletedTasks`,
    /// nothing resolvable → `.noPoolTasksResolved`, then
    /// `validateSpawnPool` over the achievable pick. Pure + static for
    /// direct unit testing. Web twin: `computeRosterHealth`
    /// (`templateHealth.ts`).
    static func computeRosterHealth(
        templates: [RecurringBoardTemplate],
        resolutionByTemplateId: [String: TemplateSupplyResolution],
        tasksById: [String: Task]
    ) -> (mixByTemplateId: [String: [String]], attentionByTemplateId: [String: SpawnAttentionReason]) {
        let counterFamilyByTaskId = BoardSources.buildCounterFamilyMap(tasksById.values)
        var mixByTemplateId: [String: [String]] = [:]
        var attention: [String: SpawnAttentionReason] = [:]
        for template in templates {
            guard let resolution = resolutionByTemplateId[template.id] else {
                // Still loading / unresolvable — raw seed list so the row
                // renders a count instead of flashing empty.
                mixByTemplateId[template.id] = template.seedTaskIds
                continue
            }
            // Resolvable manual layer (deleted manual ids stay OUT of the
            // pick but flag attention below — the spawn validator's rule).
            let manualResolvable = resolution.manualTaskIds.filter { id in
                guard let task = tasksById[id] else { return false }
                return !task.isDeleted
            }
            let achievable = BoardSources.computeAchievablePoolSize(
                supplies: resolution.supplies,
                manualTaskIds: manualResolvable,
                counterFamilyByTaskId: counterFamilyByTaskId
            )
            mixByTemplateId[template.id] = achievable.taskIds

            if !resolution.deadBoardSourceIds.isEmpty {
                attention[template.id] = .sourceBoardMissing
                continue
            }
            if manualResolvable.count < resolution.manualTaskIds.count {
                attention[template.id] = .hasDeletedTasks
                continue
            }
            if achievable.size == 0 {
                attention[template.id] = .noPoolTasksResolved
                continue
            }
            let pool = achievable.taskIds.compactMap { tasksById[$0] }
            if case .failure(let reason) = validateSpawnPool(template: template, poolTasks: pool) {
                attention[template.id] = SpawnAttentionReason(reason)
            }
        }
        return (mixByTemplateId, attention)
    }

    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }

    /// Pure pool-preview computation (issue #321) — resolves each
    /// template's CURRENT mix (`mixByTemplateId`, falling back to
    /// `seedTaskIds`) against the live library (in mix order), skipping
    /// ids that don't resolve (soft-deleted / not-yet-synced), and caps
    /// the first result at 3 titles for the card's chip row. `static`
    /// (like `computeAttention`) so unit tests can exercise it directly
    /// without a database.
    ///
    /// - Parameter mixByTemplateId: See `computeAttention`'s parameter
    ///   doc — same fallback semantics.
    /// - Returns: `(preview, overflow)` — `preview[id]` is the first-3
    ///   resolved titles in mix order (absent if 0 resolve); `overflow[id]`
    ///   is the count of additional resolved titles beyond those 3
    ///   (absent/0 ⇒ no overflow chip).
    static func computePoolPreview(
        templates: [RecurringBoardTemplate],
        liveTasks: [Task],
        mixByTemplateId: [String: [String]] = [:]
    ) -> (preview: [String: [String]], overflow: [String: Int]) {
        let taskMap = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var preview: [String: [String]] = [:]
        var overflow: [String: Int] = [:]
        for template in templates {
            let mixTaskIds = mixByTemplateId[template.id] ?? template.seedTaskIds
            let resolvedTitles = mixTaskIds.compactMap { taskMap[$0]?.title }
            guard !resolvedTitles.isEmpty else { continue }
            preview[template.id] = Array(resolvedTitles.prefix(3))
            if resolvedTitles.count > 3 {
                overflow[template.id] = resolvedTitles.count - 3
            }
        }
        return (preview, overflow)
    }
}
