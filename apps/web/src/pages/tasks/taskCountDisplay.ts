import {
  TaskType,
  countUnitSuffix,
  deriveDisplayedCount,
  formatCount,
  resolveCountKind,
  type Task,
} from '@oybc/shared';

/**
 * taskCountDisplay.ts — how a Tasks-tab surface reads a counting task's
 * number (docs/BOARD_SOURCES.md §Member rules — *Where derived counters show
 * up*, RB7).
 *
 * A LINKED counting task (`sharedCounterId` set) does not own its count: its
 * `currentCount` column mirrors its ROOT's lifetime total (see
 * `propagateIncrement`), and what the user is owed is that total minus the
 * `baseline` its window opened at. The board surfaces have always derived
 * this (`db/adapters.ts`); the library surfaces printed the raw mirror, so a
 * member of a root at 12 whose window opened at 10 read "12 / 5" instead of
 * "2 / 5". Window-stamped derived counters made that visible on every
 * ordinary board, which is why it is fixed here rather than tolerated.
 */

/** The slice of a task these readers need. */
export type CountDisplayTask = Pick<
  Task,
  'type' | 'sharedCounterId' | 'baseline' | 'maxCount' | 'currentCount' | 'isCompleted' | 'countKind'
>;

/**
 * The count to SHOW for a task: baseline-adjusted for a linked member, raw
 * for a root or standalone counter.
 *
 * Low-end clamped, never high-end clamped — an overshoot past the goal is
 * real progress the user earned and must stay visible (`deriveDisplayedCount`
 * owns that rule; this is only the "which task is linked?" fork).
 *
 * Deliberately baseline maths, not the window-bounded event sum: this site
 * has no event map. A window-stamped derived member's board cell reads
 * `resolveLinkedCounterDisplay` (root increments within the row's window),
 * so the two can differ — but window-stamped members are hidden from the
 * Tasks list (`computeBrowsableTasks`), so the difference is reachable only
 * by navigating straight to such a member's Task Detail (accepted carve-out).
 *
 * @param task - The task being rendered.
 * @returns The displayed count (0 when the task has none).
 */
export function displayedCountFor(task: CountDisplayTask): number {
  if (task.sharedCounterId == null) return task.currentCount ?? 0;
  return deriveDisplayedCount(
    { baseline: task.baseline ?? 0, maxCount: task.maxCount ?? 0, countKind: task.countKind },
    { currentCount: task.currentCount ?? 0 },
  ).displayed;
}

/**
 * The Tasks-tab row's status fragment: "Completed", "3 / 10", or nothing.
 *
 * @param task - The task being rendered.
 * @returns The status text, or `''` when the row has nothing to say.
 */
export function computeStatusLabel(task: CountDisplayTask): string {
  if (task.isCompleted) return 'Completed';
  if (task.type === TaskType.COUNTING) {
    const current = displayedCountFor(task);
    const max = task.maxCount ?? 0;
    const kind = resolveCountKind(task);
    if (current > 0 && max > 0) return `${formatCount(current, kind)} / ${formatCount(max, kind)}`;
  }
  return '';
}

/**
 * Task Detail's counting line — `"Run · 2 / 5 km"`, Continuous
 * `"Hike · 3.1 / 26.2 mi"`, Duration `"Practice · 4h 30m / 10h 30m"` (no
 * unit). Built from the DISPLAYED count, formatted per the task's kind.
 * iOS twin: `TaskCountDisplay.countingSubtitle(for:)`.
 *
 * @param task - The counting task being rendered.
 * @returns The line.
 */
export function countingDetailLine(
  task: CountDisplayTask & Pick<Task, 'action' | 'unit'>,
): string {
  const kind = resolveCountKind(task);
  const current = formatCount(displayedCountFor(task), kind);
  const max = formatCount(task.maxCount ?? 0, kind);
  return `${task.action ?? ''} · ${current} / ${max}${countUnitSuffix(kind, task.unit)}`;
}
