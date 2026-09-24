import Foundation
import GRDB

// MARK: - Task edit (Tasks-tab edit sheet save + Achievement re-target)
//
// One data-layer home for the `EditTaskSheet` save path. It used to be
// copied verbatim into `TaskDetailView`, `TaskDetailSheetView` and
// `TasksTabView`, each reaching `AppDatabase.shared` and printing the raw
// board UUIDs of a cycle path. The views now call `applyTaskEditPatch`
// through their injected `database` and render `taskEditErrorMessage(_:)`.
//
// iOS twin of web `checkAchievementRetargetCycle` + the edit-apply path in
// `apps/web/src/db/operations/tasks.crud.ts` — the cycle path is mapped to
// healed board display names (`Board.displayName` ↔ web `boardDisplayName`,
// so a frozen "Today" core board reads as its window), falling back to the
// id when a board can't be resolved, exactly as web does.

extension AppDatabase {

    /// Outcome of an Achievement re-target cycle check. `pathNames` is the
    /// cycle path with each board id replaced by that board's healed
    /// `displayName` (the id itself when the board can't be resolved).
    enum TaskEditCycleCheck: Equatable {
        case ok
        case cycle(pathNames: [String])
    }

    /// Why `applyTaskEditPatch` refused to save. Each case carries what the
    /// edit surfaces show verbatim via `taskEditErrorMessage(_:)`.
    enum TaskEditError: Error, Equatable {
        /// The task row is missing or soft-deleted.
        case taskNotFound
        /// The patch failed validation (user-facing message).
        case invalid(message: String)
        /// The Achievement re-target would create a reference cycle.
        case cycle(pathNames: [String])
        /// Reading the workspace for the cycle check failed.
        case cycleCheckFailed(message: String)
    }

    /// The resolved Achievement reference a patch asks for.
    private struct AchievementRetarget {
        let referencedBoardId: String?
        let referencedTemplateId: String?
        let requiredCount: Int?
    }

    /// User-facing message for an error thrown by `applyTaskEditPatch`.
    /// Non-`TaskEditError` failures (DB write errors) read "Failed to save: …".
    ///
    /// - Parameter error: The error thrown by `applyTaskEditPatch`.
    /// - Returns: The string the edit surface shows in its error slot.
    static func taskEditErrorMessage(_ error: Error) -> String {
        guard let editError = error as? TaskEditError else {
            return "Failed to save: \(error.localizedDescription)"
        }
        switch editError {
        case .taskNotFound:
            return "Failed to save: this task no longer exists."
        case .invalid(let message):
            return message
        case .cycle(let pathNames):
            return "This reference would create a cycle: \(pathNames.joined(separator: " → "))"
        case .cycleCheckFailed(let message):
            return "Cycle check failed: \(message)"
        }
    }

    /// Apply an `EditTaskSheet.Patch` to the stored task and save it with the
    /// usual version bump, sync enqueue and cross-board cascade — all in one
    /// write transaction.
    ///
    /// Validation order (unchanged from the view copies this replaces): for an
    /// Achievement, a missing board / template selection or a non-positive
    /// required count is rejected first, then the re-target is cycle-checked.
    ///
    /// Compound structure: when `patch.compound` is non-nil and the task is a
    /// Compound, the structure (operator / threshold / sub-tasks) is validated
    /// first and refused with `TaskEditError.invalid(message:)` BEFORE any
    /// write. On success the structure's title wins over the basic title, the
    /// basic description rides along, the parent gets ONE version bump + ONE
    /// sync enqueue, sub-task CRUD runs through the wizard's
    /// `applyStagedCompoundChildEdits`, then the parent cascades — the same
    /// order as the web twin `editCompoundStructure`. The task is read inside
    /// this `write`, so there is no stale-read window. A nil `compound` keeps
    /// the basic-fields-only behaviour.
    ///
    /// - Parameters:
    ///   - taskId: The task being edited.
    ///   - patch: The edit sheet's submitted values.
    ///   - now: Timestamp stamped into `updatedAt`.
    /// - Returns: The saved task.
    /// - Throws: `TaskEditError` for a refused edit; a database error if the
    ///   write fails.
    @discardableResult
    func applyTaskEditPatch(
        taskId: String,
        patch: EditTaskSheet.Patch,
        now: String = AppDatabase.currentTimestamp()
    ) throws -> Task {
        try write { db in
            guard var task = try Task.fetchOne(db, key: taskId), !task.isDeleted else {
                throw TaskEditError.taskNotFound
            }
            Self.applyBasicFields(of: patch, to: &task)

            if task.type == .compound, let structure = patch.compound {
                if let problem = structure.validate(type: .compound) {
                    throw TaskEditError.invalid(message: problem)
                }
                // title, operatorType, clamped threshold (nil unless M-of-N)
                task = structure.applied(to: task)
                Self.applyTimebox(of: patch, to: &task)
                task.updatedAt = now
                task.version += 1
                try Self.applyStagedCompoundChildEdits(db: db, parent: task, patch: structure, now: now)
                try Self.saveTaskAndCascade(db: db, task: task)
                return task
            }

            if task.type == .achievement {
                task.achievementTrigger = patch.trigger
                let retarget = try Self.validatedAchievementRetarget(patch)
                let check: TaskEditCycleCheck
                do {
                    check = try Self.checkAchievementRetargetCycle(
                        db: db,
                        taskId: task.id,
                        referencedBoardId: retarget.referencedBoardId,
                        referencedTemplateId: retarget.referencedTemplateId
                    )
                } catch {
                    throw TaskEditError.cycleCheckFailed(message: error.localizedDescription)
                }
                if case .cycle(let pathNames) = check {
                    throw TaskEditError.cycle(pathNames: pathNames)
                }
                task.referencedBoardId = retarget.referencedBoardId
                task.referencedTemplateId = retarget.referencedTemplateId
                task.requiredCount = retarget.requiredCount
            }

            Self.applyTimebox(of: patch, to: &task)
            task.updatedAt = now
            task.version += 1
            try Self.saveTaskAndCascade(db: db, task: task)
            return task
        }
    }

    /// Would saving `patch` re-target the Achievement `taskId` into a
    /// reference cycle? Returns `.ok` when the task isn't an Achievement or
    /// the patch names no valid target (validation is `applyTaskEditPatch`'s
    /// job, not this check's).
    ///
    /// - Parameters:
    ///   - taskId: The Achievement task being re-targeted.
    ///   - patch: The edit sheet's submitted values.
    /// - Returns: `.ok`, or `.cycle` with the path as board names.
    /// - Throws: A database error if the workspace read fails.
    func checkAchievementRetargetCycle(
        taskId: String,
        patch: EditTaskSheet.Patch
    ) throws -> TaskEditCycleCheck {
        try read { db in
            guard let task = try Task.fetchOne(db, key: taskId),
                  task.type == .achievement,
                  let retarget = try? Self.validatedAchievementRetarget(patch)
            else { return .ok }
            return try Self.checkAchievementRetargetCycle(
                db: db,
                taskId: taskId,
                referencedBoardId: retarget.referencedBoardId,
                referencedTemplateId: retarget.referencedTemplateId
            )
        }
    }

    /// `db`-scoped cycle check: builds the workspace context and runs
    /// `CycleDetection.hasCycle`, mapping the cycle path's board ids to healed display names.
    ///
    /// - Parameters:
    ///   - db: An open database connection.
    ///   - taskId: The Achievement task whose placements are the parents.
    ///   - referencedBoardId: Proposed specific-board reference.
    ///   - referencedTemplateId: Proposed recurring-template reference.
    /// - Returns: `.ok`, or `.cycle` with the path as board names.
    /// - Throws: A database error if a read fails.
    static func checkAchievementRetargetCycle(
        db: Database,
        taskId: String,
        referencedBoardId: String?,
        referencedTemplateId: String?
    ) throws -> TaskEditCycleCheck {
        let placements = try BoardTask
            .filter(Column("taskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        let allTasks = try Task.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoards = try Board.filter(Column("isDeleted") == false).fetchAll(db)

        let candidate = CycleCheckCandidate(
            parentBoardIds: Array(Set(placements.map { $0.boardId })),
            referencedBoardId: referencedBoardId,
            referencedTemplateId: referencedTemplateId
        )
        let context = CycleCheckContext(
            allBoardTasks: allBoardTasks,
            allTasks: allTasks,
            allBoards: allBoards
        )
        switch CycleDetection.hasCycle(candidate: candidate, context: context) {
        case .ok:
            return .ok
        case .cycle(let path):
            let nameById = Dictionary(allBoards.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            return .cycle(pathNames: path.map { nameById[$0] ?? $0 })
        }
    }

    // MARK: - Patch application (pure)

    /// Title, description and counting fields — identical for every type.
    private static func applyBasicFields(of patch: EditTaskSheet.Patch, to task: inout Task) {
        let trimmedDescription = patch.description.trimmingCharacters(in: .whitespacesAndNewlines)
        task.title = patch.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.description = trimmedDescription.isEmpty ? nil : trimmedDescription
        if task.type == .counting {
            if !patch.action.isEmpty { task.action = patch.action }
            if !patch.unit.isEmpty { task.unit = patch.unit }
            if let max = Int(patch.maxCountStr), max > 0 { task.maxCount = max }
        }
    }

    /// Timeboxed window: set when a timeframe is given, cleared on request.
    private static func applyTimebox(of patch: EditTaskSheet.Patch, to task: inout Task) {
        if let timeframe = patch.timeframe {
            task.timeframe = timeframe
            task.startDate = patch.startDate
            task.endDate = patch.endDate
        } else if patch.clearTimeboxed {
            task.timeframe = nil
            task.startDate = nil
            task.endDate = nil
        }
    }

    /// Resolve and validate the Achievement reference the patch asks for.
    ///
    /// - Throws: `TaskEditError.invalid` with the edit surface's message.
    private static func validatedAchievementRetarget(
        _ patch: EditTaskSheet.Patch
    ) throws -> AchievementRetarget {
        switch patch.refMode {
        case .board:
            guard !patch.selectedBoardId.isEmpty else {
                throw TaskEditError.invalid(message: "Please select a specific board to watch.")
            }
            return AchievementRetarget(
                referencedBoardId: patch.selectedBoardId,
                referencedTemplateId: nil,
                requiredCount: nil
            )
        case .template:
            guard !patch.selectedTemplateId.isEmpty else {
                throw TaskEditError.invalid(message: "Please select a recurring template to watch.")
            }
            guard let required = Int(patch.requiredCountStr), required > 0 else {
                throw TaskEditError.invalid(message: "Required count must be a whole number greater than 0.")
            }
            return AchievementRetarget(
                referencedBoardId: nil,
                referencedTemplateId: patch.selectedTemplateId,
                requiredCount: required
            )
        }
    }
}
