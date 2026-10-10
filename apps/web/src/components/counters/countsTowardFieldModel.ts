/**
 * countsTowardFieldModel.ts — the pure half of the "Counts toward" editor row
 * (docs/SHARED_COUNTER_SETTINGS.md §3d): what the row shows, which pick
 * needs the re-point confirm, and what a sheet submits.
 */

import { TaskType, countsTowardAmountOf, isSharedCounterRoot, taskSearchMatches, type Task } from '@oybc/shared';
import type { CountsTowardTarget } from '../../hooks/useCountsTowardTargets';

/** The row's selection: a counter root (or none) and the increment per completion. */
export interface CountsTowardSelection {
  counterId: string | null;
  amount: number;
}

/** What a sheet submits when the selection changed (absent = untouched). */
export interface CountsTowardSubmit {
  counterId: string | null;
  amount?: number;
}

/** The stored selection of `task` (amount 1 when absent). */
export function storedCountsToward(task: Pick<Task, 'countsTowardCounterId' | 'countsTowardAmount'>): CountsTowardSelection {
  return { counterId: task.countsTowardCounterId ?? null, amount: countsTowardAmountOf(task) };
}

/**
 * Whether the "Counts toward" row is shown for `task` at all: hidden for a
 * task that can never contribute — an Achievement, a linked counter row, or
 * a shared-counter root (a hub counter or one other rows link to).
 *
 * @param task - The edited task (its STORED shape).
 * @param tasks - Every task (for the root check).
 * @param selectedType - The type selected in the sheet (hidden while Achievement is picked).
 */
export function showsCountsTowardRow(task: Task, tasks: ReadonlyArray<Task>, selectedType: TaskType = task.type): boolean {
  if (selectedType === TaskType.ACHIEVEMENT || task.type === TaskType.ACHIEVEMENT) return false;
  if (task.sharedCounterId != null) return false;
  return !isSharedCounterRoot(task, tasks);
}

/**
 * The targets matching `query` (the shared counter search — name, noun, verb,
 * templates; blank matches all).
 */
export function filterCountsTowardTargets(targets: ReadonlyArray<CountsTowardTarget>, query: string): CountsTowardTarget[] {
  const q = query.trim();
  if (!q) return [...targets];
  return targets.filter((t) => taskSearchMatches(q, t.task));
}

/**
 * Whether picking `nextCounterId` re-points an already-counting task to a
 * DIFFERENT counter — the one pick that withdraws earlier credits (D11) and
 * so asks first. Picking "None" or the stored counter never asks.
 */
export function needsRepointConfirm(storedCounterId: string | null, nextCounterId: string | null): boolean {
  return storedCounterId != null && nextCounterId != null && nextCounterId !== storedCounterId;
}

/** The amount after a stepper tap, floored at 1. */
export function stepAmount(amount: number, delta: 1 | -1): number {
  return Math.max(1, amount + delta);
}

/**
 * What the sheet submits for the row: `undefined` when nothing changed,
 * else the new counter (or `null` to clear) and — when set — the amount.
 *
 * @param stored - {@link storedCountsToward} of the task as stored.
 * @param selection - The row's current selection.
 */
export function countsTowardSubmitFor(stored: CountsTowardSelection, selection: CountsTowardSelection): CountsTowardSubmit | undefined {
  if (selection.counterId == null) return stored.counterId == null ? undefined : { counterId: null };
  if (selection.counterId === stored.counterId && selection.amount === stored.amount) return undefined;
  return { counterId: selection.counterId, amount: selection.amount };
}
