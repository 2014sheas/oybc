import Foundation

/// How a Tasks-tab surface reads a counting task's number
/// (docs/BOARD_SOURCES.md §Member rules — *Where derived counters show up*,
/// RB7). Swift twin of `apps/web/src/pages/tasks/taskCountDisplay.ts`.
///
/// A LINKED counting task (`sharedCounterId` set) does not own its count: its
/// `currentCount` column mirrors its ROOT's lifetime total (see
/// `propagateIncrement`), and what the user is owed is that total minus the
/// `baseline` its window opened at. The board surfaces have always derived
/// this (`BoardPlayViewModel`); the library surfaces printed the raw mirror,
/// so a member of a root at 12 whose window opened at 10 read "12 / 5" instead
/// of "2 / 5". Window-stamped derived counters made that visible on every
/// ordinary board, which is why it is fixed here rather than tolerated.
enum TaskCountDisplay {

    /// The count to SHOW for a task: baseline-adjusted for a linked member,
    /// raw for a root or standalone counter.
    ///
    /// Low-end clamped, never high-end clamped — an overshoot past the goal is
    /// real progress the user earned and must stay visible
    /// (`deriveDisplayedCount` owns that rule; this is only the "which task is
    /// linked?" fork).
    ///
    /// Deliberately baseline maths, not the window-bounded event sum: this
    /// site has no event map. A window-stamped derived member's board cell
    /// reads `resolveLinkedCounterDisplay` (root increments within the row's
    /// window), so the two can differ — but window-stamped members are hidden
    /// from the Tasks list (`TaskLibraryViewModel.browsableTasks`), so the difference is
    /// reachable only by navigating straight to such a member's Task Detail
    /// (accepted carve-out).
    ///
    /// - Parameter task: The task being rendered.
    /// - Returns: The displayed count (0 when the task has none).
    static func displayedCount(for task: Task) -> CountValue {
        guard let sharedCounterId = task.sharedCounterId, !sharedCounterId.isEmpty else {
            return task.currentCount ?? 0
        }
        return deriveDisplayedCount(
            derivedBaseline: task.baseline ?? 0,
            derivedMaxCount: task.maxCount ?? 0,
            sourceCurrentCount: task.currentCount ?? 0,
            countKind: task.countKind
        ).displayed
    }

    /// Task detail's counting subtitle — `"Run · 2 / 5 km"` — built from the
    /// DISPLAYED count, not the raw mirror.
    ///
    /// Extracted out of `RisoTaskDetailContentView`'s private `typeSubtitle`
    /// so the read-audit fix it carries is actually pinned: inside a `View`'s
    /// computed property the whole suite stayed green when the string was
    /// reverted to `task.currentCount ?? 0` (every snapshot fixture has
    /// `sharedCounterId == nil`, so nothing observed it).
    ///
    /// Returns `nil` — "this row has no counting subtitle to show" — for
    /// anything missing an action or a needed unit. A counter with no goal of
    /// its own (a hub counter, browsable since 2026-10-12) shows its total
    /// alone. Web twin: `countingDetailLine`.
    ///
    /// - Parameter task: The task being rendered.
    /// - Returns: The subtitle, or `nil` when the task can't form one.
    static func countingSubtitle(for task: Task) -> String? {
        let kind = resolveCountKind(task.countKind)
        guard let action = task.action, task.unit != nil || kind == .duration else {
            return nil
        }
        // A counter with no goal of its own shows its total alone ("Do · 40 push-ups").
        let max = task.maxCount.flatMap { $0 > 0 ? " / \(formatCount($0, kind: kind))" : nil } ?? ""
        return "\(action) · \(formatCount(displayedCount(for: task), kind: kind))\(max)\(countUnitSuffix(kind, unit: task.unit))"
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
