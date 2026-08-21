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

/// Minimal `PoolMixSource` wrapper for the wizard's raw pool-mix state,
/// which isn't itself a `RecurringBoardTemplate`. Used by
/// `BoardWizardViewModel.untogglePool`'s `PoolMix.clearRemovalsForUntoggle`
/// call. (Pre-P4, this was also reused by `BoardWizardPersist
/// .persistRecurringTemplate` to evaluate `PoolMix.isLegacyShapedRecord`
/// against the wizard's session shape — P4 retired that shape-scoped
/// write-through entirely, so persistence now reads
/// `pulledPoolIds`/`manualTaskIds`/`removedTaskIds` directly.)
/// Mirrors the ad-hoc fixture pattern `OYBCTests/PoolMixTests.swift`'s
/// `PoolMixInput` already uses. Internal (not `private`) so both files see it.
struct WizardPoolMixRecord: PoolMixSource {
    var poolIds: [String]?
    var manualTaskIds: [String]?
    var removedTaskIds: [String]?
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
    /// Task Pools + Recurring Boards Rework (P4) — when true, the wizard
    /// saves a recurring board (a "repeating" board — spawns a fresh
    /// window each cadence) instead of a one-off Board. Set via the
    /// Step-1 "Repeats" segmented control (`setRepeats(_:)`) — recurrence
    /// is now a board PROPERTY chosen at setup, not a separate entry
    /// point (the old "Create a recurring board" CTA / `startRecurring`
    /// init flag retired in P4; see `setRepeats(_:)`). Hides Custom from
    /// the timeframe selector (recurring schema rejects it) and CHOSEN
    /// from the center-type selector.
    var isRecurring: Bool = false
    /// Task Pools + Recurring Boards Rework (P4) — the timeframe to
    /// restore when the user flips "Repeats" back to Once
    /// (`setRepeats(nil)`). Captured by `setRepeats(_:)` the moment the
    /// user leaves Once for a cadence; seeded at `init` to the coerced
    /// one-off default (mirroring the fresh-wizard timeframe-resolution
    /// branch below) so a wizard that starts in recurring mode
    /// (`editingTemplate` hydration) and is immediately flipped back to
    /// Once without ever having been in Once first still lands on a
    /// sane, non-CUSTOM timeframe rather than crashing or carrying over
    /// the template's own cadence.
    private var lastOneOffTimeframe: Timeframe
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

    // MARK: - Pool mix (Task Pools + Recurring Boards Rework, P3)
    //
    // Wizard "PULL IN A POOL" support (docs/POOLS_RECURRING.md §Surfaces
    // item 5). `pullPool`/`untogglePool`/`provenanceByTaskId` take
    // `poolsById`/`tasksById` as call-site parameters rather than storing a
    // live cache on the VM — mirrors how `TaskLibraryViewModel` itself is
    // owned by the container view (`BoardWizardView`) and threaded into
    // free functions like `buildWizardPlacement(controller:library:)`
    // rather than cached here, so this state can't silently go stale
    // relative to the caller's freshly-loaded pools/library.

    /// Pools currently pulled into the selection, in pull order — this
    /// doubles as the exact array persisted as the spawn record's
    /// `poolIds` (see `BoardWizardPersist.persistRecurringTemplate`).
    var pulledPoolIds: [String] = []

    /// Tasks explicitly hand-added to the selection — never pool-sourced.
    /// `toggleTaskSelection` maintains this alongside `selectedTaskIds`.
    var manualTaskIds: Set<String> = []

    /// Tasks explicitly removed from the selection while still supplied by
    /// a pulled pool — bookkeeping so re-pulling an overlapping pool
    /// doesn't resurrect them, and so `untogglePool` clears exactly the
    /// right entries. See `PoolMix`'s type doc for the full removals
    /// semantics (docs/POOLS_RECURRING.md §Data model "Union rule").
    var removedTaskIds: Set<String> = []

    /// Task Pools + Recurring Boards Rework (P5) — the `CoreBoardDefault`'s
    /// currently-saved `corePoolIds` (as of the last fetch/write), for the
    /// core-setup "Start every <TF> board with 'X'" checkbox's derived
    /// checked-state (`isCorePoolDefaultSaved`). Distinct from
    /// `pulledPoolIds` (the wizard's live in-session pull state) — the two
    /// coincide (checkbox shows checked) only right after a prefill/save
    /// with no later pool-toggle edits. Only meaningful when `isCore` is
    /// true; stays `[]` for every other wizard shape.
    var savedCorePoolIds: [String] = []

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
    private let database: AppDatabase

    init(
        preferences: UserPreferences,
        initialStep: WizardStep = 1,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        targetWindowDate: Date? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        userId: String? = nil,
        database: AppDatabase = .shared
    ) {
        self.database = database
        self.initialPreferences = preferences
        self.weekStartDay = preferences.weekStartDay.rawValue
        self.currentStep = initialStep
        self.draftBoardId = draft?.board.id
        self.targetWindowDate = targetWindowDate
        // Seeded here (before the timeframe-resolution branches below,
        // which don't depend on it) to the same CUSTOM/INDEFINITE
        // coercion the fresh-wizard branch applies to its own default —
        // see the stored-property doc for why this matters for a wizard
        // that starts in recurring mode.
        let resolvedOneOffDefault = Self.resolveTimeframe(preferences.defaultTimeframe)
        self.lastOneOffTimeframe = (resolvedOneOffDefault == .custom || resolvedOneOffDefault == .indefinite)
            ? .indefinite
            : resolvedOneOffDefault

        // Hydration priority: draft > editingTemplate > prefilledRecurringTimeframe.
        // Mirrors web's `useBoardWizard` rule. Drafts hydrate the full
        // record; templates supply their own seed; banner-prefill is the
        // weakest signal. CUSTOM prefill is rejected (defensive).
        let effectiveTemplate: RecurringBoardTemplate? = (draft == nil) ? editingTemplate : nil
        let effectivePrefill: Timeframe? =
            (draft == nil
                && effectiveTemplate == nil
                && prefilledRecurringTimeframe != nil
                && prefilledRecurringTimeframe != .custom)
                ? prefilledRecurringTimeframe
                : nil

        // Task Pools + Recurring Boards Rework (P4) — recurring mode is now
        // a Step-1 board PROPERTY chosen via the "Repeats" segmented
        // control (`setRepeats(_:)`), not a separate wizard entry point.
        // The only way a wizard *starts* in recurring mode is editing an
        // existing recurring board's template. A `prefilledRecurringTimeframe`
        // (banner / core-board browser) creates a one-off *core* board for
        // that window — NOT a repeating board — so it does not flip
        // isRecurring (#70). Captured into a local first so the
        // timeframe-coercion below can read it before `init` finishes
        // (Swift forbids `self.` reads until every stored property is set).
        let isRecurringAtEntry = effectiveTemplate != nil
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
            self.selectedTaskIds = Set(d.boardTasks.map { $0.taskId })
            // Preserve placement order on resume so the pool doesn't reshuffle.
            self.poolOrder = Self.dedupePreservingOrder(
                d.boardTasks
                    .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
                    .map { $0.taskId }
            )
            // P3 — a one-off Board carries no persisted pool-mix fields, so
            // there's no better provenance to recover: every resumed row
            // defaults to "added by hand" until the user touches the new
            // pull card. `pulledPoolIds`/`removedTaskIds` stay at their `[]`
            // defaults. Explicit, flagged judgment call (must match web).
            self.manualTaskIds = self.selectedTaskIds
            if d.board.timeframe == .custom {
                self.customStartDate = String(d.board.startDate.prefix(10))
                // A custom board always has an endDate; default defensively.
                self.customEndDate = String((d.board.endDate ?? "").prefix(10))
            }
            // Task Pools + Recurring Boards Rework (P5) — a resumed CORE
            // draft's `pulledPoolIds` is empty by the P3 limitation noted
            // above, so the checkbox naturally starts unchecked (correct:
            // nothing is "pulled" yet this session). But `savedCorePoolIds`
            // still needs to be populated here so that if the user re-pulls
            // the SAME pool that's already the saved default mid-session,
            // the checkbox correctly reflects "already saved" rather than
            // staying stuck unchecked. Judgment call: not explicitly in the
            // handoff's core-setup section (which is framed around the
            // fresh-wizard path), but required for basic checkbox
            // correctness on a resumed core board — no P6/P7 surface pulled
            // forward. Silent on DB error, matching the fresh-wizard prefill.
            if d.board.isCore, let userId = userId {
                self.savedCorePoolIds = (try? database.fetchCoreBoardDefault(
                    userId: userId, timeframe: d.board.timeframe
                ))?.corePoolIds ?? []
            }
        } else if let t = effectiveTemplate {
            self.name = t.name
            self.size = t.boardSize
            self.timeframe = t.timeframe
            self.centerType = t.centerSquareType
            self.selectedTaskIds = Self.resolveTemplateHydrationTaskIds(t, database: database)
            // Template hydration returns a Set (order not preserved); use a
            // deterministic order so the pool is stable within the session.
            self.poolOrder = self.selectedTaskIds.sorted()
            // P3 — hydrate directly from the template's own pool-mix fields
            // so editing a repeating board's pool card round-trips its real
            // provenance instead of collapsing to "added by hand".
            self.pulledPoolIds = t.poolIds ?? []
            self.manualTaskIds = Set(t.manualTaskIds ?? [])
            self.removedTaskIds = Set(t.removedTaskIds ?? [])
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
                if let userId = userId {
                    let coreDefault = try? database.fetchCoreBoardDefault(userId: userId, timeframe: timeframe)
                    let corePoolIds = coreDefault?.corePoolIds ?? []
                    let coreDefaultTaskIds = coreDefault?.coreDefaultTaskIds ?? []
                    let prefill = Self.resolveCoreBoardDefaultPrefill(
                        corePoolIds: corePoolIds,
                        coreDefaultTaskIds: coreDefaultTaskIds,
                        database: database
                    )
                    self.selectedTaskIds = prefill.selectedTaskIds
                    self.poolOrder = prefill.poolOrder
                    self.pulledPoolIds = prefill.pulledPoolIds
                    self.savedCorePoolIds = corePoolIds
                }
                // Every prefilled row (pool-sourced or an individual
                // default) is NOT hand-added — nothing has been manually
                // touched yet at init time. This is the fix for the prior
                // unconditional `self.manualTaskIds = self.selectedTaskIds`
                // below, which stomped a core prefill into looking
                // hand-added; that assignment now lives ONLY in the
                // non-prefill `else` branch, where the selection is empty
                // anyway (a true no-op there).
                self.manualTaskIds = []
            } else {
                let resolved = Self.resolveTimeframe(preferences.defaultTimeframe)
                // The "Custom" segment defaults to an ongoing board (End date =
                // None); a dated range is opt-in via the End-date control. So a
                // CUSTOM (or already-INDEFINITE) default resolves to .indefinite
                // for a fresh board. (P4: a fresh wizard is never recurring at
                // entry — `isRecurringAtEntry` is always false in this branch,
                // since the `effectiveTemplate` branch above is the only path
                // that starts recurring — so there's no more "fall back to
                // daily" case to consider here.)
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

    /// Resolves a template's CURRENT pool-mix task ids for edit-mode
    /// hydration. iOS twin of web's `useTemplateMix`.
    ///
    /// P1 (Task Pools + Recurring Boards Rework,
    /// docs/POOLS_RECURRING.md §Migration "seedTaskIds end state") rewired
    /// the legacy template editor's persistence to write edits through to
    /// the linked `Pool`'s `taskIds` instead of the template's own
    /// `seedTaskIds` field — which is left VERBATIM (decode-compat only)
    /// and never read again. That means this hydration can no longer read
    /// `t.seedTaskIds` directly: after a first "Add tasks"/"Edit"
    /// round-trip, that field is stale — it would silently drop whatever
    /// the write-through already applied to the Pool, and re-opening the
    /// wizard a second time would show (and then re-save, DESTRUCTIVELY)
    /// the wrong selection.
    ///
    /// Un-migrated safety net (shouldn't occur post-migration — the
    /// first-launch migration always stamps a length-1 `poolIds`): falls
    /// back to `seedTaskIds` verbatim ONLY when `poolIds` is `nil`
    /// (genuinely un-migrated — see `PoolMix.isLegacyShapedRecord`'s
    /// docstring).
    ///
    /// Review finding M2: this must NOT also fall back for an empty-but-
    /// present `poolIds: []` — that shape also covers the defensive
    /// "flatten" write-through (`BoardWizardPersist.swift`'s richer-shape
    /// branch: `manualTaskIds: seedTaskIds, poolIds: [], removedTaskIds:
    /// []`). Falling back to stale `seedTaskIds` there would silently
    /// drop whatever the flatten already wrote to `manualTaskIds` — a
    /// destructive-edit bug (re-saving the hydrated-wrong selection
    /// resurrects stale seeds). `poolIds: []` resolves correctly through
    /// `PoolMix.resolveMix` below regardless of which case produced it.
    ///
    /// Any DB read failure also falls back to `seedTaskIds` (silent, like
    /// the DefaultPool prefill above) so the wizard still opens with a
    /// usable selection rather than an error.
    private static func resolveTemplateHydrationTaskIds(
        _ template: RecurringBoardTemplate,
        database: AppDatabase
    ) -> Set<String> {
        guard let poolIds = template.poolIds else {
            return Set(template.seedTaskIds)
        }
        guard let pools = try? database.fetchPools(ids: poolIds) else {
            return Set(template.seedTaskIds)
        }
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var referencedIds = Set<String>()
        for pool in pools { referencedIds.formUnion(pool.taskIds) }
        referencedIds.formUnion(template.manualTaskIds ?? [])

        guard let tasks = try? database.fetchTasks(ids: Array(referencedIds)) else {
            return Set(template.seedTaskIds)
        }
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        return Set(PoolMix.resolveMix(template, poolsById: poolsById, tasksById: tasksById).taskIds)
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

    /// Whether the core-setup "Start every <TF> board with 'X'" checkbox
    /// should render checked — true iff both `pulledPoolIds` and
    /// `savedCorePoolIds` are non-empty AND represent the same SET
    /// (order-independent). Task Pools + Recurring Boards Rework (P5).
    ///
    /// Deliberately DERIVED rather than independently tracked: recomputed
    /// on every render from the wizard's live `pulledPoolIds` against
    /// whatever is currently persisted, so toggling a pool after checking
    /// immediately (and correctly) shows unchecked again without any extra
    /// bookkeeping to keep in sync.
    static func isCorePoolDefaultSaved(pulledPoolIds: [String], savedCorePoolIds: [String]) -> Bool {
        guard !pulledPoolIds.isEmpty, !savedCorePoolIds.isEmpty else { return false }
        return Set(pulledPoolIds) == Set(savedCorePoolIds)
    }

    /// Core-setup "Start every <TF> board with 'X'" checkbox write path
    /// (Task Pools + Recurring Boards Rework, P5,
    /// docs/POOLS_RECURRING.md §Surfaces item 6). Persists `corePoolIds`
    /// ONLY via `AppDatabase.upsertCorePoolIdsAndEnqueue`, which preserves
    /// whatever `coreDefaultTaskIds` already exists (that field is
    /// P7-authored-only — never written from here). `userId` is a
    /// call-site parameter rather than a stored property, mirroring
    /// `toggleTaskSelection`'s caller-supplied-lookups pattern.
    ///
    /// - `saved == true`: persists the CURRENT `pulledPoolIds` snapshot at
    ///   check-time — not a live binding to further pool toggles. A later
    ///   pool-toggle does NOT retroactively update the saved default; the
    ///   user must re-check to capture a new snapshot.
    /// - `saved == false`: clears `corePoolIds` to `[]`. Symmetric
    ///   uncheck-to-clear is a coordinator judgment call — the handoff
    ///   spec only explicitly describes the check-to-save direction, but a
    ///   checkbox that can only ever be checked isn't a real checkbox.
    ///
    /// Silent on DB error (mirrors the rest of the wizard's pool-mix I/O
    /// resilience posture) — `savedCorePoolIds` simply doesn't update, so
    /// the checkbox visually stays wherever it was.
    func setCorePoolDefaultSaved(_ saved: Bool, userId: String) {
        let idsToSave = saved ? pulledPoolIds : []
        guard let result = try? database.upsertCorePoolIdsAndEnqueue(
            userId: userId,
            timeframe: timeframe,
            corePoolIds: idsToSave,
            now: AppDatabase.currentTimestamp()
        ) else { return }
        savedCorePoolIds = result.corePoolIds
    }

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
    func updateTimeframe(_ t: Timeframe) {
        if isRecurring && (t == .custom || t == .indefinite) { return }
        timeframe = t
    }

    /// Task Pools + Recurring Boards Rework (P4) — Step-1 "Repeats"
    /// segmented control: `nil` = "Once" (a one-off board), a `Timeframe`
    /// = the repeat cadence (also the board's window unit — a repeating
    /// board's cadence IS its timeframe, so this sets both `isRecurring`
    /// and `timeframe` together).
    ///
    /// - Leaving Once for a cadence captures the current `timeframe` as
    ///   `lastOneOffTimeframe` (coercing CUSTOM → INDEFINITE, since a
    ///   repeating board can't use either) so a later `setRepeats(nil)`
    ///   restores it. The capture only fires when NOT already recurring —
    ///   switching cadence-to-cadence (Daily → Weekly) must not clobber
    ///   the remembered one-off value with the cadence itself.
    /// - CHOSEN center is incompatible with recurring boards (the
    ///   center-type selector suppresses it in recurring mode) — picking a
    ///   cadence while CHOSEN is active coerces to FREE and clears the mark,
    ///   mirroring `updateCenterType`'s own CHOSEN-clear behavior.
    /// - Returning to Once restores `lastOneOffTimeframe` verbatim.
    var repeatsValue: Timeframe? { isRecurring ? timeframe : nil }

    func setRepeats(_ cadence: Timeframe?) {
        if let cadence {
            if !isRecurring { lastOneOffTimeframe = (timeframe == .custom) ? .indefinite : timeframe }
            isRecurring = true
            timeframe = cadence
            if centerType == .chosen { centerType = .free; centerTaskId = nil }
        } else {
            isRecurring = false
            timeframe = lastOneOffTimeframe
        }
    }

    /// Toggles a task's selection; clears the center mark if the user
    /// is deselecting the current center. Also removes the task from
    /// `pendingTasks` when the user deselects a newly-created (not-yet-
    /// persisted) task — Bug #85.
    ///
    /// P3 — also maintains the manual/removed pool-mix bookkeeping:
    /// selecting a task marks it manual; deselecting it drops the manual
    /// mark and, if it's still supplied by a currently-pulled pool, records
    /// a removal so a later `untogglePool`/re-pull behaves correctly.
    /// `poolsById`/`tasksById` default to empty — every EXISTING call site
    /// (new-task-created, from-a-board copy, context-menu add) adds a task
    /// that by construction can't already be a pool member, so the
    /// removed-bookkeeping check trivially no-ops for them; only the
    /// Tasks-step's row-remove path (routed through `BoardWizardView`'s
    /// `onToggleSelection` closure) needs to pass the real lookups.
    func toggleTaskSelection(
        _ taskId: String,
        poolsById: [String: Pool] = [:],
        tasksById: [String: Task] = [:]
    ) {
        if selectedTaskIds.contains(taskId) {
            selectedTaskIds.remove(taskId)
            if centerTaskId == taskId { centerTaskId = nil }
            // Bug #85 — purge the pending payload if this was a not-yet-
            // persisted task. No-op for library tasks (won't be in the map).
            pendingTasks.removeValue(forKey: taskId)
            poolOrder.removeAll { $0 == taskId }
            // A task that leaves the pool drops any staged edit — re-adding it
            // starts clean, matching the removal-purges-pending semantics.
            stagedEdits.removeValue(forKey: taskId)
            manualTaskIds.remove(taskId)
            if Self.isSuppliedByPulledPool(
                taskId, pulledPoolIds: pulledPoolIds, poolsById: poolsById, tasksById: tasksById
            ) {
                removedTaskIds.insert(taskId)
            }
        } else {
            selectedTaskIds.insert(taskId)
            if !poolOrder.contains(taskId) { poolOrder.append(taskId) }
            manualTaskIds.insert(taskId)
            removedTaskIds.remove(taskId)
        }
    }

    /// True when `taskId` is in the resolvable supply of any pool currently
    /// pulled into the mix — a non-deleted pool in `pulledPoolIds` whose raw
    /// `taskIds` contains it, and the task itself isn't soft-deleted. Used
    /// by `toggleTaskSelection`'s deselect branch to decide whether the
    /// removal needs `removedTaskIds` bookkeeping.
    private static func isSuppliedByPulledPool(
        _ taskId: String,
        pulledPoolIds: [String],
        poolsById: [String: Pool],
        tasksById: [String: Task]
    ) -> Bool {
        if let task = tasksById[taskId], task.isDeleted { return false }
        for poolId in pulledPoolIds {
            guard let pool = poolsById[poolId], !pool.isDeleted else { continue }
            if pool.taskIds.contains(taskId) { return true }
        }
        return false
    }

    /// "PULL IN A POOL" action (P3, docs/POOLS_RECURRING.md §Surfaces item
    /// 5) — unions the pool's resolvable supply (minus current removals)
    /// into the selection. No-op if the pool is missing, soft-deleted, or
    /// already pulled. `poolsById`/`tasksById` are supplied by the caller
    /// (see the type doc's "Pool mix" section header above).
    func pullPool(_ poolId: String, poolsById: [String: Pool], tasksById: [String: Task]) {
        guard poolsById[poolId]?.isDeleted == false, !pulledPoolIds.contains(poolId) else { return }
        let additions = PoolMix.resolvePoolPullAdditions(
            poolId, removedTaskIds: Array(removedTaskIds), poolsById: poolsById, tasksById: tasksById
        )
        for taskId in additions where !selectedTaskIds.contains(taskId) {
            selectedTaskIds.insert(taskId)
            if !poolOrder.contains(taskId) { poolOrder.append(taskId) }
        }
        pulledPoolIds.append(poolId)
    }

    /// "Untoggle a pool" action (P3) — removes only that pool's non-manual
    /// tasks that aren't still supplied by another currently-pulled pool.
    /// The manual layer is never touched; the saved `Pool` itself is never
    /// modified by this or `pullPool` (locked decision,
    /// docs/POOLS_RECURRING.md §Data model "Union rule").
    func untogglePool(_ poolId: String, poolsById: [String: Pool], tasksById: [String: Task]) {
        let remainingPoolIds = pulledPoolIds.filter { $0 != poolId }
        let removals = PoolMix.resolvePoolUntoggleRemovals(
            poolId,
            remainingPoolIds: remainingPoolIds,
            manualTaskIds: Array(manualTaskIds),
            poolsById: poolsById,
            tasksById: tasksById
        )
        for taskId in removals {
            selectedTaskIds.remove(taskId)
            poolOrder.removeAll { $0 == taskId }
            if centerTaskId == taskId { centerTaskId = nil }
            pendingTasks.removeValue(forKey: taskId)
            stagedEdits.removeValue(forKey: taskId)
        }
        removedTaskIds = Set(PoolMix.clearRemovalsForUntoggle(
            WizardPoolMixRecord(poolIds: pulledPoolIds, manualTaskIds: nil, removedTaskIds: Array(removedTaskIds)),
            untoggledPoolId: poolId,
            poolsById: poolsById
        ))
        pulledPoolIds = remainingPoolIds
    }

    /// Provenance label for every currently-selected task — `"added by
    /// hand"` or `"from <Pool name>"` — for the pool list's subtitle line.
    /// Only meaningful for ids in `selectedTaskIds` (what `RisoPoolListView`
    /// renders); a manual mark always wins, then the first pulled pool (in
    /// pull order) whose resolvable supply includes the task.
    func provenanceByTaskId(poolsById: [String: Pool], tasksById: [String: Task]) -> [String: String] {
        var result: [String: String] = [:]
        for taskId in selectedTaskIds {
            if manualTaskIds.contains(taskId) {
                result[taskId] = "added by hand"
                continue
            }
            var label: String?
            for poolId in pulledPoolIds {
                guard let pool = poolsById[poolId], !pool.isDeleted, pool.taskIds.contains(taskId) else { continue }
                if let task = tasksById[taskId], task.isDeleted { continue }
                label = "from \(pool.name)"
                break
            }
            result[taskId] = label ?? "added by hand"
        }
        return result
    }

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
        // Mirror init's CUSTOM→INDEFINITE default so a reset wizard opens
        // ongoing (End date = None), not on .custom with empty dates.
        let resolvedReset = Self.resolveTimeframe(initialPreferences.defaultTimeframe)
        timeframe = resolvedReset == .custom ? .indefinite : resolvedReset
        customStartDate = ""
        customEndDate = ""
        // Same coercion the initial factory uses, so reset can never
        // reintroduce an even-board+FREE mismatch.
        centerType = Self.coerceCenterType(
            size: nextSize,
            desired: Self.resolveCenterType(initialPreferences.defaultCenterType)
        )
        isRecurring = false
        selectedTaskIds = []
        poolOrder = []
        stagedEdits = [:]
        centerTaskId = nil
        pendingTasks = [:]
        pulledPoolIds = []
        manualTaskIds = []
        removedTaskIds = []
        savedCorePoolIds = []
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

    /// Pool-size enforcement is loose-fit on both branches:
    ///   - One-off (isRecurring=false): `count >= tasksRequired` (existing
    ///     behavior; extras are silently dropped by `BoardWizardPersist`).
    ///   - Recurring (isRecurring=true): `count >= tasksRequired`. The
    ///     spawn shuffles + slices, so any extras become the random
    ///     subset for each window. The earlier strict-fit "Use every
    ///     task" branch was dropped during the Phase 6.2 UX rework.
    var isStep2Valid: Bool {
        guard selectedTaskIds.count >= tasksRequired else { return false }
        if centerMode {
            guard let id = centerTaskId, selectedTaskIds.contains(id) else { return false }
        }
        return true
    }

    var step2ValidationMessage: String? {
        let short = tasksRequired - selectedTaskIds.count
        if short > 0 {
            let noun = "task\(short == 1 ? "" : "s")"
            if isRecurring { return "Pick \(short) more \(noun) (\(tasksRequired) minimum)." }
            return "Pick \(short) more \(noun)."
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
