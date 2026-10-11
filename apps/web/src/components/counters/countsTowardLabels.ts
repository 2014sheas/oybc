import { formatCount, formatCountWithUnit, type ContributorRow, type Task } from '@oybc/shared';
import type { CountsTowardErrorCode } from '../../db/operations/countsToward';

/**
 * The inline validation line for a refused counts-toward assignment
 * (`countsTowardProblem` codes → short labels; docs/SHARED_COUNTER_SETTINGS.md
 * §3e). iOS twin: `CountsToward.Problem.label`.
 */
const LABELS: Record<Exclude<CountsTowardErrorCode, 'task-missing'>, string> = {
  self: 'Not itself.',
  'contributor-is-counter': "A counter can't count toward a counter.",
  'contributor-is-linked': "A linked counter can't count toward a counter.",
  'contributor-is-achievement': "An achievement can't count toward a counter.",
  'target-not-counter': 'Pick a shared counter.',
  'target-not-discrete': 'Pick a Discrete counter.',
  'invalid-amount': 'Amount must be a whole number, 1 or more.',
  cycle: 'That counter already feeds this task.',
  /** A zero-child compound may not stop counting (it would evaluate vacuously complete). */
  'compound-needs-child': 'A compound task needs a sub-task.',
};

/**
 * @param code - The refusal code.
 * @returns The validation-line text.
 */
export function countsTowardProblemLabel(code: Exclude<CountsTowardErrorCode, 'task-missing'>): string {
  return LABELS[code];
}

// ---------------------------------------------------------------------------
// Unit tasks — Counter Detail section labels (docs/SHARED_COUNTER_SETTINGS.md §3;
// unit-tasks handoff). iOS twin: `Helpers/CountsTowardLabels.swift`.
// ---------------------------------------------------------------------------

/** The section heading: "Unit tasks · N", or the bare "Unit tasks" when empty. */
export function unitTasksHeading(count: number): string {
  return count === 0 ? 'Unit tasks' : `Unit tasks · ${count}`;
}

/** The empty-section one-liner. */
export const UNIT_TASKS_EMPTY = 'No unit tasks yet.';

/** The tag's tooltip / accessible label. */
export function unitTagLabel(counterName: string): string {
  return `Unit task of ${counterName}`;
}

/** The accessible label of a row's trailing remove slot. */
export function removeSlotLabel(counterName: string): string {
  return `Remove from ${counterName}`;
}

/** The muted "× N" credit count — only a repeating unit task (N ≥ 2) shows one. */
export function creditCountText(row: Pick<ContributorRow, 'creditCount'>): string | null {
  return row.creditCount >= 2 ? `× ${row.creditCount}` : null;
}

/**
 * The progress text a row appends to its board line: a counting unit task
 * mid-progress reads "120 / 300 pages" (the task's real kind); a compound
 * with no sub-tasks reads "No subtasks yet", one mid-progress "1 of 2
 * subtasks". `null` for everything else (done / not started rows, simple tasks).
 *
 * @param row - The section row (pure half).
 * @param task - The row's representative task (its unit).
 */
export function rowProgressText(row: Pick<ContributorRow, 'status' | 'progress' | 'childProgress'>, task: Pick<Task, 'unit'>): string | null {
  if (row.childProgress) {
    if (row.childProgress.total === 0) return 'No subtasks yet';
    return row.status === 'inProgress' ? `${row.childProgress.done} of ${row.childProgress.total} subtasks` : null;
  }
  if (row.progress && row.status === 'inProgress') {
    const { current, goal, kind } = row.progress;
    return `${formatCount(current, kind)} / ${formatCountWithUnit(goal, kind, task.unit)}`;
  }
  return null;
}

/** Removing needs a confirm only when the lineage has credits to withdraw. */
export function removeNeedsConfirm(row: Pick<ContributorRow, 'creditCount'>): boolean {
  return row.creditCount >= 1;
}

/** The remove confirm's title. */
export function removeConfirmTitle(counterName: string): string {
  return `Remove from ${counterName}?`;
}

/** The remove confirm's body: the task stays, its credits are withdrawn. */
export function removeConfirmBody(taskTitle: string, credits: number, counterName: string): string {
  const withdrawn = credits === 1 ? `Its 1 credit on ${counterName} is withdrawn.` : `Its ${credits} credits on ${counterName} are withdrawn.`;
  return `'${taskTitle}' stays in your library. ${withdrawn}`;
}

/** The counter-delete confirm's consequence line; `null` at 0. */
export function unitTasksKeptNote(count: number): string | null {
  if (count <= 0) return null;
  return count === 1 ? 'Its 1 unit task is kept as an ordinary task.' : `Its ${count} unit tasks are kept as ordinary tasks.`;
}
