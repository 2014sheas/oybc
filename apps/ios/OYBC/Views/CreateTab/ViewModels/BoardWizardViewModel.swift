import Foundation
import Observation

/// A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate.
typealias WizardStep = Int

/// Returns the number of pool tasks the chosen geometry requires.
/// Mirrors web's `tasksNeededFor` in `useBoardWizard.ts`.
///
/// - Even-sized boards (no center concept): `size²`.
/// - Odd-sized boards with FREE center: `size² - 1`.
/// - Odd-sized boards with NONE: `size²`.
/// - Odd-sized boards with CHOSEN: `size²` (one selection IS the center).
func tasksNeededForBoard(size: Int, centerType: CenterSquareType) -> Int {
    let isOdd = size % 2 != 0
    let hasReservedCenter = isOdd && centerType == .free
    return size * size - (hasReservedCenter ? 1 : 0)
}

/// BoardWizardViewModel — Owns the full board-creation wizard state.
///
/// iOS twin of web's `useBoardWizard` hook. Initializes from the
/// supplied `UserPreferences` snapshot at construction time; later
/// preference changes do NOT stomp in-progress wizard state. All
/// step views are fully controlled — they read fields off this model
/// and call its mutators / nav actions.
///
/// Validation is exposed as computed properties (`isStep1Valid`,
/// `isStep2Valid`) so each step can disable its own Next button
/// without re-implementing the count-needed math.
@Observable
final class BoardWizardViewModel {

    // MARK: - Step 1 fields

    var name: String = ""
    var size: Int
    var timeframe: Timeframe
    /// `yyyy-MM-dd` — empty when not yet picked.
    var customStartDate: String = ""
    /// `yyyy-MM-dd` — empty when not yet picked.
    var customEndDate: String = ""
    var centerType: CenterSquareType
    /// Issue #69 — board placement is always randomized. There's no
    /// manual-placement UI, so the per-board "Randomize positions"
    /// toggle (and the `defaultRandomize` preference) were dead UX and
    /// have been removed. Nothing in production ever sets this to
    /// `false` (init/reset leave the `true` default and persist always
    /// writes `true`), so it's effectively constant — it's a `var`
    /// purely so snapshot tests can pin deterministic placement.
    /// Retained on Board/RecurringBoardTemplate for schema stability.
    var isRandomized: Bool = true
    /// Board Creation Split (iOS PR A) — whether this wizard instance is
    /// the recurring (BLUE) flow or the one-off (RED) flow. **Fixed at
    /// init, for the lifetime of this VM** — there is no mid-wizard
    /// "Repeats" control anymore (the old Step-1 segmented + `setRepeats(_:)`
    /// toggle machinery retired). The two Create-hub CTAs launch separate
    /// wizard instances with mode already decided; editing an existing
    /// recurring board always starts recurring (`editingTemplate` hydration).
    /// Hides Custom from the timeframe selector (recurring schema rejects
    /// it) and CHOSEN from the center-type selector.
    let isRecurring: Bool
    let weekStartDay: String

    // MARK: - Step 2 fields

    var selectedTaskIds: Set<String> = []
    var centerTaskId: String? = nil

    /// Insertion order of the pool. `RisoPoolListView` renders in this order
    /// rather than sorting alphabetically, so a renamed task (inline editing)
    /// keeps its position. Kept in lockstep with `selectedTaskIds`; undo-restore
    /// re-inserts at the original index. Hydrated from placement/pool order on
    /// draft/template resume.
    var poolOrder: [String] = []

    /// Staged, not-yet-persisted inline edits keyed by task id. Applied ONLY
    /// inside the board-create transaction (`persistWizardBoard` →
    /// `saveWizardBoard`) — never while the board is a draft. Cleared when the
    /// task leaves the pool or the wizard resets.
    var stagedEdits: [String: TaskEditPatch] = [:]

    /// Bug #85 — In-memory pending tasks created inside the wizard's
    /// New Task sheet. Keyed by `task.id`. These have NOT been written
    /// to GRDB yet; `persistWizardBoard` drains this dictionary inside
    /// its existing `AppDatabase.shared.write { }` block (tasks first,
    /// then child tasks, then `compound_children` links, then
    /// `board_tasks`). Abandoning the wizard silently discards the
    /// dictionary — nothing needs cleanup because nothing was persisted.
    ///
    /// iOS twin of web's `pendingTasks: Map<string, PendingTaskPayload>`.
    var pendingTasks: [String: PendingTaskPayload] = [:]

    // MARK: - Sources (Board Sources rework P2, docs/BOARD_SOURCES.md)
    //
    // The wizard's task list is assembled from SOURCES — pulled pools and
    // pulled boards, each one row with a membership range + per-board
    // excludes (+ a done-filter for boards) — plus the hand-added manual
    // layer. `sources` is the native state; the legacy trio
    // (`pulledPoolIds`/`removedTaskIds`) is DERIVED from it below, for
    // the P1 dual-write and any remaining legacy reader.

    /// Pulled sources, in row order — persisted verbatim as the record's
    /// `sources` (see `BoardWizardPersist`).
    var sources: [BoardSource] = []

    /// Per-source display/supply cache: name + RAW supply (pre-exclude,
    /// pre-filter) + done-set (boards only). Refreshed at pull time and by
    /// `refreshSourceSupplies` on library/pool reloads; the wizard session
    /// resolves supplies eagerly, while spawn re-resolves live per window.
    var supplyInfoBySourceId: [String: WizardSourceSupply] = [:]

    /// Expanded/collapsed row state — UI-only, never persisted (spec:
    /// `expanded` is not part of `BoardSource`).
    var expandedSourceIds: Set<String> = []

    /// Legacy mirror — pool-kind source ids in row order. Persisted as the
    /// record's decode-compat `poolIds` (P1 dual-write).
    var pulledPoolIds: [String] {
        sources.filter { $0.kind == .pool }.map { $0.sourceId }
    }

    /// Legacy mirror — the flat union of every source's excludes (order:
    /// first-seen across sources). Persisted as the record's decode-compat
    /// `removedTaskIds` (P1 dual-write).
    var removedTaskIds: Set<String> {
        var out = Set<String>()
        for source in sources { out.formUnion(source.excludedTaskIds) }
        return out
    }

    /// Tasks explicitly hand-added to the selection — never source-supplied.
    /// `toggleTaskSelection` maintains this alongside `selectedTaskIds`.
    var manualTaskIds: Set<String> = []

    // MARK: - Wizard navigation

    var currentStep: WizardStep = 1

    /// Set when the wizard was hydrated from an existing draft board.
    /// Non-nil means Save / Activate will update this record rather
    /// than create a new one. Mutually exclusive with `editingTemplateId`.
    let draftBoardId: String?

    /// Set when the wizard was hydrated from an existing recurring
    /// template (Profile → Recurring templates → Edit). Save updates
    /// the template and does NOT retroactively edit previously-spawned
    /// boards or trigger a fresh spawn. Mutually exclusive with
    /// `draftBoardId`.
    let editingTemplateId: String?

    /// Phase 6.1 — true iff the wizard was launched from the recurring
    /// banner (`prefilledRecurringTimeframe != nil`). Persisted on the
    /// created Board as `isCore: true`, which is the marker the
    /// `findPendingRecurringBoards` detector checks when deciding
    /// whether to keep showing the banner. Manual Create-tab opens
    /// (no prefill) leave this false → resulting Board is non-core →
    /// banner persists.
    let isCore: Bool

    /// Phase B — when the wizard was launched from the core-board
    /// browser to spawn a non-current window, this is the reference
    /// date for the target window. `computedBoundaries` resolves
    /// against this date instead of `Date()` so `resolveWizardDates`
    /// writes the board's `startDate`/`endDate` for the picked window
    /// (e.g. tomorrow's daily, next week's weekly). Nil for banner
    /// clicks and one-off boards — the legacy "today's window"
    /// behaviour is preserved.
    let targetWindowDate: Date?

    // MARK: - Init

    private let initialPreferences: UserPreferences

    /// Injected for tests; defaults to the production singleton.
    // `internal` (not private) so the BoardWizardViewModel+Sources extension
    // file can resolve board-source supplies through the same injected DB.
    let database: AppDatabase

    init(
        preferences: UserPreferences,
        initialStep: WizardStep = 1,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        targetWindowDate: Date? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        /// Board Creation Split (iOS PR A) — the recurring-hub-card entry
        /// point: a fresh wizard with no draft/template/prefill starts in
        /// recurring mode when true. Ignored (mode is derived from the
        /// hydration source instead) whenever `draft`, `editingTemplate`,
        /// or `prefilledRecurringTimeframe` is supplied. Defaults to
        /// `false` so every existing one-off call site is unaffected.
        startRecurring: Bool = false,
        userId: String? = nil,
        database: AppDatabase = .shared
    ) {
        self.database = database
        self.initialPreferences = preferences
        self.weekStartDay = preferences.weekStartDay.rawValue
        self.currentStep = initialStep
        self.draftBoardId = draft?.board.id
        self.targetWindowDate = targetWindowDate

        // Hydration priority: draft > editingTemplate > prefilledRecurringTimeframe
        // > startRecurring. Mirrors web's `useBoardWizard` rule. Drafts hydrate
        // the full record; templates supply their own seed; banner-prefill is
        // the next-weakest signal; a bare `startRecurring` flag (recurring
        // hub-card tap) is the weakest — it only matters for a truly fresh
        // wizard. CUSTOM prefill is rejected (defensive).
        let effectiveTemplate: RecurringBoardTemplate? = (draft == nil) ? editingTemplate : nil
        let effectivePrefill: Timeframe? =
            (draft == nil
                && effectiveTemplate == nil
                && prefilledRecurringTimeframe != nil
                && prefilledRecurringTimeframe != .custom)
                ? prefilledRecurringTimeframe
                : nil

        // Board Creation Split (iOS PR A) — mode is now decided ONCE at
        // init and never changes for the lifetime of this VM (no more
        // Step-1 "Repeats" segmented / `setRepeats(_:)` toggle). A wizard
        // *starts* recurring when editing an existing template, OR when
        // launched fresh from the recurring hub card (`startRecurring`).
        // A `prefilledRecurringTimeframe` (banner / core-board browser)
        // creates a one-off *core* board for that window — NOT a
        // repeating board — so it does not flip isRecurring (#70) and
        // takes priority over `startRecurring` (mutually exclusive in
        // practice: callers never pass both).
        //
        // Board Creation Split (PR B) — a resumed draft ALSO forces
        // recurring mode when the draft `Board` itself is marked
        // `isRecurringDraft`. This is checked ahead of `startRecurring`
        // (which only matters for a truly fresh wizard anyway, per the
        // `draft == nil` guard on that clause) so resuming a recurring
        // draft always reopens the blue wizard, never the red one.
        let isRecurringAtEntry = effectiveTemplate != nil
            || draft?.board.isRecurringDraft == true
            || (draft == nil && effectiveTemplate == nil && effectivePrefill == nil && startRecurring)
        self.isRecurring = isRecurringAtEntry
        self.editingTemplateId = effectiveTemplate?.id

        // isCore is independent from isRecurring (both fixed at entry).
        // Capture the launch-time signal: prefilled-from-a-window ⇒ core
        // (Phase 6.1 banner / core-board browser); preserve an existing
        // draft's core-ness on resume.
        self.isCore = draft?.board.isCore ?? (effectivePrefill != nil)

        if let d = draft {
            self.name = d.board.name
            self.size = d.board.boardSize
            self.timeframe = d.board.timeframe
            self.centerType = d.board.centerSquareType
            self.centerTaskId = d.board.centerTaskId

            // Board Sources P1 (docs/BOARD_SOURCES.md §Data model item 2)
            // — ANY draft carrying the blob hydrates from it, one-off
            // drafts included (their saves now snapshot it too, so an
            // overfilled one-off draft's full pool survives resume).
            // Legacy blob-less one-off drafts keep the boardTasks
            // fallback below. Mirrors web `useBoardWizard`'s
            // `hasDraftMixBlob`.
            if d.board.isRecurringDraft || d.board.recurringDraftMix != nil {
                // Board Creation Split (PR B) — a draft's FULL pool lives
                // in `recurringDraftMix`, not in the (possibly truncated —
                // overfill is intentional) placed BoardTask rows. Resolve
                // the mix the same way template edit-mode hydration does,
                // so a resumed draft round-trips its exact pool +
                // provenance instead of collapsing every row to "added by
                // hand".
                let mix = RecurringDraftMixPayload.decoded(from: d.board.recurringDraftMix)
                let hydrated = Self.hydrateSourcesState(
                    sources: mix.sources ?? [],
                    manualTaskIds: mix.manualTaskIds,
                    database: database
                )
                self.sources = hydrated.sources
                self.supplyInfoBySourceId = hydrated.supplyInfo
                self.selectedTaskIds = hydrated.selectedTaskIds
                self.poolOrder = hydrated.poolOrder
                self.manualTaskIds = Set(mix.manualTaskIds)
            } else {
                self.selectedTaskIds = Set(d.boardTasks.map { $0.taskId })
                // Preserve placement order on resume so the pool doesn't reshuffle.
                self.poolOrder = Self.dedupePreservingOrder(
                    d.boardTasks
                        .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
                        .map { $0.taskId }
                )
                // P3 — a LEGACY one-off draft (saved before Board Sources
                // P1) carries no persisted pool-mix fields, so there's no
                // better provenance to recover: every resumed row defaults
                // to "added by hand" until the user touches the new pull
                // card. `pulledPoolIds`/`removedTaskIds` stay at their `[]`
                // defaults. Explicit, flagged judgment call (must match web).
                self.manualTaskIds = self.selectedTaskIds
            }
            if d.board.timeframe == .custom {
                self.customStartDate = String(d.board.startDate.prefix(10))
                // A custom board always has an endDate; default defensively.
                self.customEndDate = String((d.board.endDate ?? "").prefix(10))
            }
        } else if let t = effectiveTemplate {
            self.name = t.name
            self.size = t.boardSize
            self.timeframe = t.timeframe
            self.centerType = t.centerSquareType
            // Board Sources P2 — hydrate the record's sources natively
            // (stamped array, or the legacy trio derived via
            // `sourcesForRecord`), so editing a repeating board round-trips
            // ranges/excludes/filters exactly. A GENUINELY UN-MIGRATED
            // record (every generalized field absent — pre-P1 rows pulled
            // from an old client) falls back to `seedTaskIds` as hand-added
            // rows, preserving the M2 fix-wave rule: `poolIds: []` resolves
            // through the mix (empty), ONLY fully-absent fields fall back.
            let isUnmigrated = t.sources == nil && t.poolIds == nil
                && t.manualTaskIds == nil && t.removedTaskIds == nil
            let recordManualIds = isUnmigrated ? t.seedTaskIds : (t.manualTaskIds ?? [])
            let recordSources = isUnmigrated
                ? []
                : BoardSources.sourcesForRecord(
                    sources: t.sources, poolIds: t.poolIds, removedTaskIds: t.removedTaskIds
                )
            let hydrated = Self.hydrateSourcesState(
                sources: recordSources,
                manualTaskIds: recordManualIds,
                database: database
            )
            self.sources = hydrated.sources
            self.supplyInfoBySourceId = hydrated.supplyInfo
            self.selectedTaskIds = hydrated.selectedTaskIds
            self.poolOrder = hydrated.poolOrder
            self.manualTaskIds = Set(recordManualIds)
        } else {
            let initialSize = preferences.defaultBoardSize.rawValue
            self.size = initialSize
            // Moved ahead of the timeframe if/else below (both prefill
            // branches now read `self.selectedTaskIds`, which Swift forbids
            // until every stored property — including `centerType` — has a
            // value; `centerType` doesn't depend on anything the branches
            // below compute, so hoisting it here is behavior-preserving.
            self.centerType = Self.coerceCenterType(
                size: initialSize,
                desired: Self.resolveCenterType(preferences.defaultCenterType)
            )
            // When prefilled from the recurring banner, the timeframe
            // overrides the user's default. Name is also seeded with the
            // human-readable label (e.g. "Today", "May 2026") — user can
            // edit before saving.
            if let timeframe = effectivePrefill {
                self.timeframe = timeframe
                if let window = computeTimeframeBoundaries(
                    timeframe: timeframe,
                    referenceDate: targetWindowDate ?? Date(),
                    weekStartDay: preferences.weekStartDay.rawValue
                ) {
                    self.name = formatTimeframeLabel(
                        timeframe: timeframe,
                        startDate: window.start
                    )
                }
                // Task Pools + Recurring Boards Rework (P5) — Core-board
                // setup prefill: hydrate from the user's `CoreBoardDefault`
                // for this timeframe (replaces the retired `DefaultPool`
                // prefill this superseded). BOTH `corePoolIds` (resolved
                // pool supply) and `coreDefaultTaskIds` (individual
                // defaults, P7-authored) pre-fill the selection as plain
                // chips — they never auto-own the board (see
                // docs/POOLS_RECURRING.md §Data model "CoreBoardDefault").
                // Silent on any DB error / no-row — the wizard still opens
                // with an empty selection so the user can build a board
                // manually.
                // Board Sources P2 (locked decision, docs/BOARD_SOURCES.md)
                // — core defaults PRE-PULL AS SOURCES: each `corePoolIds`
                // entry becomes a `[0, all]` pool source row, and
                // `coreDefaultTaskIds` become hand-added rows. The
                // Board-settings defaults sheet is now the SOLE author
                // surface; the wizard never writes `CoreBoardDefault`.
                if let userId = userId {
                    let coreDefault = try? database.fetchCoreBoardDefault(userId: userId, timeframe: timeframe)
                    let rawPoolIds = coreDefault?.corePoolIds ?? []
                    let rawDefaultIds = coreDefault?.coreDefaultTaskIds ?? []
                    // A fresh prefill pre-pulls only sources/tasks that
                    // RESOLVE — a deleted pool or task must not seed a dead
                    // row. (Draft/template hydration deliberately keeps the
                    // reference instead, so a sync-restored source returns.)
                    let livePoolIds = Set(
                        ((try? database.fetchPools(ids: rawPoolIds)) ?? [])
                            .filter { !$0.isDeleted }.map { $0.id }
                    )
                    let liveDefaultIds = Set(
                        ((try? database.fetchTasks(ids: rawDefaultIds)) ?? [])
                            .filter { !$0.isDeleted }.map { $0.id }
                    )
                    let corePoolIds = rawPoolIds.filter { livePoolIds.contains($0) }
                    let coreDefaultTaskIds = rawDefaultIds.filter { liveDefaultIds.contains($0) }
                    let hydrated = Self.hydrateSourcesState(
                        sources: corePoolIds.map { BoardSource(sourceId: $0, kind: .pool) },
                        manualTaskIds: coreDefaultTaskIds,
                        database: database
                    )
                    self.sources = hydrated.sources
                    self.supplyInfoBySourceId = hydrated.supplyInfo
                    self.selectedTaskIds = hydrated.selectedTaskIds
                    self.poolOrder = hydrated.poolOrder
                    self.manualTaskIds = Set(coreDefaultTaskIds)
                } else {
                    self.manualTaskIds = []
                }
            } else if isRecurringAtEntry {
                // Board Creation Split (iOS PR A) — a fresh wizard launched
                // from the recurring hub card seeds a default cadence
                // rather than resolving the one-off `defaultTimeframe`
                // preference (Custom/Indefinite aren't valid cadences
                // anyway). The Setup step's "REPEATS EVERY" segmented lets
                // the user change it to Day/Month/Year before Next.
                self.timeframe = .weekly
                self.manualTaskIds = self.selectedTaskIds
            } else {
                let resolved = Self.resolveTimeframe(preferences.defaultTimeframe)
                // The "Custom" segment defaults to an ongoing board (End date =
                // None); a dated range is opt-in via the End-date control. So a
                // CUSTOM (or already-INDEFINITE) default resolves to .indefinite
                // for a fresh board.
                if resolved == .custom || resolved == .indefinite {
                    self.timeframe = .indefinite
                } else {
                    self.timeframe = resolved
                }
                // P3 — a fresh, non-prefilled wizard has no pool-mix history
                // yet and nothing selected: `selectedTaskIds` is empty here,
                // so this is a no-op today, but keeps `manualTaskIds`
                // doc-consistent with `selectedTaskIds` for whatever a
                // future non-prefill entry point might seed.
                self.manualTaskIds = self.selectedTaskIds
            }
        }
    }

    private static func resolveCenterType(_ value: DefaultCenterSquareType) -> CenterSquareType {
        switch value {
        case .free: return .free
        case .none: return .none
        }
    }

    /// Returns a `centerType` consistent with `size`. Even boards have
    /// no center concept — the form hides the center selector for
    /// them, so a leaked FREE from prefs would be
    /// unfixable from the UI. Coerce to NONE in that case. Mirrors
    /// the web `coerceCenterType` helper in `useBoardWizard.ts` and
    /// the existing odd/even guard inside `updateSize`.
    private static func coerceCenterType(
        size: Int,
        desired: CenterSquareType
    ) -> CenterSquareType {
        let isOdd = size % 2 != 0
        if !isOdd { return .none }
        return desired
    }

    private static func resolveTimeframe(_ value: DefaultTimeframe) -> Timeframe {
        switch value {
        case .daily:      return .daily
        case .weekly:     return .weekly
        case .monthly:    return .monthly
        case .yearly:     return .yearly
        case .custom:     return .custom
        case .indefinite: return .indefinite
        }
    }


    /// Resolves a recurring draft's raw `recurringDraftMix` fields into a
    /// hydrated selection + display order. Board Creation Split (PR B) —
    /// mirrors `resolveTemplateHydrationTaskIds`'s DB-lookup shape, but
    /// (a) returns an ORDERED result (`poolOrder` needs a deterministic
    /// sequence, unlike the template path's `Set`) and (b) has no
    /// `seedTaskIds`-style legacy fallback to preserve — a fresh recurring
    /// draft's mix is the only shape that has ever existed, so any lookup
    /// failure just yields an empty selection (the wizard still opens;
    /// the user rebuilds the pool) rather than a stale substitute.
    static func resolvePoolMixHydration(
        poolIds: [String],
        manualTaskIds: [String],
        removedTaskIds: [String],
        database: AppDatabase
    ) -> (selectedTaskIds: Set<String>, poolOrder: [String]) {
        guard let pools = try? database.fetchPools(ids: poolIds) else {
            return (Set(), [])
        }
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var referencedIds = Set<String>()
        for pool in pools { referencedIds.formUnion(pool.taskIds) }
        referencedIds.formUnion(manualTaskIds)

        guard let tasks = try? database.fetchTasks(ids: Array(referencedIds)) else {
            return (Set(), [])
        }
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        let result = PoolMix.resolveMix(
            WizardPoolMixRecord(poolIds: poolIds, manualTaskIds: manualTaskIds, removedTaskIds: removedTaskIds),
            poolsById: poolsById,
            tasksById: tasksById
        )
        return (Set(result.taskIds), result.taskIds)
    }

    /// Board Creation Split (PR B) — computes which step a resumed draft
    /// should open on: Setup (1) when nothing has been selected yet,
    /// Tasks/Pool (2) when the selection is below the board's
    /// requirement, Preview (3) once it can fill the board. README
    /// §Interactions & Behavior / §State Management "Resume-step
    /// selection". Completed steps stay reachable via the stepper's
    /// existing jump-back behavior regardless of where this lands.
    ///
    /// Static (not an instance method) so `CreateHubViewModel` can compute
    /// the step BEFORE constructing the `BoardWizardViewModel` that will
    /// actually hydrate from this same draft — the hub only carries a
    /// `(board, boardTasks)` tuple, not a live VM, at the point it decides
    /// which step to open.
    ///
    /// A recurring draft's true selection count comes from
    /// `recurringDraftMix` (resolved via `resolvePoolMixHydration`), never
    /// `boardTasks.count` — the placed rows are a possibly-truncated grid
    /// subset of an intentionally overfilled pool (see
    /// `Board.recurringDraftMix`'s doc), so counting them would send an
    /// already-fillable recurring draft back to the Pool step.
    static func resolveDraftInitialStep(
        board: Board,
        boardTasks: [BoardTask],
        database: AppDatabase
    ) -> WizardStep {
        let tasksRequired = tasksNeededForBoard(size: board.boardSize, centerType: board.centerSquareType)
        let selectedCount: Int
        // Board Sources P1 — one-off drafts saved post-P1 carry the blob
        // too; count from it whenever present (same truncation rationale).
        if board.isRecurringDraft || board.recurringDraftMix != nil {
            let mix = RecurringDraftMixPayload.decoded(from: board.recurringDraftMix)
            selectedCount = Self.resolvePoolMixHydration(
                poolIds: mix.poolIds,
                manualTaskIds: mix.manualTaskIds,
                removedTaskIds: mix.removedTaskIds,
                database: database
            ).selectedTaskIds.count
        } else {
            selectedCount = boardTasks.count
        }
        if selectedCount == 0 { return 1 }
        if selectedCount < tasksRequired { return 2 }
        return 3
    }

    /// Resolves a `CoreBoardDefault` row's `corePoolIds` +
    /// `coreDefaultTaskIds` into the core-board setup wizard's initial
    /// selection. Task Pools + Recurring Boards Rework (P5),
    /// docs/POOLS_RECURRING.md §Surfaces item 6 ("pre-filled chips plain").
    /// iOS twin of web's core-setup prefill resolver; mirrors
    /// `resolveTemplateHydrationTaskIds`'s shape and fallback posture.
    ///
    /// - Folds `PoolMix.resolvePoolPullAdditions` across `corePoolIds` (no
    ///   removals at this stage — a fresh wizard has none yet), unioning
    ///   each pool's resolvable supply into `selected`/`order` in
    ///   first-seen order, and appending each RESOLVABLE (non-deleted)
    ///   pool id to `pulled` — a deleted pool contributes nothing and is
    ///   skipped (derived detachment, matching `PoolMix`'s own posture).
    /// - Then unions `coreDefaultTaskIds` (filtered to resolvable —
    ///   present + non-deleted — tasks) in their own stored order,
    ///   appended AFTER the pool-resolved tasks, deduped against what's
    ///   already selected.
    /// - Silent on any DB error (`try?`) or empty input — mirrors the
    ///   retired `DefaultPool` prefill's fallback posture: the wizard
    ///   still opens with an empty selection rather than blocking.
    private static func resolveCoreBoardDefaultPrefill(
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        database: AppDatabase
    ) -> (selectedTaskIds: Set<String>, poolOrder: [String], pulledPoolIds: [String]) {
        guard !corePoolIds.isEmpty || !coreDefaultTaskIds.isEmpty else {
            return (Set(), [], [])
        }
        guard let pools = try? database.fetchPools(ids: corePoolIds) else {
            return (Set(), [], [])
        }
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var referencedIds = Set<String>()
        for pool in pools { referencedIds.formUnion(pool.taskIds) }
        referencedIds.formUnion(coreDefaultTaskIds)

        guard let tasks = try? database.fetchTasks(ids: Array(referencedIds)) else {
            return (Set(), [], [])
        }
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        return Self.resolveCoreBoardDefaultPrefill(
            corePoolIds: corePoolIds,
            coreDefaultTaskIds: coreDefaultTaskIds,
            poolsById: poolsById,
            tasksById: tasksById
        )
    }

    /// Pure core of `resolveCoreBoardDefaultPrefill(corePoolIds:coreDefaultTaskIds:database:)`
    /// above, taking pre-fetched lookups instead of hitting the DB itself.
    /// `internal` (not `private`) so the P7 Board-settings surfaces
    /// (`BoardSettingsView`'s per-timeframe summary line,
    /// `CoreDefaultsEditSheetView`'s seed selection) can reuse the EXACT
    /// same resolution logic the wizard's core-setup prefill uses, rather
    /// than a second hand-rolled union — those callers already have
    /// `pools`/`tasks` loaded for the whole screen (batched once, not
    /// per-row), so a DB round-trip per call would be wasteful.
    static func resolveCoreBoardDefaultPrefill(
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> (selectedTaskIds: Set<String>, poolOrder: [String], pulledPoolIds: [String]) {
        guard !corePoolIds.isEmpty || !coreDefaultTaskIds.isEmpty else {
            return (Set(), [], [])
        }

        var selected = Set<String>()
        var order: [String] = []
        var pulled: [String] = []

        for poolId in corePoolIds {
            guard let pool = poolsById[poolId], !pool.isDeleted else { continue }
            pulled.append(poolId)
            let additions = PoolMix.resolvePoolPullAdditions(
                poolId, removedTaskIds: [], poolsById: poolsById, tasksById: tasksById
            )
            for taskId in additions where !selected.contains(taskId) {
                selected.insert(taskId)
                order.append(taskId)
            }
        }

        for taskId in coreDefaultTaskIds {
            guard let task = tasksById[taskId], !task.isDeleted else { continue }
            if !selected.contains(taskId) {
                selected.insert(taskId)
                order.append(taskId)
            }
        }

        return (selected, order, pulled)
    }

    // Board Sources P2 — the core-setup "Start every…" checkbox and its
    // `isCorePoolDefaultSaved` / `setCorePoolDefaultSaved` helpers were
    // REMOVED (docs/BOARD_SOURCES.md §Removed): the Board-settings
    // defaults sheet is the sole `CoreBoardDefault` author surface now.

    // MARK: - Coupled mutators

    /// Changes board size and resets center type when crossing the
    /// odd/even boundary so the model stays consistent.
    ///
    /// The NONE→FREE coercion only fires when actually crossing from an
    /// even board to an odd one (where the even board had forced NONE and
    /// an odd board wants a visible default). Re-selecting the same — or
    /// another — odd size must NOT silently discard a deliberate NONE the
    /// user picked on an already-odd board.
    func updateSize(_ s: Int) {
        let oldIsOdd = size % 2 != 0
        size = s
        let newIsOdd = s % 2 != 0
        if !newIsOdd {
            centerType = .none
            centerTaskId = nil
        } else if !oldIsOdd && centerType == .none {
            centerType = .free
        }
    }

    /// Changes the center type and clears the chosen-task mark when
    /// switching away from CHOSEN.
    func updateCenterType(_ t: CenterSquareType) {
        centerType = t
        if t != .chosen {
            centerTaskId = nil
        }
    }

    /// Recurring templates exclude `.custom` and `.indefinite` (no computed
    /// window / no cadence). Mirrors the web `setTimeframe` defensive guard.
    ///
    /// Board Creation Split (iOS PR A) — this is now ALSO the recurring
    /// flow's "REPEATS EVERY" cadence setter (Day/Week/Month/Year). Mode
    /// itself (`isRecurring`) is fixed at init and can never be changed
    /// through this or any other mutator — the retired `setRepeats(_:)`
    /// was the only path that flipped it, and it's gone.
    func updateTimeframe(_ t: Timeframe) {
        if isRecurring && (t == .custom || t == .indefinite) { return }
        timeframe = t
    }

    // Board Sources P2 — the pool-mix actions (`pullPool`/`untogglePool`/
    // `toggleTaskSelection`) and every sources-native action live in
    // `BoardWizardViewModel+Sources.swift` (kept out of this frozen
    // god-file; ROADMAP B6 posture). `provenanceByTaskId` was removed with
    // the provenance subtitles (docs/BOARD_SOURCES.md §Removed).

    /// Stage an inline edit; returns the previous patch (or nil) so the Save
    /// toast's Undo can revert to it.
    @discardableResult
    func stageEdit(_ patch: TaskEditPatch, for taskId: String) -> TaskEditPatch? {
        let previous = stagedEdits[taskId]
        stagedEdits[taskId] = patch
        return previous
    }

    /// Undo a staged edit: restore the previous patch, or clear it entirely
    /// when there was none.
    func revertEdit(for taskId: String, to previous: TaskEditPatch?) {
        if let previous {
            stagedEdits[taskId] = previous
        } else {
            stagedEdits.removeValue(forKey: taskId)
        }
    }

    /// Overlay a staged patch onto a base task for DISPLAY (pool rows + preview)
    /// — the DB is untouched until board create. No-op when unstaged.
    func effectiveTask(_ base: OYBC.Task) -> OYBC.Task {
        guard let patch = stagedEdits[base.id] else { return base }
        return patch.applied(to: base)
    }

    /// Undo-restore for the Remove ✕ toast: re-select and re-insert at the
    /// original index (clamped), so the removed row returns to where it was.
    ///
    /// `payload` MUST be supplied when the removed task was a deferred (Bug #85)
    /// pending task — `toggleTaskSelection` purges its `pendingTasks` entry on
    /// removal, so without re-adding it the restored id can't be resolved by
    /// `effectiveTaskById`/`buildWizardPlacement` and the board silently
    /// under-fills (a `nil` grid cell). Library tasks pass `nil`.
    func restoreToPool(_ taskId: String, at index: Int, payload: PendingTaskPayload? = nil) {
        selectedTaskIds.insert(taskId)
        if !poolOrder.contains(taskId) {
            poolOrder.insert(taskId, at: min(max(0, index), poolOrder.count))
        }
        if let payload { pendingTasks[payload.task.id] = payload }
    }

    /// De-dupes a task-id sequence preserving first occurrence — used to derive
    /// `poolOrder` from a board's placement rows on draft resume.
    private static func dedupePreservingOrder(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Bug #85 — Store a pending task payload in the wizard's in-memory
    /// dictionary. Must be called AFTER `toggleTaskSelection` adds the
    /// task id to `selectedTaskIds`.
    ///
    /// iOS twin of web's `addPendingTask` action in `useBoardWizard.ts`.
    func addPendingTask(_ payload: PendingTaskPayload) {
        pendingTasks[payload.task.id] = payload
    }

    func setCenterTaskId(_ id: String?) {
        centerTaskId = id
    }

    // MARK: - Step navigation

    func goToStep(_ step: WizardStep) {
        currentStep = max(1, min(3, step))
    }

    func goNext() {
        if currentStep < 3 { currentStep += 1 }
    }

    func goBack() {
        if currentStep > 1 { currentStep -= 1 }
    }

    func reset() {
        name = ""
        let nextSize = initialPreferences.defaultBoardSize.rawValue
        size = nextSize
        // Board Creation Split (iOS PR A) — `isRecurring` is fixed for this
        // VM's lifetime, so reset() must respect the current mode rather
        // than resolving the one-off `defaultTimeframe` preference
        // unconditionally. Mirrors init's own per-mode default.
        if isRecurring {
            timeframe = .weekly
        } else {
            // Mirror init's CUSTOM→INDEFINITE default so a reset wizard opens
            // ongoing (End date = None), not on .custom with empty dates.
            let resolvedReset = Self.resolveTimeframe(initialPreferences.defaultTimeframe)
            timeframe = resolvedReset == .custom ? .indefinite : resolvedReset
        }
        customStartDate = ""
        customEndDate = ""
        // Same coercion the initial factory uses, so reset can never
        // reintroduce an even-board+FREE mismatch.
        centerType = Self.coerceCenterType(
            size: nextSize,
            desired: Self.resolveCenterType(initialPreferences.defaultCenterType)
        )
        selectedTaskIds = []
        poolOrder = []
        stagedEdits = [:]
        centerTaskId = nil
        pendingTasks = [:]
        sources = []
        supplyInfoBySourceId = [:]
        expandedSourceIds = []
        manualTaskIds = []
        currentStep = 1
    }

    // MARK: - Derived

    var tasksRequired: Int { tasksNeededForBoard(size: size, centerType: centerType) }
    var centerMode: Bool { centerType == .chosen }
    var isOddBoard: Bool { size % 2 != 0 }

    /// Computed timeframe boundaries (nil for `.custom`).
    ///
    /// Uses `targetWindowDate` when set (core-board browser pre-spawn);
    /// otherwise falls back to `Date()` for the historic banner /
    /// one-off behaviour. All downstream date producers
    /// (`timeframeDisplayLabel`, `resolveWizardDates`, the recurring
    /// template's first-spawn window) read through this single
    /// computation so the target window stays consistent.
    var computedBoundaries: (start: Date, end: Date)? {
        computeTimeframeBoundaries(
            timeframe: timeframe,
            referenceDate: targetWindowDate ?? Date(),
            weekStartDay: weekStartDay
        )
    }

    /// Inline summary label for the chosen non-custom timeframe.
    var timeframeDisplayLabel: String? {
        guard let b = computedBoundaries else { return nil }
        return formatTimeframeLabel(timeframe: timeframe, startDate: b.start)
    }

    var isStep1Valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if timeframe == .custom {
            guard !customStartDate.isEmpty && !customEndDate.isEmpty else { return false }
            guard customEndDate >= customStartDate else { return false }
        }
        return true
    }

    var step1ValidationMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Board name is required." }
        if timeframe == .custom {
            if customStartDate.isEmpty || customEndDate.isEmpty {
                return "Pick a start and end date."
            }
            if customEndDate < customStartDate {
                return "End date must be on or after the start date."
            }
        }
        return nil
    }

    /// Board Sources P2 — the step-2 gate compares CAPACITY (sum of every
    /// source's effective max + hand-added, deduped — docs/BOARD_SOURCES.md
    /// §Selection step 3) against the fillable cell count. For all-[0,all]
    /// sources this equals the old flat selection count, so pre-rework
    /// behavior is unchanged; a numeric max caps what a source can
    /// contribute and the gate respects it.
    var isStep2Valid: Bool {
        guard sourceCapacity >= tasksRequired else { return false }
        if centerMode {
            guard let id = centerTaskId, selectedTaskIds.contains(id) else { return false }
        }
        return true
    }

    var step2ValidationMessage: String? {
        let short = tasksRequired - sourceCapacity
        if short > 0 {
            // Design copy (docs/BOARD_SOURCES.md §Surfaces item 1).
            return "\(short) more to fill the board."
        }
        if centerMode {
            if centerTaskId == nil || !selectedTaskIds.contains(centerTaskId!) {
                return "Mark one selected task as the center."
            }
        }
        return nil
    }

    /// True when no meaningful edit has been made — the wizard can be
    /// dismissed without prompting. When a draft is being resumed this
    /// is always `false`: closing a resumed draft is always a decision
    /// worth confirming.
    var isPristine: Bool {
        if draftBoardId != nil { return false }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if !selectedTaskIds.isEmpty { return false }
        if currentStep > 1 { return false }
        return true
    }
}
