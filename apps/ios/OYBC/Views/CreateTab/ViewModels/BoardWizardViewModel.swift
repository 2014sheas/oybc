import Foundation
import Observation

/// A wizard step. 1 = Setup, 2 = Tasks, 3 = Preview & Activate.
typealias WizardStep = Int

/// Returns the number of pool tasks the chosen geometry requires.
/// Mirrors web's `tasksNeededFor` in `useBoardWizard.ts`.
///
/// - Even-sized boards (no center concept): `size²`.
/// - Odd-sized boards with FREE / CUSTOM_FREE center: `size² - 1`.
/// - Odd-sized boards with NONE: `size²`.
/// - Odd-sized boards with CHOSEN: `size²` (one selection IS the center).
func tasksNeededForBoard(size: Int, centerType: CenterSquareType) -> Int {
    let isOdd = size % 2 != 0
    let hasReservedCenter = isOdd && (centerType == .free || centerType == .customFree)
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
    var centerCustomName: String
    /// Issue #69 — board placement is always randomized. There's no
    /// manual-placement UI, so the per-board "Randomize positions"
    /// toggle (and the `defaultRandomize` preference) were dead UX and
    /// have been removed. Nothing in production ever sets this to
    /// `false` (init/reset leave the `true` default and persist always
    /// writes `true`), so it's effectively constant — it's a `var`
    /// purely so snapshot tests can pin deterministic placement.
    /// Retained on Board/RecurringBoardTemplate for schema stability.
    var isRandomized: Bool = true
    /// Phase 6.2 — when true, the wizard saves a recurring template
    /// (and immediately spawns the first board) instead of a one-off
    /// Board. Set at wizard entry (the "Create a recurring board" CTA
    /// or template edit) — there's no in-form toggle since #71. Hides
    /// Custom from the timeframe selector (recurring schema rejects it).
    var isRecurring: Bool = false
    let weekStartDay: String

    // MARK: - Step 2 fields

    var selectedTaskIds: Set<String> = []
    var centerTaskId: String? = nil

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

    init(
        preferences: UserPreferences,
        initialStep: WizardStep = 1,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        targetWindowDate: Date? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        startRecurring: Bool = false,
        userId: String? = nil
    ) {
        self.initialPreferences = preferences
        self.weekStartDay = preferences.weekStartDay.rawValue
        self.currentStep = initialStep
        self.draftBoardId = draft?.board.id
        self.targetWindowDate = targetWindowDate

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

        // Recurring mode is an explicit entry choice now (#71): the
        // Create-hub "Create a recurring board" CTA passes
        // `startRecurring`, or we're editing a template. A
        // `prefilledRecurringTimeframe` (banner / core-board browser)
        // creates a one-off *core* board for that window — NOT a
        // recurring template — so it no longer flips isRecurring (#70).
        // Captured into a local first so the timeframe-coercion below can
        // read it before `init` finishes (Swift forbids `self.` reads
        // until every stored property is set).
        let isRecurringAtEntry = effectiveTemplate != nil || startRecurring
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
            self.centerCustomName = d.board.centerSquareCustomName ?? ""
            self.centerTaskId = d.board.centerTaskId
            self.selectedTaskIds = Set(d.boardTasks.map { $0.taskId })
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
            self.centerCustomName = t.centerSquareCustomName ?? ""
            self.selectedTaskIds = Set(t.seedTaskIds)
        } else {
            let initialSize = preferences.defaultBoardSize.rawValue
            self.size = initialSize
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
                // Phase 6.X — Default Pool prefill: when banner-launched
                // and a DefaultPool exists for `(userId, timeframe)`,
                // hydrate `selectedTaskIds` from the pool's taskIds.
                // Silent on DB error — the wizard still opens with an
                // empty selection so the user can build a board manually.
                if let userId = userId,
                   let pool = try? AppDatabase.shared.fetchDefaultPool(userId: userId, timeframe: timeframe),
                   !pool.taskIds.isEmpty {
                    self.selectedTaskIds = Set(pool.taskIds)
                }
            } else {
                let resolved = Self.resolveTimeframe(preferences.defaultTimeframe)
                // The "Custom" segment defaults to an ongoing board (End date =
                // None); a dated range is opt-in via the End-date control. So a
                // CUSTOM default resolves to .indefinite for a fresh board.
                // Recurring templates can't use CUSTOM/INDEFINITE (no computed
                // window) → fall back to daily in the recurring CTA.
                if resolved == .custom {
                    self.timeframe = isRecurringAtEntry ? .daily : .indefinite
                } else {
                    self.timeframe = resolved
                }
            }
            self.centerType = Self.coerceCenterType(
                size: initialSize,
                desired: Self.resolveCenterType(preferences.defaultCenterType)
            )
            self.centerCustomName = preferences.defaultCenterCustomName
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
    /// them, so a leaked FREE/CUSTOM_FREE from prefs would be
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
        case .daily:   return .daily
        case .weekly:  return .weekly
        case .monthly: return .monthly
        case .yearly:  return .yearly
        case .custom:  return .custom
        }
    }

    // MARK: - Coupled mutators

    /// Changes board size and resets center type when crossing the
    /// odd/even boundary so the model stays consistent.
    func updateSize(_ s: Int) {
        size = s
        let newIsOdd = s % 2 != 0
        if !newIsOdd {
            centerType = .none
            centerTaskId = nil
        } else if centerType == .none {
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

    /// Toggles a task's selection; clears the center mark if the user
    /// is deselecting the current center. Also removes the task from
    /// `pendingTasks` when the user deselects a newly-created (not-yet-
    /// persisted) task — Bug #85.
    func toggleTaskSelection(_ taskId: String) {
        if selectedTaskIds.contains(taskId) {
            selectedTaskIds.remove(taskId)
            if centerTaskId == taskId { centerTaskId = nil }
            // Bug #85 — purge the pending payload if this was a not-yet-
            // persisted task. No-op for library tasks (won't be in the map).
            pendingTasks.removeValue(forKey: taskId)
        } else {
            selectedTaskIds.insert(taskId)
        }
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
        timeframe = Self.resolveTimeframe(initialPreferences.defaultTimeframe)
        customStartDate = ""
        customEndDate = ""
        // Same coercion the initial factory uses, so reset can never
        // reintroduce an even-board+FREE mismatch.
        centerType = Self.coerceCenterType(
            size: nextSize,
            desired: Self.resolveCenterType(initialPreferences.defaultCenterType)
        )
        centerCustomName = initialPreferences.defaultCenterCustomName
        isRecurring = false
        selectedTaskIds = []
        centerTaskId = nil
        pendingTasks = [:]
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
