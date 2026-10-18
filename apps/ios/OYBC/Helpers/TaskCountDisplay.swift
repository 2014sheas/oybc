import Foundation

/// Counting-task display helpers for library surfaces (Swift twin of
/// `apps/web/src/pages/tasks/taskCountDisplay.ts`). Library rows carry no
/// progress (Task Detail redesign binding decision 2); the count a library
/// reader needs (in-progress / done) comes from `contextlessCounterState`
/// over the whole event log, never the propagation latch or `baseline`.
enum TaskCountDisplay {

    /// The count a library reader sees for a task: the context-less event
    /// count (`contextlessCounterState`) — a linked member reads its ROOT's
    /// lifetime events, a root or plain counter its own. Overshoot is kept.
    ///
    /// - Parameters:
    ///   - task: The task being read.
    ///   - eventsByTaskId: Non-deleted events grouped by `taskId`, or `nil`.
    /// - Returns: The count (0 for a non-counting task).
    static func displayedCount(for task: Task, eventsByTaskId: [String: [TaskEvent]]?) -> CountValue {
        contextlessCounterState(task: task, eventsByTaskId: eventsByTaskId).count
    }

    /// The library / pool / Tasks-row counting detail line — `"Run · goal 26.2 mi"`,
    /// Duration `"Practice · goal 10h 30m"` (no unit). The one shared builder for
    /// `RisoPoolListView`, `RisoTaskRowView` and `RisoLibrarySheetView`; web twin
    /// `buildPoolRowSubtitle`.
    ///
    /// - Parameter task: A counting task.
    /// - Returns: The line, or `nil` when action, goal or a needed unit is missing.
    static func goalSubtitle(for task: Task) -> String? {
        let kind = resolveCountKind(task.countKind)
        guard let action = task.action, !action.isEmpty, let max = task.maxCount,
              !countKindNeedsUnit(kind) || !(task.unit ?? "").isEmpty else { return nil }
        return "\(action) · goal \(formatCountWithUnit(max, kind: kind, unit: task.unit))"
    }

    /// The goal alone — `goal {value}` at the task's kind ("goal 5",
    /// "goal 1h 30m") — for rows whose title already carries the action and
    /// unit (the wizard / pool editor list). Nil without a positive goal.
    /// Web twin: `buildPoolRowSubtitle`'s counting case.
    static func goalOnlySubtitle(for task: Task) -> String? {
        guard let max = task.maxCount, max > 0 else { return nil }
        return "goal \(formatCount(max, kind: resolveCountKind(task.countKind)))"
    }

    /// The auto counting title from a task's own fields ("Run 26.2 miles"), or
    /// nil when action, goal or a needed unit is missing. Web twin:
    /// `counterRowTitle`.
    static func counterRowTitle(for task: Task) -> String? {
        let kind = resolveCountKind(task.countKind)
        let action = (task.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = (task.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, let max = task.maxCount else { return nil }
        if countKindNeedsUnit(kind) && unit.isEmpty { return nil }
        return TaskTitle.generateCounterTaskTitle(
            action: action, maxCount: max, unit: unit, countKind: kind,
            settings: CounterSettings.TitleSettings(task: task)
        )
    }

    /// The subtitle under a counting task's row: its auto title, or nil when
    /// that merely restates the row's own title. Web twin: `counterRowSubtitle`.
    static func counterRowSubtitle(for task: Task) -> String? {
        guard let derived = counterRowTitle(for: task) else { return nil }
        return derived.lowercased() == task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ? nil : derived
    }
}
