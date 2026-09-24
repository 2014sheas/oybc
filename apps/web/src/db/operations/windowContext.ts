import { db } from '../internal';
import type { TaskEvent, WindowEvaluationContext } from '@oybc/shared';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Sync). Load every
 * non-deleted TaskEvent grouped by `taskId` so the derivation pass evaluates
 * each board against its own window (`computeBoardStatsUpdate` keys the window
 * on `board.startDate`). The map MUST stay workspace-wide (never scoped to the
 * placed tasks): a window-stamped derived counter resolves from its ROOT's
 * events, and the root is usually not placed on the board. Hub-linked derived
 * / compound / achievement squares are carved out INSIDE the shared kernel, so
 * passing the full event map is always safe.
 *
 * Build this BEFORE opening a Dexie `rw` transaction so `db.taskEvents` need
 * not be included in the transaction scope of the write path that consumes it.
 */
export async function buildWindowContext(): Promise<WindowEvaluationContext> {
  const events = await db.taskEvents.toArray();
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    if (e.isDeleted) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  return { eventsByTaskId };
}
