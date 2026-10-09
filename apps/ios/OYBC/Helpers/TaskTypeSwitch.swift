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
    /// for a Simple / Counting task that is not a linked counter (a compound,
    /// an achievement and a linked counter keep their type). A counter ROOT
    /// with live copies is refused at Done / Save (`sharedCounterMessage`).
    ///
    /// - Parameters:
    ///   - task: The task (any staged override merged).
    ///   - original: The task before any staged override (nil ⇒ `task`).
    static func showsPicker(task: Task, original: Task?) -> Bool {
        let t = (original ?? task).type
        return (t == .normal || t == .counting) && task.sharedCounterId == nil
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
