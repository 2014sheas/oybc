import Foundation

/// The one type-switch rule shared by every editor that edits a task row —
/// the Board Edit square sheet (`SquareEditTaskSheet`, committed by
/// `BoardPlayViewModel.applyStagedOverrides`) and the global editor
/// (`EditTaskSheet`, Task Detail + Tasks tab, saved by
/// `AppDatabase.applyTaskEditPatch`). The write side is
/// `AppDatabase.saveTypeSwitchedTask`. Web twin: `taskTypeRules.ts` +
/// `applyTaskTypeSwitchInTransaction` (`compoundStructureEdit.ts`).
enum TaskTypeSwitch {
    /// Refusal shown when an edit would change a linked counter's type
    /// (web `LINKED_COUNTER_TYPE_MESSAGE`).
    static let linkedCounterMessage = "A linked counter’s type can’t be changed here."
    /// Refusal shown when an edit would change a counter root's type while
    /// copies link to it (web `SHARED_COUNTER_TYPE_MESSAGE`).
    static let sharedCounterMessage = "A shared counter’s type can’t be changed here."
    /// Refusal for a Counting target without a goal / unit.
    static let countingNeedsGoalMessage = "A Counting task needs a goal and a unit."

    /// Whether a task may switch from `from` to `to`: Simple ⇄ Counting, and
    /// Simple / Counting → Compound. Never OUT of Compound (its sub-tasks'
    /// fate is undecided) and never into / out of Achievement (it carries its
    /// trigger + board/template target).
    static func allows(from: TaskType, to: TaskType) -> Bool {
        let switchable: Set<TaskType> = [.normal, .counting]
        guard switchable.contains(from) else { return false }
        return switchable.contains(to) || to == .compound
    }

    /// Whether an editor shows the Simple / Counting / Compound picker: only
    /// for a Simple / Counting task that is not a SHARED COUNTER — a linked
    /// copy, a hub counter (`isCounter`), or a counting task other rows link
    /// to (a board-born root, `hasLinkedCopies`) keeps its type (owner rule
    /// 2026-10-09), as do a compound and an achievement. The save still
    /// refuses a shared counter's switch (`sharedCounterMessage`) as the
    /// backstop. Web twin: `typeLockedForEdit` + `typeControlMode`.
    ///
    /// - Parameters:
    ///   - task: The task (any staged override merged).
    ///   - original: The task before any staged override (nil ⇒ `task`).
    ///   - hasLinkedCopies: Whether live rows link to it as their root
    ///     (`initialHasLinkedCopies`, read in the sheet's `init`). `nil` =
    ///     not known yet: a Counting task then shows its type FIXED, so the
    ///     picker never appears and then disappears.
    static func showsPicker(task: Task, original: Task?, hasLinkedCopies: Bool? = false) -> Bool {
        let base = original ?? task
        return (base.type == .normal || base.type == .counting)
            && task.sharedCounterId == nil && !base.isCounter
            && !(base.type == .counting && hasLinkedCopies != false)
    }

    /// The sheet's first-frame linked-copies answer: a cheap synchronous
    /// indexed read, only for a Counting task that is not already locked
    /// (linked copy / hub counter); false otherwise. A failed read reads as
    /// LOCKED (the save guard decides anyway).
    ///
    /// - Parameters:
    ///   - task: The stored (original) task.
    ///   - database: The database to read.
    static func initialHasLinkedCopies(task: Task, database: AppDatabase) -> Bool {
        guard task.type == .counting, task.sharedCounterId == nil, !task.isCounter else { return false }
        return (try? database.hasLiveLinkedCopies(taskId: task.id)) ?? true
    }

    /// `task` with its type set to `next` and the fields the new type cannot
    /// carry cleared: into Simple drops action / unit / goal / count; into
    /// Compound also drops the own latch (a compound derives from its
    /// sub-tasks). `countKind` is left to the caller (never cleared — sync
    /// merge-writes it). Pure; no-op when the type is unchanged.
    ///
    /// - Parameters:
    ///   - task: The stored (or staged) task.
    ///   - next: The target type.
    static func converting(_ task: Task, to next: TaskType) -> Task {
        guard next != task.type else { return task }
        var t = task
        t.type = next
        switch next {
        case .normal:
            t.action = nil
            t.unit = nil
            t.maxCount = nil
            t.currentCount = nil
        case .compound:
            t.action = nil
            t.unit = nil
            t.maxCount = nil
            t.currentCount = nil
            t.isCompleted = false
            t.completedAt = nil
        default:
            break
        }
        return t
    }
}
