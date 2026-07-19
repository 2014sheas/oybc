import Foundation
import GRDB
import Observation

// MARK: - PendingTaskPayload

/// Bug #85 — Payload for a wizard-created task that has NOT yet been
/// written to the DB. Mirrors web's `PendingTaskPayload` interface in
/// `useCreateFormState.ts`.
///
/// `BoardWizardViewModel` stores these keyed by `task.id`. At board-save
/// time, `persistWizardBoard` drains the map inside the existing GRDB
/// write block — parent task first, then child tasks, then
/// `compound_children` links — before writing `board_tasks` rows that
/// reference them. Abandoning the wizard silently discards the map
/// with zero cleanup because nothing was ever persisted.
struct PendingTaskPayload {
    /// The parent (or standalone) task built in memory.
    let task: OYBC.Task
    /// Inline-created child tasks for compound/progress types. Empty
    /// for NORMAL / COUNTING / ACHIEVEMENT tasks.
    let childTasks: [OYBC.Task]
    /// `CompoundChild` link rows corresponding to `childTasks`. Same
    /// count and same order. Empty for non-compound types.
    let childLinks: [CompoundChild]
}

/// Task type picker that maps to the 4 unified `TaskType` cases.
/// Mirrors the web create form, which uses `TaskType` directly after
/// the Progress/Composite merge (the old `TaskTypeOrComposite` union
/// was removed). Compound is authored via the compound wizard.
enum CreateTaskType: String, CaseIterable {
    case normal = "Normal"
    case counting = "Counting"
    case compound = "Compound"
    /// Phase 6.3 — Achievement (cross-board watcher).
    case achievement = "Achievement"

    /// Standard 4-letter abbreviation used by the segmented type
    /// picker (UIKit UISegmentedControl). The picker renders via
    /// UIKit's `UISegmentedControl`, which allocates equal width per
    /// segment and ignores per-`Text` SwiftUI font modifiers — so
    /// the full `rawValue` "Achievement" (11 chars) truncates with
    /// `…` on phone-class widths. The form pairs the picker with a
    /// caption below showing the current selection's full `rawValue`
    /// so the abbreviation never loses meaning.
    ///
    /// All abbreviations are exactly 4 chars: first-4-letters for
    /// most (Norm, Coun) plus a consonant-drop form for Compound
    /// (Cmpd) and mild vowel-drop for Achievement (Achv). "Comp" was
    /// retired alongside the Composite label to avoid visual
    /// confusion; "Cmpd" matches the web badge abbreviation.
    ///
    /// All other surfaces (badges, filter chips, detail views)
    /// continue to display the full `rawValue` — this property is
    /// scoped to the segmented picker.
    var shortLabel: String {
        switch self {
        case .normal:      return "Norm"
        case .counting:    return "Coun"
        case .compound:    return "Cmpd"
        case .achievement: return "Achv"
        }
    }
}

/// Phase 6.3 — Achievement-mode picker for the Create form. Mirrors
/// the web `AchievementMode` union. The rawValue strings are the
/// segmented-picker labels — domain terms verbatim, no paraphrase.
enum AchievementMode: String, CaseIterable {
    case specificBoard = "Board"
    case recurringTemplate = "Template"
}

/// Validation-length limits for the Create form. Exported so the
/// presentation layer can render character counts alongside the
/// matching inputs without hardcoding the numbers.
enum CreateFormLimits {
    static let title = 200
    static let description = 1000
    static let action = 50
    static let unit = 50
    static let stepTitle = 200
}

/// Owns the task-creation form state — fields, validation errors,
/// submit pipeline, reset. Mirrors web's `useCreateFormState` hook.
///
/// Submit sequence: trim fields → validate → build `Task` + step
/// records → write to GRDB on a background queue → add the new task
/// to the pool (via `onTaskCreated`) → reset the form → ask the
/// library to reload so the new task appears under Existing Tasks.
///
/// Compound tasks are handled by the inline `RisoCompoundFieldsView`
/// builder (via `handleCreateCompoundAndAddToPool`). Normal, Counting,
/// and Achievement use `handleCreateAndAddToPool`.
@Observable
final class CreateFormViewModel {

    // MARK: - Form fields

    var taskType: CreateTaskType = .normal

    var title: String = ""
    var description: String = ""

    // Counting fields
    var countingAction: String = ""
    var countingUnit: String = ""
    var countingMaxCount: String = ""

    /// The counting Task currently used as a derivation template, or nil.
    /// When set, `countingAction` and `countingUnit` are pre-filled from
    /// this task. Only relevant when `taskType == .counting`.
    var countingDeriveFromTask: OYBC.Task? = nil

    // Counter-link suggestion (Shared Counters — counter-link-suggest).
    // Non-nil when the user confirmed the counter-link suggestion banner in
    // the counting create panel. Written from `RisoSpecialTaskPanel` before
    // calling `handleCreateAndAddToPool`.
    //
    // When set, the new task is linked to the given counter source:
    //   sharedCounterId = countingSharedCounterId
    //   baseline        = countingBaseline
    //     - "Start fresh": baseline = source.currentCount at link time
    //       → displayed = source.currentCount − baseline (starts at 0).
    //     - "Inherit total": baseline = 0
    //       → displayed = source.currentCount (inherits the running total).
    var countingSharedCounterId: String? = nil
    var countingBaseline: Int? = nil

    // UI state
    var isSubmitting: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // MARK: - Derived

    /// Maps the form-level `taskType` to the resulting `TaskType` written
    /// to GRDB. Compound returns `nil` because it routes to the inline
    /// `RisoCompoundFieldsView` builder via `handleCreateCompoundAndAddToPool`.
    var selectedType: TaskType? {
        switch taskType {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return nil
        case .achievement: return .achievement
        }
    }

    // MARK: - Achievement (Phase 6.3)

    /// Watch-mode for ACHIEVEMENT tasks. `specificBoard` is the default
    /// because most users will likely watch a single named longer-running
    /// board rather than a template's spawns.
    var achievementMode: AchievementMode = .specificBoard
    /// The picker-selected board id (when `achievementMode == .specificBoard`)
    /// OR template id (when `achievementMode == .recurringTemplate`).
    /// Serialized to `referencedBoardId` XOR `referencedTemplateId` on the
    /// new Task at submit time.
    var achievementReferenceId: String?
    /// Completion trigger. Default `.greenlog` matches the pre-trigger
    /// shipped behavior; user can flip to `.bingo` via the picker.
    var achievementTrigger: AchievementTrigger = .greenlog
    /// Required spawn count for template mode. Stored as string so the
    /// input field can be empty (no auto-zero); parsed at submit time.
    var achievementRequiredCountStr: String = ""

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Actions

    /// Validates the form and either persists the task immediately (default)
    /// or builds it fully in memory and fires the deferred callbacks
    /// (Bug #85 — wizard mode).
    ///
    /// - Parameters:
    ///   - userId: Authenticated user id for the new Task's `userId`.
    ///   - onTaskCreated: Called on the main queue with the resolved
    ///     title + type once the task is saved (or built in deferred mode).
    ///     Typical implementation is "add to pool + show success toast".
    ///   - onLibraryReloadRequested: Called on the main queue after a
    ///     successful save so the library can refresh — without this
    ///     the new task wouldn't show up under Existing Tasks until
    ///     the next tab switch. Ignored in deferred mode (no DB write).
    ///   - defaultTimeframe: Inherited timeframe triple from the wizard
    ///     or nil for indefinite tasks (standalone Tasks-tab quick-add).
    ///   - deferPersist: Bug #85 — When `true`, the form builds the task
    ///     (and any inline compound children) fully in memory and fires
    ///     `onTaskCreated` + `onPendingCreated` WITHOUT writing anything
    ///     to GRDB or the sync queue. The wizard is responsible for
    ///     persisting inside `persistWizardBoard`'s write block.
    ///     When `false` (default), existing immediate-persist behaviour
    ///     is preserved so standalone quick-add is unchanged.
    ///   - onPendingCreated: Bug #85 — Called alongside `onTaskCreated`
    ///     when `deferPersist == true`. Receives the full
    ///     `PendingTaskPayload` (task + any child tasks + link rows) so
    ///     the wizard can store it for the board-save transaction. Ignored
    ///     when `deferPersist == false`.
    func handleCreateAndAddToPool(
        userId: String,
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void,
        onLibraryReloadRequested: @escaping () -> Void,
        // Phase 6.Y — Timeboxed Tasks. When provided (typically from
        // the board wizard's currentTimeframe + resolved dates), the
        // newly-created Task inherits this triple. Standalone Tasks-
        // tab usage passes nil and the task is indefinite.
        defaultTimeframe: Timeframe? = nil,
        defaultStartDate: String? = nil,
        defaultEndDate: String? = nil,
        deferPersist: Bool = false,
        onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let resolvedType = selectedType else { return }

        if resolvedType != .counting {
            guard !trimmedTitle.isEmpty else {
                errorMessage = "Title is required"
                return
            }
        }
        guard trimmedTitle.count <= CreateFormLimits.title else {
            errorMessage = "Title must be \(CreateFormLimits.title) characters or less"
            return
        }
        guard trimmedDesc.count <= CreateFormLimits.description else {
            errorMessage = "Description must be \(CreateFormLimits.description) characters or less"
            return
        }

        switch resolvedType {
        case .normal:
            break

        case .compound:
            // .compound is never reached here — selectedType returns nil for
            // the .compound CreateTaskType case, which routes to the inline
            // RisoCompoundFieldsView builder. This branch satisfies exhaustive
            // switching on TaskType but should never execute.
            break

        case .counting:
            // R1 counters refresh — field names are Verb/Goal/Counting
            // everywhere (RisoSpecialTaskPanel's labels); these error
            // strings are the web parity contract for the same relabel
            // (apps/web/src/pages/createPage/useCreateFormState.ts).
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else {
                errorMessage = "Verb is required"
                return
            }
            guard a.count <= CreateFormLimits.action else {
                errorMessage = "Verb must be \(CreateFormLimits.action) characters or less"
                return
            }
            guard !u.isEmpty else {
                errorMessage = "Counting is required"
                return
            }
            guard u.count <= CreateFormLimits.unit else {
                errorMessage = "Counting must be \(CreateFormLimits.unit) characters or less"
                return
            }
            guard !m.isEmpty else {
                errorMessage = "Goal is required"
                return
            }
            guard let v = Int(m), v > 0 else {
                errorMessage = "Goal must be a positive integer"
                return
            }

        case .achievement:
            // Phase 6.3 — Achievement tasks must reference exactly one
            // target. The form's submit pipeline serializes the picker
            // selection into either `referencedBoardId` or
            // `referencedTemplateId` on the new Task.
            guard let _ = achievementReferenceId, !achievementReferenceId!.isEmpty else {
                switch achievementMode {
                case .specificBoard:
                    errorMessage = "Pick a board to watch"
                case .recurringTemplate:
                    errorMessage = "Pick a recurring template to watch"
                }
                return
            }
            // Recurring-template mode requires a positive count.
            if achievementMode == .recurringTemplate {
                let trimmed = achievementRequiredCountStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = Int(trimmed), parsed > 0 else {
                    errorMessage = "Required count must be a positive integer"
                    return
                }
                _ = parsed
            }
        }

        isSubmitting = true
        errorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let taskId = AppDatabase.generateUUID()

        let resolvedTitle: String
        if resolvedType == .counting {
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            resolvedTitle = TaskTitle.generateCounterTaskTitle(
                action: a, maxCount: m, unit: u, providedTitle: trimmedTitle
            )
        } else {
            resolvedTitle = trimmedTitle
        }

        let newTask = buildCreateTask(
            id: taskId,
            userId: userId,
            type: resolvedType,
            title: resolvedTitle,
            desc: trimmedDesc.isEmpty ? nil : trimmedDesc,
            now: now,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate
        )
        // Compound tasks are never submitted through this path — selectedType
        // returns nil for .compound so the guard above always exits early.
        // These arrays remain empty; the write block below short-circuits
        // through the non-compound path.
        let progressChildTasks: [Task] = []
        let progressChildLinks: [CompoundChild] = []

        // ── Bug #85: Deferred-persist path ──────────────────────────────────
        // When invoked from the board wizard, skip all DB writes. Build the
        // PendingTaskPayload in memory and hand it to the wizard via
        // `onPendingCreated` so it can be written atomically inside the
        // board-save transaction. `onTaskCreated` still fires so the wizard
        // adds the id to `selectedTaskIds` and the Tasks step shows the row.
        if deferPersist {
            // Mark the deferred task (and any inline children) as wizard-born
            // so library-browse surfaces hide it until its board goes active.
            var deferredTask = newTask
            deferredTask.createdInWizard = true
            let deferredChildTasks = progressChildTasks.map { child -> Task in
                var c = child
                c.createdInWizard = true
                return c
            }
            let payload = PendingTaskPayload(
                task: deferredTask,
                childTasks: deferredChildTasks,
                childLinks: progressChildLinks
            )
            isSubmitting = false
            // Deferred-persist banner — the task is NOT yet in GRDB; it
            // only commits when the wizard saves the board. Wording
            // reflects that so the user doesn't think the task already
            // exists in their library.
            let successText = "Pending: \"\(resolvedTitle)\" — saved with the board"
            successMessage = successText
            resetForm()
            onTaskCreated(taskId, resolvedTitle, resolvedType.rawValue)
            onPendingCreated?(payload)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if self.successMessage == successText { self.successMessage = nil }
            }
            return
        }

        // ── Immediate-persist path (default — standalone quick-add) ─────────
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if progressChildLinks.isEmpty {
                    try self.database.createTaskAndEnqueue(newTask, now: now)
                } else {
                    try self.database.createTaskWithPairedChildrenAndEnqueue(
                        task: newTask,
                        childTasks: progressChildTasks,
                        childLinks: progressChildLinks,
                        now: now
                    )
                }
                DispatchQueue.main.async {
                    self.isSubmitting = false
                    onTaskCreated(taskId, resolvedTitle, resolvedType.rawValue)
                    let successText = "Created & added to pool: \"\(resolvedTitle)\""
                    self.successMessage = successText
                    self.resetForm()
                    onLibraryReloadRequested()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.successMessage == successText {
                            self.successMessage = nil
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSubmitting = false
                    self.errorMessage = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Resets every form field + clears inline errors so the next
    /// submission starts from a fresh state.
    func resetForm() {
        title = ""
        description = ""
        countingAction = ""
        countingUnit = ""
        countingMaxCount = ""
        countingDeriveFromTask = nil
        countingSharedCounterId = nil
        countingBaseline = nil
        achievementMode = .specificBoard
        achievementReferenceId = nil
        achievementTrigger = .greenlog
        achievementRequiredCountStr = ""
    }

    /// Clears the transient error/success banners. Called on mode or
    /// task-type change so stale feedback doesn't linger.
    func clearFeedback() {
        errorMessage = nil
        successMessage = nil
    }

    /// Applies a counting task as the derivation template: pre-fills
    /// `countingAction` and `countingUnit` from the source task and clears
    /// `countingMaxCount` so the user must enter a fresh value.
    ///
    /// - Parameter source: The counting `Task` to use as a template.
    func applyTemplate(_ source: OYBC.Task) {
        countingDeriveFromTask = source
        countingAction = source.action ?? ""
        countingUnit = source.unit ?? ""
        countingMaxCount = ""
        clearFeedback()
    }

    /// Clears the derivation template and resets `countingAction`,
    /// `countingUnit`, and `countingMaxCount` back to empty strings.
    func clearTemplate() {
        countingDeriveFromTask = nil
        countingAction = ""
        countingUnit = ""
        countingMaxCount = ""
        clearFeedback()
    }

    // MARK: - Compound creation

    /// A sub-task entry for the inline compound builder. Each sub is
    /// either a reference to an EXISTING library task or a NEW inline-
    /// created primitive (Normal or Counting only — no nested compounds).
    enum CompoundSubItem {
        /// Reference to a task already persisted in the user's library.
        case existing(taskId: String, title: String, type: TaskType)
        /// Inline Normal task to be created on submit.
        case newNormal(title: String)
        /// Inline Counting task to be created on submit.
        /// title is auto-generated as "\(action) \(goal) \(unit)" at save time.
        ///
        /// - Parameters:
        ///   - sharedCounterId: R1 counters refresh — auto-link. Non-nil
        ///     when the sub's (verb, noun) pair matched an existing counter
        ///     and the user hasn't opted out via the "Don't link" hint, so
        ///     the inline-created child is born already linked (mirrors
        ///     `Task.sharedCounterId`). Must be paired with `baseline`.
        ///   - baseline: The auto-link baseline — always the matched
        ///     counter's lifetime count at add time ("start fresh": the new
        ///     sub's own window begins at 0). Must be set when
        ///     `sharedCounterId` is set.
        case newCounting(action: String, goal: Int, unit: String, sharedCounterId: String?, baseline: Int?)

        /// Display title for the sub chip in the UI.
        var displayTitle: String {
            switch self {
            case .existing(_, let t, _): return t
            case .newNormal(let t): return t
            case .newCounting(let a, let g, let u, _, _):
                return TaskTitle.generateCounterTaskTitle(action: a, maxCount: g, unit: u)
            }
        }

        /// The `TaskType` of this sub, for type-dot decoration.
        var taskType: TaskType {
            switch self {
            case .existing(_, _, let t): return t
            case .newNormal: return .normal
            case .newCounting: return .counting
            }
        }
    }

    /// Compound completion rule choices for the inline panel.
    /// Maps to operator/threshold/isOrdered on the Task row verbatim.
    enum CompoundRule {
        /// All sub-tasks must complete — operatorType .and, isOrdered false.
        case allOf
        /// Any single sub-task completes the parent — operatorType .or, isOrdered false.
        case anyOf
        /// At least N sub-tasks must complete — operatorType .mOfN, threshold N, isOrdered false.
        case atLeastN(threshold: Int)
        /// All sub-tasks in strict order — operatorType .and, isOrdered true.
        case inOrder

        var label: String {
            switch self {
            case .allOf:      return "All of"
            case .anyOf:      return "Any of"
            case .atLeastN:   return "At least N"
            case .inOrder:    return "In order"
            }
        }

        /// The OperatorType value to write to the Task row.
        var operatorType: OperatorType {
            switch self {
            case .allOf, .inOrder: return .and
            case .anyOf:            return .or
            case .atLeastN:         return .mOfN
            }
        }

        /// The threshold value — only non-nil when rule is .atLeastN.
        var threshold: Int? {
            if case .atLeastN(let n) = self { return n }
            return nil
        }

        /// Whether to set Task.isOrdered = true.
        var isOrdered: Bool { if case .inOrder = self { return true }; return false }
    }

    /// Validates the supplied inputs and either creates the compound task
    /// immediately (writes parent + children atomically to GRDB) or
    /// defers the payload for the wizard to persist as part of the board-
    /// save transaction (Bug #85).
    ///
    /// Rule → field mapping (verbatim from the inline compound builder):
    ///   - All of  → operatorType .and,  isOrdered false, threshold nil
    ///   - Any of  → operatorType .or,   isOrdered false, threshold nil
    ///   - At least N → operatorType .mOfN, isOrdered false, threshold N
    ///   - In order   → operatorType .and, isOrdered true,  threshold nil
    ///
    /// - Parameters:
    ///   - userId: Authenticated user id for Task.userId.
    ///   - title: Trimmed compound task title. Must be non-empty.
    ///   - rule: Completion rule — drives operator/threshold/isOrdered.
    ///   - subs: Ordered list of sub-task entries (min 2).
    ///   - onTaskCreated: Called on main queue with (parentId, title, "Compound").
    ///   - onLibraryReloadRequested: Called on main queue after an immediate-persist
    ///     write so the library refresh includes the new task.
    ///   - defaultTimeframe: Inherited wizard timeframe (or nil for indefinite).
    ///   - defaultStartDate / defaultEndDate: Inherited wizard date range.
    ///   - deferPersist: Bug #85 — when true, skips DB writes and fires
    ///     `onPendingCreated` with the fully-built `PendingTaskPayload`.
    ///   - onPendingCreated: Bug #85 — receives the payload when `deferPersist == true`.
    func handleCreateCompoundAndAddToPool(
        userId: String,
        title: String,
        rule: CompoundRule,
        subs: [CompoundSubItem],
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void,
        onLibraryReloadRequested: @escaping () -> Void,
        defaultTimeframe: Timeframe? = nil,
        defaultStartDate: String? = nil,
        defaultEndDate: String? = nil,
        deferPersist: Bool = false,
        onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard subs.count >= 2 else { return }

        isSubmitting = true
        errorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let compoundId = AppDatabase.generateUUID()

        let resolvedOperator = rule.operatorType
        let resolvedThreshold: Int? = resolvedOperator == .mOfN ? rule.threshold : nil
        let resolvedIsOrdered = rule.isOrdered

        let parentTask = OYBC.Task(
            id: compoundId,
            userId: userId,
            title: trimmedTitle,
            description: nil,
            type: .compound,
            operatorType: resolvedOperator,
            threshold: resolvedThreshold,
            isOrdered: resolvedIsOrdered,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate
        )

        // Build child tasks + link rows. For EXISTING subs the child task is
        // already in GRDB — only the CompoundChild link row is new. For NEW
        // inline subs both the child Task row and the CompoundChild link are new.
        var childTasks: [OYBC.Task] = []
        var childLinks: [CompoundChild] = []

        for (index, sub) in subs.enumerated() {
            let childTaskId: String
            switch sub {
            case .existing(let id, _, _):
                childTaskId = id
                // No new Task row — already persisted in the library.

            case .newNormal(let subTitle):
                let newId = AppDatabase.generateUUID()
                let newTask = OYBC.Task(
                    id: newId,
                    userId: userId,
                    title: subTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: nil,
                    type: .normal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )
                childTasks.append(newTask)
                childTaskId = newId

            case .newCounting(let action, let goal, let unit, let sharedCounterId, let baseline):
                let newId = AppDatabase.generateUUID()
                let autoTitle = TaskTitle.generateCounterTaskTitle(action: action, maxCount: goal, unit: unit)
                let newTask = OYBC.Task(
                    id: newId,
                    userId: userId,
                    title: autoTitle,
                    description: nil,
                    type: .counting,
                    action: action.trimmingCharacters(in: .whitespacesAndNewlines),
                    unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxCount: goal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false,
                    // R1 counters refresh — auto-link (see
                    // `CompoundSubItem.newCounting` doc).
                    sharedCounterId: sharedCounterId,
                    baseline: baseline
                )
                childTasks.append(newTask)
                childTaskId = newId
            }

            let link = CompoundChild(
                id: AppDatabase.generateUUID(),
                compoundTaskId: compoundId,
                childTaskId: childTaskId,
                childIndex: index,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            childLinks.append(link)
        }

        // ── Bug #85: Deferred-persist path ──────────────────────────────────
        if deferPersist {
            // Mark the deferred compound parent + its NEW inline children as
            // wizard-born. Existing-library children are referenced by id only
            // (not in `childTasks`), so their provenance is untouched.
            var deferredParent = parentTask
            deferredParent.createdInWizard = true
            let deferredChildTasks = childTasks.map { child -> Task in
                var c = child
                c.createdInWizard = true
                return c
            }
            let payload = PendingTaskPayload(
                task: deferredParent,
                childTasks: deferredChildTasks,
                childLinks: childLinks
            )
            isSubmitting = false
            let successText = "Pending: \"\(trimmedTitle)\" — saved with the board"
            successMessage = successText
            onTaskCreated(compoundId, trimmedTitle, TaskType.compound.rawValue)
            onPendingCreated?(payload)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if self.successMessage == successText { self.successMessage = nil }
            }
            return
        }

        // ── Immediate-persist path ───────────────────────────────────────────
        let capturedChildTasks = childTasks
        let capturedChildLinks = childLinks
        let capturedParent = parentTask

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // Parent compound + its children/links are written +
                // sync-enqueued atomically by the data layer. A child Task row
                // is inserted only for NEW inline children; existing-library
                // children are referenced by id (already in GRDB).
                try self.database.createCompoundAndEnqueue(
                    parent: capturedParent,
                    newChildTasks: capturedChildTasks,
                    childLinks: capturedChildLinks,
                    now: now
                )

                DispatchQueue.main.async {
                    self.isSubmitting = false
                    onTaskCreated(compoundId, trimmedTitle, TaskType.compound.rawValue)
                    let successText = "Created & added to pool: \"\(trimmedTitle)\""
                    self.successMessage = successText
                    onLibraryReloadRequested()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.successMessage == successText { self.successMessage = nil }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSubmitting = false
                    self.errorMessage = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Build helpers

    /// Builds a `Task` record for the resolved task type. Pulls the
    /// counting-specific fields from the view model's state.
    private func buildCreateTask(
        id: String,
        userId: String,
        type: TaskType,
        title: String,
        desc: String?,
        now: String,
        timeframe: Timeframe? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) -> Task {
        switch type {
        case .normal:
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .normal, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false,
                timeframe: timeframe, startDate: startDate, endDate: endDate
            )
        case .counting:
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .counting, action: a, unit: u, maxCount: m,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false,
                timeframe: timeframe, startDate: startDate, endDate: endDate,
                sharedCounterId: countingSharedCounterId,
                baseline: countingBaseline
            )
        case .compound:
            // Unreachable — compound CreateTaskType returns nil from
            // selectedType; compounds route through handleCreateCompoundAndAddToPool.
            // Kept for exhaustive switching on TaskType.
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .compound,
                operatorType: .and,
                threshold: nil,
                isOrdered: false,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false,
                timeframe: timeframe, startDate: startDate, endDate: endDate
            )
        case .achievement:
            let isTemplateMode = (achievementMode == .recurringTemplate)
            let parsedCount: Int? = isTemplateMode
                ? Int(achievementRequiredCountStr.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .achievement,
                referencedBoardId: achievementMode == .specificBoard ? achievementReferenceId : nil,
                referencedTemplateId: isTemplateMode ? achievementReferenceId : nil,
                achievementTrigger: achievementTrigger,
                requiredCount: parsedCount,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false,
                timeframe: timeframe, startDate: startDate, endDate: endDate
            )
        }
    }

}

