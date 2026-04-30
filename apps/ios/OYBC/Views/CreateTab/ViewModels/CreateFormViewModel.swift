import Foundation
import GRDB
import Observation

/// Task type picker that includes Composite alongside the three
/// `TaskType` cases. Mirrors the web `TaskTypeOrComposite` union.
enum CreateTaskType: String, CaseIterable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
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
/// Composite tasks are handled by `CompositeTaskWizardView`; this view
/// model only covers NORMAL / COUNTING / PROGRESS.
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

    // Progress fields
    var progressSteps: [ProgressStepFormState] = [ProgressStepFormState()]
    var progressStepErrors: [UUID: ProgressStepFormErrors] = [:]

    // UI state
    var isSubmitting: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // MARK: - Derived

    /// Maps the form-level `taskType` to the resulting `TaskType` written
    /// to GRDB. Progress submissions resolve to `.compound` (with
    /// operator=AND + isOrdered=true set in `buildCreateTask`) — under the
    /// unified compound model former Progress tasks are just a compound
    /// shape. Composite returns `nil` because it routes to its own wizard.
    var selectedType: TaskType? {
        switch taskType {
        case .normal:    return .normal
        case .counting:  return .counting
        case .progress:  return .compound
        case .composite: return nil
        }
    }

    // MARK: - Actions

    /// Validates the form, persists the task (and any steps), adds the
    /// new task to the pool via `onTaskCreated`, and resets the form.
    ///
    /// - Parameters:
    ///   - userId: Authenticated user id for the new Task's `userId`.
    ///   - onTaskCreated: Called on the main queue with the resolved
    ///     title + type once the task is saved. Typical implementation
    ///     is "add to pool + show success toast".
    ///   - onLibraryReloadRequested: Called on the main queue after a
    ///     successful save so the library can refresh — without this
    ///     the new task wouldn't show up under Existing Tasks until
    ///     the next tab switch.
    func handleCreateAndAddToPool(
        userId: String,
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void,
        onLibraryReloadRequested: @escaping () -> Void
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
            // Reached only for the Progress form mode (selectedType maps
            // .progress → .compound). Composites are excluded by the
            // earlier `guard let resolvedType = selectedType else` since
            // selectedType returns nil for .composite.
            if progressSteps.isEmpty {
                errorMessage = "Progress tasks require at least one step"
                return
            }
            var stepErrors: [UUID: ProgressStepFormErrors] = [:]
            for step in progressSteps {
                var err = ProgressStepFormErrors()
                if step.type != .counting && step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    err.title = "Step title is required"
                }
                if step.type == .counting {
                    if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        err.action = "Action is required"
                    }
                    if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        err.unit = "Unit is required"
                    }
                    if (Int(step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) <= 0 {
                        err.maxCount = "Must be a positive number"
                    }
                }
                if err.hasErrors { stepErrors[step.id] = err }
            }
            progressStepErrors = stepErrors
            if !stepErrors.isEmpty {
                errorMessage = "Please fix the errors below"
                return
            }

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
                errorMessage = "Max Count must be a positive integer"
                return
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
            now: now
        )
        // Progress submit becomes a compound write: one Task with
        // type=.compound + isOrdered=true, plus one CompoundChild row per
        // step (linked to an inline-created primitive child Task). Mirrors
        // web's `useCreateFormState.handleSubmit` which routes Progress
        // through `createCompound`.
        let progressChildTasks: [Task]
        let progressChildLinks: [CompoundChild]
        if resolvedType == .compound {
            let pair = buildCompoundChildrenForProgress(parentId: taskId, userId: userId, now: now)
            progressChildTasks = pair.tasks
            progressChildLinks = pair.children
        } else {
            progressChildTasks = []
            progressChildLinks = []
        }

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
        progressSteps = [ProgressStepFormState()]
        progressStepErrors = [:]
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
    private func buildCreateTask(id: String, userId: String, type: TaskType, title: String, desc: String?, now: String) -> Task {
        switch type {
        case .normal:
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .normal, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .counting:
            let a = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .counting, action: a, unit: u, maxCount: m,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .compound:
            // The Progress form mode resolves to `.compound` (selectedType
            // maps .progress → .compound). Composite mode is excluded
            // earlier (selectedType returns nil and the submit pipeline
            // bails). So `.compound` here always means "Progress submit":
            // operator=AND + isOrdered=true with one CompoundChild per step.
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .compound,
                operatorType: .and,
                threshold: nil,
                isOrdered: true,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        }
    }

    /// Builds the unified-compound write set for a Progress submit:
    /// one freshly-allocated child Task per step (so each step is
    /// independently pool-addable, mirroring legacy progress-step
    /// behavior) plus the corresponding CompoundChild link rows.
    /// Counting steps with a blank title get an auto-generated title.
    /// Mirrors web's `createCompound(...autoCreate...)` path.
    private func buildCompoundChildrenForProgress(parentId: String, userId: String, now: String) -> (tasks: [Task], children: [CompoundChild]) {
        var tasks: [Task] = []
        var children: [CompoundChild] = []
        for (index, stepForm) in progressSteps.enumerated() {
            let trimmedAction = stepForm.action.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = stepForm.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTitle = stepForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedStepTitle: String
            if stepForm.type == .counting && trimmedTitle.isEmpty {
                let m = Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                resolvedStepTitle = "\(trimmedAction) \(m) \(trimmedUnit)"
            } else {
                resolvedStepTitle = trimmedTitle
            }
            let childTaskId = AppDatabase.generateUUID()
            let childTask = Task(
                id: childTaskId,
                userId: userId,
                title: resolvedStepTitle,
                description: nil,
                type: stepForm.type == .counting ? .counting : .normal,
                action: stepForm.type == .counting ? trimmedAction : nil,
                unit: stepForm.type == .counting ? trimmedUnit : nil,
                maxCount: stepForm.type == .counting ? Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
            let link = CompoundChild(
                id: AppDatabase.generateUUID(),
                compoundTaskId: parentId,
                childTaskId: childTaskId,
                childIndex: index,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            tasks.append(childTask)
            children.append(link)
        }
        return (tasks, children)
    }

}
