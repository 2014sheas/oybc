import Foundation
import Observation

/// Owns the user's non-deleted recurring board templates. iOS twin of
/// the web `useRecurringBoardTemplates` hook (Phase 6.2b).
///
/// Loading is imperative — the view calls `reloadAsync(userId:)` on
/// appear and after any save/delete from the form. Mirrors the pattern
/// used by `ParentBoardTasksViewModel`.
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
    var attentionByTemplateId: [String: SpawnPoolFailureReason] = [:]

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
            // Resolve pools against the live library (non-deleted tasks
            // only) to compute the per-template mix, then attention +
            // preview state from that mix — see `mixByTemplateId`'s doc.
            let liveTasks = try database.fetchTasks(userId: userId)
            let tasksById = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            let allPoolIds = Set(result.flatMap { $0.poolIds ?? [] })
            let pools = try database.fetchPools(ids: Array(allPoolIds))
            let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

            let mixByTemplateId = Self.computeTemplateMixes(
                templates: result, poolsById: poolsById, tasksById: tasksById
            )
            let attention = Self.computeAttention(
                templates: result, liveTasks: liveTasks, mixByTemplateId: mixByTemplateId
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

    /// Batched, per-reload pool-mix resolution across every template.
    /// `static` (like `computeAttention`/`computePoolPreview`) so unit
    /// tests can exercise it directly without a database. iOS twin of
    /// web's `computeTemplateMixes`.
    ///
    /// `poolIds == nil || poolIds!.isEmpty` falls back to `seedTaskIds`
    /// verbatim — the same transient un-migrated safety net
    /// `resolveTemplateHydrationTaskIds` uses (see that function's doc for
    /// the full rationale; matches `PoolMix.isLegacyShapedRecord`'s "no
    /// pool yet" case).
    static func computeTemplateMixes(
        templates: [RecurringBoardTemplate],
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for template in templates {
            guard let poolIds = template.poolIds, !poolIds.isEmpty else {
                out[template.id] = template.seedTaskIds
                continue
            }
            out[template.id] = PoolMix.resolveMix(template, poolsById: poolsById, tasksById: tasksById).taskIds
        }
        return out
    }

    /// Pure attention-map computation. Extracted (and `static`) so unit
    /// tests can exercise it directly without a database. Strict mirror
    /// of web's `computeTemplateAttention` in `templateHealth.ts`.
    ///
    /// - Parameters:
    ///   - templates: The user's non-deleted templates.
    ///   - liveTasks: The user's non-deleted task library.
    ///   - mixByTemplateId: Each template's CURRENT resolved task-id mix
    ///     (from `computeTemplateMixes`). A missing entry falls back to
    ///     that template's own `seedTaskIds` (loading-state safety net so
    ///     the badge doesn't flash "pool too small" before the batched
    ///     mix resolves, AND so pre-P1 callers/tests that never pass this
    ///     parameter keep their old seedTaskIds-based behavior verbatim).
    /// - Returns: template id → failure reason (absent ⇒ healthy).
    static func computeAttention(
        templates: [RecurringBoardTemplate],
        liveTasks: [Task],
        mixByTemplateId: [String: [String]] = [:]
    ) -> [String: SpawnPoolFailureReason] {
        let taskMap = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [String: SpawnPoolFailureReason] = [:]
        for template in templates {
            let mixTaskIds = mixByTemplateId[template.id] ?? template.seedTaskIds
            var pool: [Task] = []
            var hasMissingFromLibrary = false
            for id in mixTaskIds {
                if let found = taskMap[id] { pool.append(found) } else { hasMissingFromLibrary = true }
            }
            if hasMissingFromLibrary {
                out[template.id] = .hasDeletedTasks
                continue
            }
            if case .failure(let reason) = validateSpawnPool(template: template, poolTasks: pool) {
                out[template.id] = reason
            }
        }
        return out
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
