/**
 * countsToward.ts — "counts toward": any task as the unit of a Discrete
 * shared counter (docs/SHARED_COUNTER_SETTINGS.md §3, PR 3 — data + cascade).
 *
 * A contributing task carries `countsTowardCounterId` (+ optional
 * `countsTowardAmount`, default 1). When its derived LIFETIME state becomes
 * complete, the counter ROOT receives ONE increment event with the
 * deterministic id {@link countsTowardEventId}(contributor), stamped at the
 * completion instant; when it becomes incomplete again that event is
 * tombstoned. The write happens in the board cascade on both platforms (web
 * `db/operations/countsToward.ts` ↔ iOS `AppDatabase+CountsToward.swift`);
 * this module is the pure half:
 *
 *   - {@link countsTowardEventId} — the uuidv5 seam (same as the fork ids),
 *     so every device's re-derivation produces the same row and union-by-id
 *     sync stays correct.
 *   - {@link resolveContributionState} — lifetime completion + the instant it
 *     happened (§3c / D8: a late log's `min(now, endDate)` stamp is inherited
 *     because the instant IS the completing event's `occurredAt`).
 *   - {@link planCountsTowardAction} — compare the derived state to the
 *     stored event: insert / revise / tombstone / nothing (idempotent).
 *   - {@link countsTowardProblem} — the write-time cross-row validation.
 *
 * "Lifetime" because the event id is per contributing task: a task counts at
 * most once, whichever board (or the library) completed it (§3a). A
 * per-board variant (a fork) is its own task with its own event.
 *
 * Has a Swift twin (`Helpers/CountsToward.swift`) pinned by
 * `tests/fixtures/countsTowardVectors.json` (copied byte-identically to
 * `apps/ios/OYBCTests/Fixtures/`). A change here is a change in two places.
 */

import { OperatorType, TaskType } from '../constants/enums';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { isWithinTimeframe } from './calendarBoundaries';
import { quantizeCount, resolveCountKind } from './countValue';
import { isWindowStampedDerived } from './memberRules';
import { resolveTaskWindowState, resolveWindowStampedDerivedState } from './taskEvents';
import { uuidv5 } from './uuidv5';

/** uuidv5 name prefix for a contributing task's counts-toward increment. */
export const COUNTS_TOWARD_NAMESPACE = 'counts-toward:event';

/**
 * Deterministic id of the increment `contributingTaskId` writes on its
 * counter root.
 *
 * @param contributingTaskId - The task carrying `countsTowardCounterId`.
 * @returns A stable uuidv5 — every device derives the same id.
 */
export function countsTowardEventId(contributingTaskId: string): string {
  return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${contributingTaskId}`);
}

/**
 * The increment a contributor writes: its `countsTowardAmount`, or 1 when
 * absent / not a positive integer.
 *
 * @param task - The contributing task.
 * @returns A positive integer.
 */
export function countsTowardAmountOf(task: Pick<Task, 'countsTowardAmount'>): number {
  const a = task.countsTowardAmount;
  return a != null && Number.isInteger(a) && a > 0 ? a : 1;
}

/** A contributing task's lifetime completion and the instant it completed. */
export interface ContributionState {
  isCompleted: boolean;
  /** ISO instant the task became complete; `null` when incomplete. */
  completedAt: string | null;
}

const INCOMPLETE: ContributionState = { isCompleted: false, completedAt: null };

const toMs = (iso: string): number => new Date(iso).getTime();

/** Ascending by parsed instant, then by string (deterministic ties). */
function sortInstants(instants: string[]): string[] {
  return [...instants].sort((a, b) => toMs(a) - toMs(b) || (a < b ? -1 : a > b ? 1 : 0));
}

/**
 * The `occurredAt` of the increment that last carried the running sum from
 * below `target` to at-or-above it (events ordered by instant, then id), or
 * `null` when it never did.
 */
function crossingInstant(events: TaskEvent[], target: number): string | null {
  const live = events
    .filter((e) => !e.isDeleted && e.kind === 'increment')
    .sort((a, b) => toMs(a.occurredAt) - toMs(b.occurredAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  let sum = 0;
  let at: string | null = null;
  for (const e of live) {
    const prev = sum;
    sum = quantizeCount(sum + (e.delta ?? 0));
    if (prev < target && sum >= target) at = e.occurredAt;
    else if (sum < target) at = null;
  }
  return at;
}

/** A latched row (achievement, hub-linked copy): its cache + `completedAt`. */
function latchState(task: Task): ContributionState {
  return task.isCompleted ? { isCompleted: true, completedAt: task.completedAt ?? null } : INCOMPLETE;
}

function stateOf(
  task: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  eventsByTaskId: Record<string, TaskEvent[]>,
  visiting: Set<string>,
): ContributionState {
  if (task.isDeleted) return INCOMPLETE;

  if (task.type === TaskType.NORMAL) {
    const done = (eventsByTaskId[task.id] ?? []).filter((e) => !e.isDeleted && e.kind === 'completion');
    if (done.length === 0) return INCOMPLETE;
    return { isCompleted: true, completedAt: sortInstants(done.map((e) => e.occurredAt))[0] };
  }

  if (task.type === TaskType.COUNTING) {
    if (task.sharedCounterId) {
      if (!isWindowStampedDerived(task)) return latchState(task);
      const rootEvents = eventsByTaskId[task.sharedCounterId] ?? [];
      if (!resolveWindowStampedDerivedState(task, rootEvents).isCompleted) return INCOMPLETE;
      const inWindow = rootEvents.filter((e) =>
        isWithinTimeframe(e.occurredAt, task.startDate as string, task.endDate ?? null),
      );
      return { isCompleted: true, completedAt: crossingInstant(inWindow, task.maxCount ?? 0) };
    }
    const events = eventsByTaskId[task.id] ?? [];
    if (!resolveTaskWindowState(task, events, null, null).isCompleted) return INCOMPLETE;
    return { isCompleted: true, completedAt: crossingInstant(events, task.maxCount ?? 0) };
  }

  if (task.type !== TaskType.COMPOUND) return latchState(task);

  if (visiting.has(task.id)) return INCOMPLETE;
  visiting.add(task.id);
  const childStates = (childrenByCompound[task.id] ?? [])
    .filter((c) => !c.isDeleted)
    .map((link) => {
      const child = taskById[link.childTaskId];
      if (!child || child.isDeleted) return INCOMPLETE;
      return stateOf(child, childrenByCompound, taskById, eventsByTaskId, visiting);
    });
  visiting.delete(task.id);

  if (childStates.length === 0) {
    // Mirrors `evaluateCompound`: AND over nothing is vacuously true — except
    // an unfilled counts-toward container, which stays incomplete (§3a).
    const vacuous = task.operator === OperatorType.AND && task.countsTowardCounterId == null;
    return vacuous ? { isCompleted: true, completedAt: null } : INCOMPLETE;
  }
  const done = childStates.filter((s) => s.isCompleted);
  const instants = sortInstants(done.map((s) => s.completedAt).filter((x): x is string => x != null));
  const nth = (n: number): string | null =>
    instants.length === 0 ? null : instants[Math.min(n, instants.length) - 1];

  switch (task.operator) {
    case OperatorType.AND:
      return done.length === childStates.length ? { isCompleted: true, completedAt: nth(instants.length) } : INCOMPLETE;
    case OperatorType.OR:
      return done.length > 0 ? { isCompleted: true, completedAt: nth(1) } : INCOMPLETE;
    case OperatorType.M_OF_N: {
      const required = Math.max(1, task.threshold ?? 1);
      return done.length >= required ? { isCompleted: true, completedAt: nth(required) } : INCOMPLETE;
    }
    default:
      return INCOMPLETE;
  }
}

/**
 * A task's LIFETIME completion as "counts toward" reads it, and the instant
 * it became complete (docs/SHARED_COUNTER_SETTINGS.md §3b–§3c):
 *
 *   - NORMAL — complete iff a live completion event exists; the instant is
 *     the EARLIEST one's `occurredAt` (a late log's `endDate` stamp is
 *     inherited verbatim — D8).
 *   - Plain COUNTING — complete iff the lifetime sum reaches `maxCount`; the
 *     instant is the `occurredAt` of the increment that last crossed it.
 *   - Window-stamped linked COUNTING (a compound child) — the root's events
 *     inside its own window, same crossing rule. A hub-linked child reads its
 *     latch (`completedAt`), as `evaluateCompound`'s lifetime path does.
 *   - COMPOUND — the operator over its live children (same states
 *     `evaluateCompound` gives in a lifetime context); the instant is when
 *     the rule became satisfied: All of → the LAST child's instant (the max),
 *     Any of → the first, At least N → the N-th. A counts-toward container
 *     with no children is incomplete.
 *   - ACHIEVEMENT (as a compound child) — its latch.
 *
 * A complete task whose instant cannot be derived (a vacuous compound, a
 * latch without `completedAt`) falls back to the task's own `createdAt` — a
 * synced, immutable field, so devices still agree.
 *
 * @param task - The contributing task.
 * @param childrenByCompound - `compoundTaskId` → links (deleted ones ignored).
 * @param taskById - Every task by id.
 * @param eventsByTaskId - Events grouped by `taskId` (deleted ones ignored).
 * @returns `{ isCompleted, completedAt }`.
 */
export function resolveContributionState(
  task: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  eventsByTaskId: Record<string, TaskEvent[]>,
): ContributionState {
  const s = stateOf(task, childrenByCompound, taskById, eventsByTaskId, new Set());
  if (!s.isCompleted) return INCOMPLETE;
  return { isCompleted: true, completedAt: s.completedAt ?? task.createdAt };
}

/**
 * Whether `task` can receive counts-toward increments: a live, unlinked,
 * Discrete COUNTING row. (Root-ness — `isCounter` or linked copies — is a
 * write-time rule, {@link countsTowardProblem}; the cascade only needs a row
 * that can own increment events.)
 *
 * @param task - The candidate counter.
 */
export function isCountsTowardTarget(task: Task | undefined): task is Task {
  return (
    task != null &&
    !task.isDeleted &&
    task.type === TaskType.COUNTING &&
    task.sharedCounterId == null &&
    resolveCountKind(task) === 'discrete'
  );
}

/** One write the cascade makes for a contributing task. */
export type CountsTowardAction =
  | { kind: 'insert'; eventId: string; rootId: string; delta: number; occurredAt: string }
  | {
      /** Update a stored event in place (amount / instant / counter moved, or a revive). */
      kind: 'revise';
      eventId: string;
      rootId: string;
      delta: number;
      occurredAt: string;
      previousRootId: string;
      previousOccurredAt: string;
      wasDeleted: boolean;
    }
  | { kind: 'tombstone'; eventId: string; rootId: string; occurredAt: string };

/**
 * Decide the write a contributor needs: compare its derived state to the
 * stored event with id {@link countsTowardEventId}(contributor.id).
 *
 *   - Wanted (live, flagged, target valid, complete) + no event → `insert`.
 *   - Wanted + a tombstoned event → `revise` (revive).
 *   - Wanted + a live event that differs (counter, amount or instant) →
 *     `revise`; identical → `null` (replay is a no-op).
 *   - Not wanted + a live event → `tombstone`.
 *   - Counter deleted (or not pulled yet) → `null`: its events go with it
 *     (§3e) — no write either way.
 *
 * @param contributor - The task (flagged or not — an unflagged task with a
 *   stale live event is tombstoned).
 * @param taskById - Every task by id (resolves the counter roots).
 * @param state - {@link resolveContributionState} for `contributor`.
 * @param existing - The stored event with the deterministic id, if any (any state).
 * @returns The action, or `null` when nothing changes.
 */
export function planCountsTowardAction(
  contributor: Task,
  taskById: Record<string, Task>,
  state: ContributionState,
  existing: TaskEvent | undefined,
): CountsTowardAction | null {
  const eventId = countsTowardEventId(contributor.id);
  const targetId = contributor.countsTowardCounterId ?? null;
  const target = targetId != null ? taskById[targetId] : undefined;
  if (targetId != null && (!target || target.isDeleted)) return null;

  const wanted =
    !contributor.isDeleted && isCountsTowardTarget(target) && state.isCompleted && state.completedAt != null
      ? { rootId: target.id, delta: countsTowardAmountOf(contributor), occurredAt: state.completedAt }
      : null;

  if (existing && !existing.isDeleted) {
    if (!wanted) {
      const root = taskById[existing.taskId];
      if (!root || root.isDeleted) return null;
      return { kind: 'tombstone', eventId, rootId: existing.taskId, occurredAt: existing.occurredAt };
    }
    const same =
      existing.kind === 'increment' &&
      existing.taskId === wanted.rootId &&
      existing.delta === wanted.delta &&
      toMs(existing.occurredAt) === toMs(wanted.occurredAt);
    if (same) return null;
    return {
      kind: 'revise',
      eventId,
      ...wanted,
      previousRootId: existing.taskId,
      previousOccurredAt: existing.occurredAt,
      wasDeleted: false,
    };
  }
  if (!wanted) return null;
  if (existing) {
    return {
      kind: 'revise',
      eventId,
      ...wanted,
      previousRootId: existing.taskId,
      previousOccurredAt: existing.occurredAt,
      wasDeleted: true,
    };
  }
  return { kind: 'insert', eventId, ...wanted };
}

/** Why a counts-toward assignment is refused at write time. */
export type CountsTowardProblem =
  | 'self'
  | 'contributor-is-counter'
  | 'contributor-is-linked'
  | 'contributor-is-achievement'
  | 'target-not-counter'
  | 'target-not-discrete'
  | 'invalid-amount'
  | 'cycle';

/**
 * Whether `task` is a shared-counter ROOT: a hub counter, or a task other
 * live rows link to via `sharedCounterId`.
 *
 * @param task - The candidate.
 * @param tasks - Every task (any superset of the linked rows).
 */
export function isSharedCounterRoot(task: Task, tasks: ReadonlyArray<Task>): boolean {
  if (task.isCounter === true) return true;
  return tasks.some((t) => !t.isDeleted && t.sharedCounterId === task.id);
}

/**
 * Write-time validation for `task.countsTowardCounterId = targetId` (§3a, D7).
 * Refused when: the task points at itself; the task is a counter root or a
 * linked copy, or an Achievement; the target is not a live, unlinked
 * COUNTING root (hub counter or linked-to) or not Discrete; the amount is not
 * a positive integer; or the task's own subtree already feeds that counter (a
 * child that IS the counter or links to it — a self-sustaining loop).
 *
 * @param input.task - The contributing task as stored.
 * @param input.targetId - The counter it should count toward.
 * @param input.amount - The requested `countsTowardAmount` (absent = 1).
 * @param input.tasks - Every task.
 * @param input.children - Every compound link (deleted ones ignored).
 * @returns The first problem, or `null` when the assignment is allowed.
 */
export function countsTowardProblem(input: {
  task: Task;
  targetId: string;
  amount?: number;
  tasks: ReadonlyArray<Task>;
  children: ReadonlyArray<CompoundChild>;
}): CountsTowardProblem | null {
  const { task, targetId, amount, tasks, children } = input;
  if (targetId === task.id) return 'self';
  if (task.type === TaskType.ACHIEVEMENT) return 'contributor-is-achievement';
  if (task.sharedCounterId != null) return 'contributor-is-linked';
  if (isSharedCounterRoot(task, tasks)) return 'contributor-is-counter';
  const target = tasks.find((t) => t.id === targetId);
  if (!target || target.isDeleted || target.type !== TaskType.COUNTING || target.sharedCounterId != null || !isSharedCounterRoot(target, tasks)) {
    return 'target-not-counter';
  }
  if (resolveCountKind(target) !== 'discrete') return 'target-not-discrete';
  if (amount !== undefined && !(Number.isInteger(amount) && amount > 0)) return 'invalid-amount';

  const byId = new Map(tasks.map((t) => [t.id, t]));
  const seen = new Set<string>([task.id]);
  const stack = [task.id];
  while (stack.length > 0) {
    const parent = stack.pop() as string;
    for (const link of children) {
      if (link.isDeleted || link.compoundTaskId !== parent || seen.has(link.childTaskId)) continue;
      seen.add(link.childTaskId);
      const child = byId.get(link.childTaskId);
      if (child && (child.id === targetId || child.sharedCounterId === targetId)) return 'cycle';
      stack.push(link.childTaskId);
    }
  }
  return null;
}
