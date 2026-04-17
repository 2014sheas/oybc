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
/// Composite tasks are handled by `CompositeTaskFormView`; this view
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

    // Progress fields
    var progressSteps: [ProgressStepFormState] = [ProgressStepFormState()]
    var progressStepErrors: [UUID: ProgressStepFormErrors] = [:]

    // UI state
    var isSubmitting: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // MARK: - Derived

    /// Maps `taskType` to a concrete `TaskType`. `nil` for Composite
    /// (which routes to a separate view).
    var selectedType: TaskType? {
        switch taskType {
        case .normal:    return .normal
        case .counting:  return .counting
        case .progress:  return .progress
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

        case .progress:
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
        let newSteps: [TaskStep] = resolvedType == .progress
            ? buildCreateSteps(taskId: taskId, userId: userId, now: now)
            : []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if newSteps.isEmpty {
                    try AppDatabase.shared.saveTask(newTask)
                } else {
                    try AppDatabase.shared.write { db in
                        try newTask.save(db)
                        for var step in newSteps {
                            // Create a standalone task for each step so the step
                            // is immediately pool-addable via cross-board rollup.
                            let stepTaskId = AppDatabase.generateUUID()
                            let stepTask = Task(
                                id: stepTaskId,
                                userId: userId,
                                title: step.title,
                                type: step.type,
                                action: step.action,
                                unit: step.unit,
                                maxCount: step.maxCount,
                                totalCompletions: 0,
                                totalInstances: 0,
                                createdAt: now,
                                updatedAt: now,
                                version: 1,
                                isDeleted: false
                            )
                            try stepTask.save(db)
                            step.linkedTaskId = stepTaskId
                            try step.save(db)
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
        progressSteps = [ProgressStepFormState()]
        progressStepErrors = [:]
    }

    /// Clears the transient error/success banners. Called on mode or
    /// task-type change so stale feedback doesn't linger.
    func clearFeedback() {
        errorMessage = nil
        successMessage = nil
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
        case .progress:
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .progress, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        }
    }

    /// Builds `TaskStep` records from the current progress-step form
    /// state. Counting steps with a blank title get an auto-generated
    /// title matching the shared `generateCounterTaskTitle` format.
    private func buildCreateSteps(taskId: String, userId: String, now: String) -> [TaskStep] {
        progressSteps.enumerated().map { index, stepForm in
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
            return TaskStep(
                id: AppDatabase.generateUUID(),
                taskId: taskId,
                stepIndex: index,
                title: resolvedStepTitle,
                type: stepForm.type == .counting ? .counting : .normal,
                action: stepForm.type == .counting ? trimmedAction : nil,
                unit: stepForm.type == .counting ? trimmedUnit : nil,
                maxCount: stepForm.type == .counting ? Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        }
    }
}
