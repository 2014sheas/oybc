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
    /// - Parameter task: The task being rendered.
    /// - Returns: The displayed count (0 when the task has none).
    static func displayedCount(for task: Task) -> Int {
        guard let sharedCounterId = task.sharedCounterId, !sharedCounterId.isEmpty else {
            return task.currentCount ?? 0
        }
        return deriveDisplayedCount(
            derivedBaseline: task.baseline ?? 0,
            derivedMaxCount: task.maxCount ?? 0,
            sourceCurrentCount: task.currentCount ?? 0
        ).displayed
    }
}
