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
    /// boards-list perf lesson. iOS twin of web's `useTemplateRosterHealth`.
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

            let resolutionByTemplateId = try database.fetchTemplateSupplyResolution(
                templates: result, tasksById: tasksById
            )

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

    /// Per-template sources resolution input for `computeRosterHealth` —
    /// resolved by `AppDatabase.fetchTemplateSupplyResolution` (kept as a
    /// nested name so existing call sites and tests read unchanged).
    typealias TemplateSupplyResolution = AppDatabase.TemplateSupplyResolution

    /// The achievable pick per template — the same `mixByTemplateId` the
    /// roster renders, resolved on demand for surfaces that don't own a
    /// roster VM (the Tasks-tab Pools segment's pool-health warning; 2026-09
    /// audit T2). Web twin: `useTemplateRosterHealth(...).mixByTemplateId`.
    /// Runs DB reads — call off-main.
    ///
    /// - Parameters:
    ///   - templates: The roster.
    ///   - tasksById: Every live task of the user.
    ///   - database: The database to resolve against.
    /// - Returns: template id → the task ids its next spawn could deal from.
    /// - Throws: A GRDB error from the supply resolution.
    static func resolveAchievableTaskIds(
        templates: [RecurringBoardTemplate],
        tasksById: [String: Task],
        database: AppDatabase
    ) throws -> [String: [String]] {
        let resolution = try database.fetchTemplateSupplyResolution(
            templates: templates, tasksById: tasksById
        )
        return computeRosterHealth(
            templates: templates, resolutionByTemplateId: resolution, tasksById: tasksById
        ).mixByTemplateId
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
    ///
    /// B2: the supplies are Split-up expanded (`applyMemberRules`) first, so
    /// the count is of the squares a new window would actually get.
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
            // B2 (§Member rules step 1) — expand Split-up compound members
            // into their parts BEFORE the capacity dry-run: a split member
            // supplies N squares, not one, so counting the raw supply would
            // badge a healthy record `poolTooSmall` (and show the wrong
            // "N tasks").
            let supplies = BoardSources.applyMemberRules(
                resolution.supplies,
                childrenByCompoundId: resolution.childrenByCompoundId,
                tasksById: tasksById
            ).map { $0.asSupply }
            // Resolvable manual layer (deleted manual ids stay OUT of the
            // pick but flag attention below — the spawn validator's rule).
            let manualResolvable = resolution.manualTaskIds.filter { id in
                guard let task = tasksById[id] else { return false }
                return !task.isDeleted
            }
            let achievable = BoardSources.computeAchievablePoolSize(
                supplies: supplies,
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
