import {
  TaskType,
  Timeframe,
  counterDisplayName,
  renderCounterTitle,
  resolveCountKind,
  sharedCounterRootIds,
  type Task,
} from '@oybc/shared';
import { taskLookupValues, type TaskLookup } from '../counters/rowCounterTagName';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';

/**
 * quickAddCounterPlacement.ts — the pure half of the quick-add / picker match
 * row for a shared counter (docs/SHARED_COUNTER_SETTINGS.md §2; design
 * handoff `PlaceFrame.dc.html`): which rows are counters and the pending
 * LINKED task the no-default row builds. iOS twin:
 * `QuickAddCounterPlacement.swift`.
 */

/**
 * Is this library task a shared counter ROOT the match row treats specially:
 * a counting task with no `sharedCounterId` that is a hub counter, carries
 * timeframe defaults, or is linked to by another live task (`linkedRootIds`,
 * from {@link counterRootIdsIn}) — the same roots the Tasks tab shows as
 * counters, so every search surface returns the COUNTER for them.
 *
 * @param task - A library task.
 * @param linkedRootIds - Ids other live tasks link to (default: none).
 */
export function isSharedCounterRoot(task: Task, linkedRootIds: ReadonlySet<string> = NO_IDS): boolean {
  if (task.type !== TaskType.COUNTING || task.sharedCounterId) return false;
  return (
    task.isCounter === true ||
    Object.keys(task.timeframeGoals ?? {}).length > 0 ||
    linkedRootIds.has(task.id)
  );
}

const NO_IDS: ReadonlySet<string> = new Set();

/**
 * The counter roots in a surface's FULL task set (`sharedCounterRootIds`: a
 * hub counter, or a task another live task links to) — pass the unfiltered
 * set: the browse list drops the linked members that make a root.
 *
 * @param lookup - The surface's full task set (map or list).
 */
export function counterRootIdsIn(lookup: TaskLookup): Set<string> {
  return sharedCounterRootIds(taskLookupValues(lookup));
}

/** The host board's window, stamped on the pending linked row (as `useLinkedCounterCreate` does). */
export interface PendingLinkedWindow {
  timeframe?: Timeframe;
  startDate?: string;
  endDate?: string;
}

/**
 * The pending LINKED counting task the no-default match row builds from a
 * typed goal — the special panel's deferred auto-link shape
 * (`useLinkedCounterCreate`): linked to the root, the root's verb / noun /
 * kind, the typed goal, the title rendered through the root's templates,
 * start-from-zero baseline, wizard-born, and the host board's window fields
 * so that, wherever the row IS persisted (a draft; a repeating board's
 * member list), it expires with its window. On an active one-off save and in
 * Board Edit the planner / placement resolver mint the per-board copy at this
 * goal — a picked LINKED row keeps its own goal — and the persist seams then
 * never write this row (`dropReplacedLinkedPendingRows`). Nothing is written
 * to the root.
 *
 * @param root - The counter root.
 * @param goal - The typed goal (positive, at the root's kind).
 * @param userId - Owner of the new task.
 * @param id - The new task's id.
 * @param now - ISO8601 creation instant.
 * @param window - The host board's timeframe / dates, when it has them.
 * @returns The payload for `onPendingCreated`.
 */
export function buildPendingLinkedCounter(
  root: Task,
  goal: number,
  userId: string,
  id: string,
  now: string,
  window: PendingLinkedWindow = {},
): PendingTaskPayload {
  const kind = resolveCountKind(root);
  const task: Task = {
    id,
    userId,
    title: renderCounterTitle(root, goal),
    type: TaskType.COUNTING,
    action: root.action ?? '',
    unit: root.unit ?? '',
    maxCount: goal,
    ...(kind !== 'discrete' ? { countKind: kind } : {}),
    currentCount: 0,
    sharedCounterId: root.id,
    baseline: root.currentCount ?? 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...(window.timeframe !== undefined ? { timeframe: window.timeframe } : {}),
    ...(window.startDate !== undefined ? { startDate: window.startDate } : {}),
    ...(window.endDate !== undefined ? { endDate: window.endDate } : {}),
    createdInWizard: true,
  };
  return { task, childTasks: [], childLinks: [] };
}

/**
 * Is this pending payload a bare LINKED counting row (the match row's or the
 * special panel's auto-link create) — the only pending shape a mint replaces
 * with the per-board copy, so the persist seams must not write it once it is
 * not among the placed ids. Ordinary pending pool tasks are never dropped.
 *
 * @param payload - A pending payload.
 */
export function isLinkedPendingPayload(payload: PendingTaskPayload): boolean {
  return !!payload.task.sharedCounterId && payload.task.type === TaskType.COUNTING && payload.childTasks.length === 0;
}

/**
 * The counter name a match row shows for a root.
 *
 * @param root - The counter root.
 */
export function counterMatchRowName(root: Task): string {
  return counterDisplayName(root) || root.title || '(untitled task)';
}
