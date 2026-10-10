import {
  COUNTER_GOAL_TIMEFRAMES,
  TaskType,
  Timeframe,
  countUnitSuffix,
  counterDisplayName,
  formatCount,
  placementGoalSource,
  renderCounterTitle,
  resolveCountKind,
  type Task,
} from '@oybc/shared';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';

/**
 * quickAddCounterPlacement.ts — the pure half of the quick-add / picker match
 * row for a shared counter (docs/SHARED_COUNTER_SETTINGS.md §2; design
 * handoff `PlaceFrame.dc.html`): which rows are counters, what the goal slot
 * says, and the pending LINKED task the no-default row builds. iOS twin:
 * `QuickAddCounterPlacement.swift`.
 */

/** The goal slot's text: a muted prefix (the board's timeframe, or `''`) + the ink value. */
export interface CounterMatchRowGoal {
  prefix: string;
  value: string;
}

/** The board timeframe label the goal slot prefixes a timeframe default with. */
const TIMEFRAME_PREFIX: Record<(typeof COUNTER_GOAL_TIMEFRAMES)[number], string> = {
  daily: 'Daily',
  weekly: 'Weekly',
  monthly: 'Monthly',
  yearly: 'Yearly',
};

/**
 * Is this library task a shared counter ROOT the match row treats specially:
 * a counting task with no `sharedCounterId` that is a hub counter or carries
 * timeframe defaults (a counting task other boards link to becomes one the
 * moment its defaults are set in the counter sheet).
 *
 * @param task - A library task.
 */
export function isSharedCounterRoot(task: Task): boolean {
  if (task.type !== TaskType.COUNTING || task.sharedCounterId) return false;
  return task.isCounter === true || Object.keys(task.timeframeGoals ?? {}).length > 0;
}

/**
 * The goal slot for placing `root` on a board of `timeframe`: "Weekly · " +
 * "2 books" when the goal is the board-timeframe default, just "12 books"
 * when it fell through to the root's own goal, null when nothing resolves
 * (the row offers a Goal entry instead).
 *
 * @param root - The counter root.
 * @param timeframe - The board's timeframe.
 * @returns The slot text, or null.
 */
export function counterMatchRowGoal(root: Task, timeframe: Timeframe): CounterMatchRowGoal | null {
  const src = placementGoalSource(root, { timeframe });
  if (!src) return null;
  const kind = resolveCountKind(root);
  const prefixLabel = TIMEFRAME_PREFIX[timeframe as keyof typeof TIMEFRAME_PREFIX];
  return {
    prefix: src.fromTimeframe && prefixLabel ? `${prefixLabel} · ` : '',
    value: `${formatCount(src.goal, kind)}${countUnitSuffix(kind, root.unit)}`,
  };
}

/**
 * The pending LINKED counting task the no-default match row builds from a
 * typed goal — the same shape as the special panel's deferred auto-link
 * create: linked to the root, the root's verb / noun / kind, the typed goal,
 * the title rendered through the root's templates, start-from-zero baseline,
 * wizard-born. Deliberately carries NO window fields: a linked row with a
 * `startDate` would read as a window-stamped derived copy. The planner (and
 * Board Edit's placement resolver) then mints the per-board copy at this goal
 * — a picked LINKED row keeps its own goal. Nothing is written to the root.
 *
 * @param root - The counter root.
 * @param goal - The typed goal (positive, at the root's kind).
 * @param userId - Owner of the new task.
 * @param id - The new task's id.
 * @param now - ISO8601 creation instant.
 * @returns The payload for `onPendingCreated`.
 */
export function buildPendingLinkedCounter(root: Task, goal: number, userId: string, id: string, now: string): PendingTaskPayload {
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
    createdInWizard: true,
  };
  return { task, childTasks: [], childLinks: [] };
}

/**
 * The counter name a match row shows for a root.
 *
 * @param root - The counter root.
 */
export function counterMatchRowName(root: Task): string {
  return counterDisplayName(root) || root.title || '(untitled task)';
}
