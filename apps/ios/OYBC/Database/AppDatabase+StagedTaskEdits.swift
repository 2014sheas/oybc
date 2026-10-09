import Foundation
import GRDB

extension AppDatabase {

    /// Thrown by `applyStagedTaskEdits(... strict: true ...)` when a staged
    /// edit can no longer be applied (task gone, invalid patch, or an
    /// ineligible compound link). Throwing rolls the surrounding
    /// transaction back.
    struct StagedTaskEditError: LocalizedError, Equatable {
        let taskId: String
        let reason: String
        var errorDescription: String? { "Could not apply task edit: \(reason)" }
    }

    /// Applies staged inline task edits (`TaskEditPatch`) inside the CALLER's
    /// transaction. Factored out of `saveWizardBoard` /
    /// `writeWizardPendingTasksAndEnqueue` (which carried identical copies)
    /// so the board wizard and the pool editor share one apply path.
    ///
    /// Edits are GLOBAL (same Task everywhere), so each mutation goes through
    /// `saveTaskAndCascade` — save + sync enqueue + re-derive every other
    /// board / parent compound that shares the Task. Per-type handling:
    ///   - compound: parent fields + child/link CRUD
    ///     (`applyStagedCompoundChildEdits`), then save.
    ///   - simple/counting: `patch.applied(to:)` (a counting task's blank
    ///     title is derived there), then save. Ids in `skipSimpleIds` are
    ///     skipped (a pending simple/counting edit was pre-merged into its
    ///     payload by the wizard).
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - stagedEdits: Patches keyed by task id.
    ///   - skipSimpleIds: Simple/counting task ids to leave alone.
    ///   - strict: `false` (wizard) silently skips an edit that is missing /
    ///     invalid / ineligible; `true` (pool editor) throws
    ///     `StagedTaskEditError` instead so the whole save rolls back rather
    ///     than dropping the user's edit.
    ///   - now: ISO8601 timestamp for `updatedAt` and sync rows.
    ///   - scopeBoard: The board the one-off wizard is creating. Non-nil makes
    ///     every edit BOARD-SCOPED (docs/BOARD_SCOPED_TASK_EDITS.md): a task
    ///     placed on any other board is forked for this board first and the
    ///     edit lands on the fork; a task placed nowhere else — including one
    ///     created in this wizard session — is edited in place. nil (pool
    ///     editor, repeating-board pool) = global.
    /// - Returns: Original id → fork id for every forked task, so the caller
    ///   places the fork instead of the original.
    @discardableResult
    static func applyStagedTaskEdits(
        db: Database,
        stagedEdits: [String: TaskEditPatch],
        skipSimpleIds: Set<String> = [],
        strict: Bool = false,
        now: String,
        scopeBoard: Board? = nil
    ) throws -> [String: String] {
        var forks: [String: String] = [:]
        for stagedId in stagedEdits.keys.sorted() {
            guard let patch = stagedEdits[stagedId] else { continue }
            var taskId = stagedId
            guard var task = try Task.fetchOne(db, key: taskId) else {
                if strict { throw StagedTaskEditError(taskId: taskId, reason: "task no longer exists") }
                continue
            }
            // Defensive: never persist an invalid edit (the UI blocks Save,
            // but a stale draft shouldn't corrupt the row).
            if let problem = patch.validate(type: task.type) {
                if strict { throw StagedTaskEditError(taskId: taskId, reason: problem) }
                continue
            }
            if task.type != .compound && skipSimpleIds.contains(taskId) { continue }
            var scoped = BoardScopedTarget(targetId: taskId, forked: false)
            if let scopeBoard {
                scoped = try ensureBoardScopedTask(
                    db: db, taskId: taskId, board: scopeBoard, editedType: task.type, now: now
                )
                if scoped.forked, let fork = try Task.fetchOne(db, key: scoped.targetId) {
                    forks[stagedId] = fork.id
                    taskId = fork.id
                    task = fork
                }
            }
            if task.type == .compound {
                // An ineligible newly linked existing task skips the whole
                // edit (never half-applied), exactly like an invalid patch.
                if let problem = try Self.compoundLinkProblem(db: db, parentId: taskId, patch: patch) {
                    if strict { throw StagedTaskEditError(taskId: taskId, reason: problem) }
                    continue
                }
                task = patch.applied(to: task)
                task.version += 1
                task.updatedAt = now
                try Self.applyStagedCompoundChildEdits(db: db, parent: task, patch: patch, now: now, scopeBoard: scopeBoard)
                try Self.saveTaskAndCascade(db: db, task: task)
            } else {
                // The switch (rounding the root + its family) and the goal guard run first,
                // inside the caller's write; a refused goal throws and rolls the whole save back.
                if task.type == .counting,
                   try Self.applyKindSwitchThenGoalGuard(
                       db: db, taskId: taskId, to: patch.countKind,
                       maxCount: parseCountInput(patch.goal, kind: patch.countKind),
                       now: Self.parseISO8601(now) ?? Date()
                   ) {
                    task = try Task.fetchOne(db, key: taskId) ?? task
                }
                task = patch.applied(to: task)
                task.version += 1
                task.updatedAt = now
                try Self.saveTaskAndCascade(db: db, task: task)
            }
            try stampForkCaches(db: db, target: scoped, now: now)
        }
        return forks
    }
}
