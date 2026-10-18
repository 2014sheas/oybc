import { contextlessCounterState, type Task, type TaskEvent } from '@oybc/shared';

/**
 * taskCountDisplay.ts — how a Tasks-tab surface reads a counting task's
 * number (docs/TASK_WINDOW_REWORK.md slice 2c).
 *
 * A library surface has no board window, so a counting task reads its
 * lifetime: a LINKED row sums its ROOT's live increment events, a root or
 * plain counter its own (`contextlessCounterState`). The `baseline` column and
 * the `isCompleted` latch are never read here.
 */

/** The slice of a task these readers need. */
export type CountDisplayTask = Pick<
  Task,
  'id' | 'type' | 'sharedCounterId' | 'maxCount' | 'countKind'
>;

/**
 * The count to SHOW for a task, from the workspace event log.
 *
 * @param task          - The task being rendered.
 * @param eventsByTaskId - Every live `taskEvents` row grouped by `taskId`.
 * @returns The lifetime count (0 for a non-counting task or no events).
 */
export function displayedCountFor(
  task: CountDisplayTask,
  eventsByTaskId: Record<string, TaskEvent[]> | null | undefined,
): number {
  return contextlessCounterState(task, eventsByTaskId).count;
}
