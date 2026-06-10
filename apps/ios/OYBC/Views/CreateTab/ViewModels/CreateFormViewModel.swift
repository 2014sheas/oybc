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
    /// picker in `CreateNewTaskFormView`. The picker renders via
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

/// Owns the Create-New tab's form state — fields, validation errors,
/// submit pipeline, reset. Mirrors web's `useCreateFormState` hook.
///
/// Submit sequence: trim fields → validate → build `Task` + step
/// records → write to GRDB on a background queue → add the new task
/// to the pool (via `onTaskCreated`) → reset the form → ask the
/// library to reload so the new task appears under Existing Tasks.
///
/// Compound tasks are handled by `CompositeTaskWizardView`; this view
/// model only covers NORMAL / COUNTING / ACHIEVEMENT.
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

    // UI state
    var isSubmitting: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // MARK: - Derived

    /// Maps the form-level `taskType` to the resulting `TaskType` written
    /// to GRDB. Compound returns `nil` because it routes to its own wizard
    /// (`CompositeTaskWizardView`) which owns the full creation transaction.
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
            // the .compound CreateTaskType case, which routes to
            // CompositeTaskWizardView. This branch satisfies exhaustive
            // switching on TaskType but should never execute.
            break

        case .counting:
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else {
                errorMessage = "Action is required for Counting tasks"
                return
            }
            guard a.count <= CreateFormLimits.action else {
                errorMessage = "Action must be \(CreateFormLimits.action) characters or less"
                return
            }
            guard !u.isEmpty else {
                errorMessage = "Unit is required for Counting tasks"
                return
            }
            guard u.count <= CreateFormLimits.unit else {
                errorMessage = "Unit must be \(CreateFormLimits.unit) characters or less"
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
        if resolvedType == .counting && trimmedTitle.isEmpty {
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            resolvedTitle = "\(a) \(m) \(u)"
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
            let payload = PendingTaskPayload(
                task: newTask,
                childTasks: progressChildTasks,
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
                    try AppDatabase.shared.saveTask(newTask)
                    try AppDatabase.shared.write { db in
                        try SyncQueueBuilder.makeItem(
                            entityType: "tasks",
                            entityId: newTask.id,
                            operationType: .create,
                            payload: newTask,
                            now: now
                        ).save(db)
                    }
                } else {
                    try AppDatabase.shared.write { db in
                        try newTask.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "tasks",
                            entityId: newTask.id,
                            operationType: .create,
                            payload: newTask,
                            now: now
                        ).save(db)

                        for (childTask, link) in zip(progressChildTasks, progressChildLinks) {
                            try childTask.save(db)
                            try SyncQueueBuilder.makeItem(
                                entityType: "tasks",
                                entityId: childTask.id,
                                operationType: .create,
                                payload: childTask,
                                now: now
                            ).save(db)
                            try link.save(db)
                            try SyncQueueBuilder.makeItem(
                                entityType: "compoundChildren",
                                entityId: link.id,
                                operationType: .create,
                                payload: link,
                                now: now
                            ).save(db)
                        }
                    }
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
                timeframe: timeframe, startDate: startDate, endDate: endDate
            )
        case .compound:
            // Unreachable — compound CreateTaskType returns nil from
            // selectedType, so this path never executes. Kept for
            // exhaustive switching on TaskType.
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

