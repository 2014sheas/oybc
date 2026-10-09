import Foundation
import GRDB

// MARK: - Task type switch (shared by Board Edit's commit and the global editor)
//
// The one place a Task's `type` may change after creation. Board Edit's Save
// (`BoardPlayViewModel.applyStagedOverrides`, on the row its Scope rule chose)
// and the global editor (`applyTaskEditPatch`, Task Detail + Tasks tab) both
// call `saveTypeSwitchedTask`. Retroactive on every board placing the row; old
// events stay but are inert for the new type. Web twin:
// `applyTaskTypeSwitchInTransaction` in `compoundStructureEdit.ts`.

extension AppDatabase {

    /// Whether any live task links to `taskId` as its counter root
    /// (`sharedCounterId == taskId`). A root with live copies keeps its type:
    /// the copies resolve from its increment events.
    static func hasLiveLinkedCopies(db: Database, taskId: String) throws -> Bool {
        try Task
            .filter(Column("sharedCounterId") == taskId && Column("isDeleted") == false)
            .fetchCount(db) > 0
    }

    /// Read-only twin of `hasLiveLinkedCopies(db:taskId:)` for a sheet's Done check.
    func hasLiveLinkedCopies(taskId: String) throws -> Bool {
        try read { try Self.hasLiveLinkedCopies(db: $0, taskId: taskId) }
    }

    /// Writes a TYPE-SWITCHED task: guards, then saves with one version bump,
    /// one enqueue and the cascade over every board placing it.
    ///
    /// - Into Compound: `structure` is required; link guard + validation, the
    ///   rule applied, sub-task CRUD via `applyStagedCompoundChildEdits`
    ///   (board-scoped when `scopeBoard` is set).
    /// - Simple ⇄ Counting: a Counting target needs a goal (and a unit unless
    ///   Duration); the lifetime caches are recomputed from the row's events
    ///   in the same write (a Simple row's completions count nothing for
    ///   Counting, and vice versa).
    ///
    /// Must run inside the caller's write transaction.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - original: The stored row (its type is the switch's `from`).
    ///   - switched: The row as the edit leaves it (`TaskTypeSwitch.converting`
    ///     plus the edited fields); its type differs from `original`'s.
    ///   - structure: The compound rule + sub-tasks (into Compound only).
    ///   - now: ISO8601 write stamp.
    ///   - scopeBoard: Board Edit's board (sub-task forks); nil = global.
    /// - Returns: The saved row.
    /// - Throws: `TaskEditError.invalid` for a refused switch; a database error.
    @discardableResult
    static func saveTypeSwitchedTask(
        db: Database, original: Task, switched: Task, structure: TaskEditPatch?,
        now: String, scopeBoard: Board? = nil
    ) throws -> Task {
        if original.sharedCounterId != nil {
            throw TaskEditError.invalid(message: TaskTypeSwitch.linkedCounterMessage)
        }
        guard TaskTypeSwitch.allows(from: original.type, to: switched.type) else {
            throw TaskEditError.invalid(message: "This task’s type can’t be changed.")
        }
        if original.type == .counting,
           try original.isCounter || hasLiveLinkedCopies(db: db, taskId: original.id) {
            throw TaskEditError.invalid(message: TaskTypeSwitch.sharedCounterMessage)
        }
        var task = switched
        if task.type == .compound {
            guard var titled = structure else {
                throw TaskEditError.invalid(message: "Add at least one sub-task.")
            }
            titled.title = task.title
            if let problem = try compoundLinkProblem(db: db, parentId: task.id, patch: titled) {
                throw TaskEditError.invalid(message: problem)
            }
            if let problem = titled.validate(type: .compound) {
                throw TaskEditError.invalid(message: problem)
            }
            task = titled.applied(to: task)
            if task.operatorType == nil { task.operatorType = .and }
            task.updatedAt = now
            task.version = original.version + 1
            try applyStagedCompoundChildEdits(db: db, parent: task, patch: titled, now: now, scopeBoard: scopeBoard)
            try saveTaskAndCascade(db: db, task: task)
            return task
        }
        if task.type == .counting {
            let needsUnit = countKindNeedsUnit(resolveCountKind(task.countKind))
            let goalOK = (task.maxCount ?? 0) > 0
            let unitOK = !needsUnit || !(task.unit ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            guard goalOK && unitOK else {
                throw TaskEditError.invalid(message: TaskTypeSwitch.countingNeedsGoalMessage)
            }
        }
        let events = try TaskEvent.filter(Column("taskId") == task.id).fetchAll(db)
        let caches = computeTaskCachesFromEvents(task: task, events: events)
        task.isCompleted = caches.isCompleted
        task.currentCount = caches.currentCount
        task.completedAt = caches.completedAt
        task.updatedAt = now
        task.version = original.version + 1
        try saveTaskAndCascade(db: db, task: task)
        return task
    }
}
