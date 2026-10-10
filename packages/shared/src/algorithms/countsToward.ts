/**
 * countsToward.ts — "counts toward": any task as the unit of a Discrete
 * shared counter (docs/SHARED_COUNTER_SETTINGS.md §3, PR 3 — data + cascade).
 *
 * A contributing task carries `countsTowardCounterId` (+ optional
 * `countsTowardAmount`, default 1; `countsTowardSince`, the instant the flag
 * was set — D11). Its counter ROOT receives ONE increment event per
 * COMPLETION OCCURRENCE of the contributor (D10, ruled 2026-10-10: once per
 * occurrence, not once per task lifetime — a manual square on a repeating
 * weekly board is the SAME task every week, and counts every week it is
 * completed). Each occurrence has a stable key and a deterministic credit id
 * ({@link countsTowardEventId}); when an occurrence is no longer derived (an
 * undo, a removed placement, a cleared flag) its credit is tombstoned. The
 * write happens in the board cascade on both platforms (web
 * `db/operations/countsToward.ts` ↔ iOS `AppDatabase+CountsToward.swift`);
 * this module is the pure half:
 *
 *   - {@link countsTowardEventId} — the uuidv5 seam, so every device's
 *     re-derivation produces the same row and union-by-id sync stays correct.
 *   - {@link resolveContributionCredits} — the WANTED credits, from live data.
 *   - {@link isOccurrenceWanted} — the D11 "count from flag time" gate.
 *   - {@link candidateContributionIds} — every credit id the contributor may
 *     have owned (live AND tombstoned data), so a withdrawn occurrence is found
 *     and tombstoned.
 *   - {@link planCountsTowardActions} — the per-contributor set reconciliation:
 *     insert / revise / tombstone per credit id (idempotent), protecting the
 *     credits another member of the contributor's fork lineage still wants.
 *   - {@link isCreditWriteSealSuppressed} — the D11 "credits honour the
 *     counter's sealed windows" gate the writers apply per action.
 *   - {@link resolveContributionState} — one window's completion + instant
 *     (§3c / D8: a late log's `min(now, endDate)` stamp is inherited because
 *     the instant IS the completing event's `occurredAt`).
 *   - {@link countsTowardProblem} — the write-time cross-row validation.
 *
 * Occurrence keys per contributor type (§3a):
 *
 *   - NORMAL — one per live completion event; key = that event's id.
 *   - plain COUNTING — one per live placement window in which the windowed
 *     state is complete; key = the id of the increment that last crossed the
 *     goal inside that window (unplaced → the lifetime evaluation, same key).
 *   - COMPOUND — one per live placement window in which the windowed
 *     derivation is complete; key = the COMPLETING CHILD's event (the child
 *     event that set the instant — All of → the last child's, Any of → the
 *     first, At least N → the N-th; nested compounds pass theirs up), so
 *     overlapping boards and board date edits collapse to one credit. Only
 *     when the completing child is a latched row with no event: key =
 *     `board:<boardId>` (stable across date edits), or `lifetime` unplaced.
 *
 * An event key is globally unique, so the credit id for an event-keyed
 * occurrence does NOT include the contributor id: a board-scoped fork copies
 * the original's in-window events onto itself (`forkedEventId`) — a copy is
 * resolved back to its SOURCE event's id through the `forkedFromTaskId`
 * lineage ({@link ForkEventResolver}), so the original and its fork share one
 * credit instead of double-counting. Because several lineage members can want
 * the same credit, a member tombstones an event-keyed credit only when NO
 * live, flagged lineage member wants it ({@link planCountsTowardActions}'s
 * `lineageWantedIds`).
 *
 * Has a Swift twin (`Helpers/CountsToward.swift`) pinned by
 * `tests/fixtures/countsTowardVectors.json` (copied byte-identically to
 * `apps/ios/OYBCTests/Fixtures/`). A change here is a change in two places.
 */

import { BoardStatus, OperatorType, TaskType } from '../constants/enums';
import type { Board } from '../types/board';
import type { BoardTask } from '../types/boardTask';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { quantizeCount, resolveCountKind } from './countValue';
import { createForkEventResolver, isForkLineageLoaded, lineageRootId, type ForkEventResolver } from './countsTowardLineage';
import { isWindowStampedDerived } from './memberRules';
import {
  boardWindowEnd,
  boundWindowContextAtSeal,
  isEventSealImmune,
  resolveDerivedCounterWindowState,
  resolveTaskWindowState,
  resolveWindowStampedDerivedState,
  type CompoundWindowContext,
  type SealImmuneWindow,
} from './taskEvents';
import { uuidv5 } from './uuidv5';

/** uuidv5 name prefix for a contributing task's counts-toward increments. */
export const COUNTS_TOWARD_NAMESPACE = 'counts-toward:event';

/** One completion occurrence of a contributor — the key its credit is minted under. */
export type ContributionOccurrence =
  /** A NORMAL / plain COUNTING contributor's OWN completing event. */
  | { kind: 'event'; eventId: string }
  /** A COMPOUND contributor's completing CHILD event (scoped — several compounds may share a child). */
  | { kind: 'childEvent'; eventId: string }
  /** A placed compound whose completing child owns no event. */
  | { kind: 'board'; boardId: string }
  /** An unplaced compound whose completing child owns no event. */
  | { kind: 'lifetime' };

/**
 * Deterministic id of the credit a contributor writes on counter root
 * `rootId` for `occurrence`. Every name carries the TARGET root, so lineage
 * members share a credit only while they target the same counter (a re-point
 * is a tombstone on the old root + an insert on the new one, never a flip).
 * `contributorScopeId` is the contributor's fork-lineage ROOT
 * ({@link lineageRootId}) — a fork shares its original's scope, so the two
 * never mint distinct credits for one occurrence.
 *
 *   - `event`      → `uuidv5("counts-toward:event:<rootId>:<eventId>")` — an
 *                    own event belongs to exactly one task (a fork's copy
 *                    resolves to its source), so no scope is needed.
 *   - `childEvent` → `uuidv5("counts-toward:event:<rootId>:<scope>:child-event:<eventId>")`
 *                    — two compounds containing the same child each credit
 *                    their own completion of it.
 *   - `board`      → `uuidv5("counts-toward:event:<rootId>:<scope>:board:<boardId>")`.
 *   - `lifetime`   → `uuidv5("counts-toward:event:<rootId>:<scope>:lifetime")`.
 *
 * @param rootId - The counter root the credit is written on.
 * @param contributorScopeId - The contributor's lineage root id (its own id when it is not a fork).
 * @param occurrence - The occurrence key.
 * @returns A stable uuidv5 — every device derives the same id.
 */
export function countsTowardEventId(rootId: string, contributorScopeId: string, occurrence: ContributionOccurrence): string {
  switch (occurrence.kind) {
    case 'event':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${rootId}:${occurrence.eventId}`);
    case 'childEvent':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${rootId}:${contributorScopeId}:child-event:${occurrence.eventId}`);
    case 'board':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${rootId}:${contributorScopeId}:board:${occurrence.boardId}`);
    case 'lifetime':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${rootId}:${contributorScopeId}:lifetime`);
  }
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

/** A contributing task's completion (over one window) and the instant it completed. */
export interface ContributionState {
  isCompleted: boolean;
  /** ISO instant the task became complete; `null` when incomplete. */
  completedAt: string | null;
  /** The event that completed it (own crossing / first completion; a compound's completing child's). */
  completingEventId?: string;
  /** The task that owns `completingEventId` (a linked child's crossing belongs to its ROOT). */
  completingTaskId?: string;
}

const INCOMPLETE: ContributionState = { isCompleted: false, completedAt: null };

/** A window a contribution is evaluated over (`null` bounds = lifetime). */
export type ContributionWindow = Pick<CompoundWindowContext, 'windowStart' | 'windowEnd'>;

/** The lifetime window: no bounds. */
export const LIFETIME_WINDOW: ContributionWindow = { windowStart: null, windowEnd: null };

/** Epoch ms of an ISO instant (`NaN` when unparseable — the JS `Date` degrade). */
const toMs = (iso: string): number => new Date(iso).getTime();

const compareIds = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/**
 * Whether two ISO instants denote the same moment: parsed-ms equality, or the
 * raw strings when either does not parse (so an unparseable stamp never makes
 * a replay look like a change).
 */
function sameInstant(a: string, b: string): boolean {
  const ma = toMs(a);
  const mb = toMs(b);
  if (Number.isNaN(ma) || Number.isNaN(mb)) return a === b;
  return ma === mb;
}

/** Ascending by parsed instant, then by the tie-break keys (deterministic). */
function compareStates(a: ContributionState, b: ContributionState): number {
  const [ia, ib] = [a.completedAt ?? '', b.completedAt ?? ''];
  return (
    toMs(ia) - toMs(ib) ||
    compareIds(ia, ib) ||
    compareIds(a.completingEventId ?? '', b.completingEventId ?? '') ||
    compareIds(a.completingTaskId ?? '', b.completingTaskId ?? '')
  );
}

/** Live events of `events` whose `occurredAt` falls inside `[windowStart, windowEnd]` (inclusive; `null` = unbounded). */
function eventsInWindow(events: TaskEvent[], window: ContributionWindow): TaskEvent[] {
  const lower = window.windowStart == null ? null : toMs(window.windowStart);
  const upper = window.windowEnd == null ? null : toMs(window.windowEnd);
  return events.filter((e) => {
    if (e.isDeleted) return false;
    const t = toMs(e.occurredAt);
    if (lower !== null && !(t >= lower)) return false;
    if (upper !== null && !(t <= upper)) return false;
    return true;
  });
}

/**
 * The increment that last carried the running sum from below `target` to
 * at-or-above it (events ordered by instant, then id), or `null` when it
 * never did.
 */
function crossingEvent(events: TaskEvent[], target: number): TaskEvent | null {
  const live = events
    .filter((e) => !e.isDeleted && e.kind === 'increment')
    .sort((a, b) => toMs(a.occurredAt) - toMs(b.occurredAt) || compareIds(a.id, b.id));
  let sum = 0;
  let at: TaskEvent | null = null;
  for (const e of live) {
    const prev = sum;
    sum = quantizeCount(sum + (e.delta ?? 0));
    if (prev < target && sum >= target) at = e;
    else if (sum < target) at = null;
  }
  return at;
}

/** A completed state stamped at `event` (or incomplete when there is none). */
function completedBy(event: TaskEvent | null): ContributionState {
  return event
    ? { isCompleted: true, completedAt: event.occurredAt, completingEventId: event.id, completingTaskId: event.taskId }
    : INCOMPLETE;
}

/** A latched row (achievement, hub-linked copy in a lifetime window): its cache + `completedAt`. */
function latchState(task: Task): ContributionState {
  return task.isCompleted ? { isCompleted: true, completedAt: task.completedAt ?? null } : INCOMPLETE;
}

function stateOf(
  task: Task,
  ctx: CompoundWindowContext,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  visiting: Set<string>,
): ContributionState {
  if (task.isDeleted) return INCOMPLETE;

  if (task.type === TaskType.NORMAL) {
    const events = ctx.eventsByTaskId[task.id] ?? [];
    if (!resolveTaskWindowState(task, events, ctx.windowStart, ctx.windowEnd).isCompleted) return INCOMPLETE;
    const done = eventsInWindow(events, ctx)
      .filter((e) => e.kind === 'completion')
      .sort((a, b) => toMs(a.occurredAt) - toMs(b.occurredAt) || compareIds(a.id, b.id));
    return completedBy(done[0] ?? null);
  }

  if (task.type === TaskType.COUNTING) {
    if (task.sharedCounterId) {
      const rootEvents = ctx.eventsByTaskId[task.sharedCounterId] ?? [];
      if (isWindowStampedDerived(task)) {
        if (!resolveWindowStampedDerivedState(task, rootEvents).isCompleted) return INCOMPLETE;
        const own = { windowStart: task.startDate as string, windowEnd: task.endDate ?? null };
        return completedBy(crossingEvent(eventsInWindow(rootEvents, own), task.maxCount ?? 0));
      }
      // Owner rule 2026-10-01: any other linked row on a board resolves over
      // the HOST window; only a lifetime reader still reads its latch.
      const derived = resolveDerivedCounterWindowState(task, ctx.eventsByTaskId, ctx);
      if (!derived) return latchState(task);
      if (!derived.isCompleted) return INCOMPLETE;
      return completedBy(crossingEvent(eventsInWindow(rootEvents, ctx), task.maxCount ?? 0));
    }
    const events = ctx.eventsByTaskId[task.id] ?? [];
    if (!resolveTaskWindowState(task, events, ctx.windowStart, ctx.windowEnd).isCompleted) return INCOMPLETE;
    return completedBy(crossingEvent(eventsInWindow(events, ctx), task.maxCount ?? 0));
  }

  if (task.type !== TaskType.COMPOUND) return latchState(task);

  if (visiting.has(task.id)) return INCOMPLETE;
  visiting.add(task.id);
  const childStates = (childrenByCompound[task.id] ?? [])
    .filter((c) => !c.isDeleted)
    .map((link) => {
      const child = taskById[link.childTaskId];
      if (!child || child.isDeleted) return INCOMPLETE;
      return stateOf(child, ctx, childrenByCompound, taskById, visiting);
    });
  visiting.delete(task.id);

  if (childStates.length === 0) {
    // Mirrors `evaluateCompound`: AND over nothing is vacuously true — except
    // an unfilled counts-toward container, which stays incomplete (§3a).
    const vacuous = task.operator === OperatorType.AND && task.countsTowardCounterId == null;
    return vacuous ? { isCompleted: true, completedAt: null } : INCOMPLETE;
  }
  const done = childStates.filter((s) => s.isCompleted).sort(compareStates);
  const nth = (n: number): ContributionState => {
    const { isCompleted: _done, ...rest } = done[Math.min(n, done.length) - 1];
    return { isCompleted: true, ...rest };
  };

  switch (task.operator) {
    case OperatorType.AND:
      return done.length === childStates.length ? nth(done.length) : INCOMPLETE;
    case OperatorType.OR:
      return done.length > 0 ? nth(1) : INCOMPLETE;
    case OperatorType.M_OF_N: {
      const required = Math.max(1, task.threshold ?? 1);
      return done.length >= required ? nth(required) : INCOMPLETE;
    }
    default:
      return INCOMPLETE;
  }
}

/**
 * A task's completion as "counts toward" reads it over one window, and the
 * instant it became complete (docs/SHARED_COUNTER_SETTINGS.md §3b–§3c). The
 * default window is lifetime (no bounds); a board window is
 * `[startDate, endDate]` inclusive, the kernel's convention
 * (`resolveTaskWindowState` / `resolveDerivedCounterWindowState`):
 *
 *   - NORMAL — complete iff a live completion event falls in the window; the
 *     instant is the EARLIEST one's `occurredAt` (a late log's `endDate` stamp
 *     is inherited verbatim — D8); `completingEventId` names it.
 *   - Plain COUNTING — complete iff the in-window sum reaches `maxCount`; the
 *     instant is the `occurredAt` of the increment that last crossed it
 *     (`completingEventId`). A goal of 0 is degenerate: complete, but no
 *     increment ever crosses it, so no event names the occurrence.
 *   - Window-stamped linked COUNTING (a compound child) — the root's events
 *     inside its own window, same crossing rule (`completingTaskId` = the
 *     root). Any other linked child resolves over the HOST window (owner rule
 *     2026-10-01); only a lifetime window reads its latch (`completedAt`), as
 *     `evaluateCompound` does.
 *   - COMPOUND — the operator over its live children (the same states
 *     `evaluateCompound` gives in that window); the instant is when the rule
 *     became satisfied: All of → the LAST child's (the max), Any of → the
 *     first, At least N → the N-th — and that child's `completingEventId` /
 *     `completingTaskId` pass up (a nested compound passes its own). A
 *     counts-toward container with no children is incomplete.
 *   - ACHIEVEMENT (as a compound child) — its latch.
 *
 * A complete task whose instant cannot be derived (a vacuous compound, a
 * latch without `completedAt`) falls back to the task's own `createdAt` — a
 * synced, immutable field, so devices still agree.
 *
 * @param task - The contributing task.
 * @param childrenByCompound - `compoundTaskId` → links (deleted ones ignored).
 * @param taskById - Every task by id.
 * @param eventsByTaskId - Events grouped by `taskId` (deleted ones ignored;
 *   a sealed board's caller bounds them at `sealedAt` first).
 * @param window - The window to evaluate over (default: lifetime).
 * @returns `{ isCompleted, completedAt, completingEventId?, completingTaskId? }`.
 */
export function resolveContributionState(
  task: Task,
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  eventsByTaskId: Record<string, TaskEvent[]>,
  window: ContributionWindow = LIFETIME_WINDOW,
): ContributionState {
  const ctx: CompoundWindowContext = { windowStart: window.windowStart, windowEnd: window.windowEnd, eventsByTaskId };
  const s = stateOf(task, ctx, childrenByCompound, taskById, new Set());
  if (!s.isCompleted) return INCOMPLETE;
  return {
    isCompleted: true,
    completedAt: s.completedAt ?? task.createdAt,
    ...(s.completingEventId ? { completingEventId: s.completingEventId } : {}),
    ...(s.completingTaskId ? { completingTaskId: s.completingTaskId } : {}),
  };
}

// ---------------------------------------------------------------------------
// Credits
// ---------------------------------------------------------------------------

/** The data a contributor's credits are derived from. */
export interface ContributionInputs {
  /** Every task by id (resolves the counter root, compound children, fork lineage). */
  taskById: Record<string, Task>;
  /** `compoundTaskId` → LIVE links (deleted ones ignored). */
  childrenByCompound: Record<string, CompoundChild[]>;
  /** `compoundTaskId` → links in ANY state (the candidate subtree); defaults to `childrenByCompound`. */
  allChildrenByCompound?: Record<string, CompoundChild[]>;
  /** Non-deleted events grouped by `taskId` (the kernel convention). */
  eventsByTaskId: Record<string, TaskEvent[]>;
  /**
   * EVERY event (tombstones included) by `taskId` — the contributor's, its
   * fork ancestors', and (for a compound) its subtree's and their roots'.
   */
  allEventsByTaskId: Record<string, TaskEvent[]>;
  /** The contributor's placements, any state (rows for other tasks are ignored). */
  placements: ReadonlyArray<Pick<BoardTask, 'boardId' | 'taskId' | 'isDeleted'>>;
  /** Boards referenced by `placements`, any state. A board absent here is treated as not live. */
  boardById: Record<string, Pick<Board, 'id' | 'isDeleted' | 'status' | 'startDate' | 'endDate' | 'sealedAt'>>;
  /** A shared {@link ForkEventResolver}; one is created over the inputs when absent. */
  forkEvents?: ForkEventResolver;
}

/** One credit a contributor wants on its counter root. */
export interface ContributionCredit {
  /** The credit's deterministic id ({@link countsTowardEventId}). */
  eventId: string;
  /** The counter root the credit is written on. */
  rootId: string;
  occurrence: ContributionOccurrence;
  /** The completion instant the credit is stamped at. */
  occurredAt: string;
}

const resolverOf = (inputs: ContributionInputs): ForkEventResolver =>
  inputs.forkEvents ?? createForkEventResolver(inputs.taskById, inputs.allEventsByTaskId);

/** The event-keyed occurrence for `eventId` owned by `taskId`, resolved through the fork lineage. */
function eventOccurrence(eventId: string, taskId: string, inputs: ContributionInputs, resolver: ForkEventResolver): ContributionOccurrence {
  const owner = inputs.taskById[taskId];
  return { kind: 'event', eventId: owner ? resolver.resolve(eventId, owner) : eventId };
}

/** The live boards placing `task`, each as the window its square is evaluated over (sealed → bounded at `sealedAt`). */
function liveWindowsOf(task: Task, inputs: ContributionInputs): Array<{ boardId: string; ctx: CompoundWindowContext }> {
  const seen = new Set<string>();
  const out: Array<{ boardId: string; startDate: string; ctx: CompoundWindowContext }> = [];
  for (const p of inputs.placements) {
    if (p.isDeleted || p.taskId !== task.id || seen.has(p.boardId)) continue;
    seen.add(p.boardId);
    const b = inputs.boardById[p.boardId];
    if (!b || b.isDeleted || b.status === BoardStatus.DRAFT) continue;
    const sealedAtMs = b.sealedAt != null ? toMs(b.sealedAt) : NaN;
    const eventsByTaskId = Number.isNaN(sealedAtMs)
      ? inputs.eventsByTaskId
      : boundWindowContextAtSeal(inputs.eventsByTaskId, sealedAtMs).eventsByTaskId;
    out.push({ boardId: b.id, startDate: b.startDate, ctx: { windowStart: b.startDate, windowEnd: boardWindowEnd(b), eventsByTaskId } });
  }
  return out.sort((a, b) => toMs(a.startDate) - toMs(b.startDate) || compareIds(a.boardId, b.boardId));
}

/**
 * The credits `task` WANTS on its counter root, from live data (§3a):
 *
 *   - NORMAL — one per live completion event, keyed by that event (resolved
 *     through the fork lineage), stamped at its `occurredAt`.
 *   - plain COUNTING — one per live placement window (board not deleted, not
 *     a draft; a sealed board bounded at `sealedAt`, an ended one at its
 *     `endDate`) whose windowed state is complete, keyed by the crossing
 *     increment; placed nowhere → the lifetime evaluation, same key. The
 *     same crossing event in two overlapping windows is ONE credit.
 *   - COMPOUND — one per live placement window whose windowed derivation is
 *     complete, keyed by the completing child's (fork-resolved) event; when
 *     that child owns no event, `board:<boardId>`; placed nowhere → the
 *     lifetime evaluation, keyed by the completing event or `lifetime`.
 *   - A linked row, an achievement, a counter root or a deleted task — none.
 *   - A fork whose `forkedFromTaskId` chain is not fully loaded — none (its
 *     keys depend on the lineage root, so it waits for the lineage to arrive;
 *     {@link isForkLineageLoaded}).
 *
 * Keys are minted on `rootId` (default: the task's own target). Does NOT
 * consult the flag's validity or `countsTowardSince`:
 * {@link planCountsTowardActions} applies those.
 *
 * @param task - The contributor.
 * @param inputs - See {@link ContributionInputs}.
 * @param rootId - The counter root to key the credits on (default: `task.countsTowardCounterId`).
 * @returns The wanted credits, deduplicated by id, in a deterministic order; `[]` with no root.
 */
export function resolveContributionCredits(
  task: Task,
  inputs: ContributionInputs,
  rootId: string | null = task.countsTowardCounterId ?? null,
): ContributionCredit[] {
  if (rootId == null || task.isDeleted || task.isCounter === true) return [];
  if (!isForkLineageLoaded(task, inputs.taskById)) return [];
  const resolver = resolverOf(inputs);
  const scope = lineageRootId(task, inputs.taskById);
  const byId = new Map<string, ContributionCredit>();
  const want = (occurrence: ContributionOccurrence, occurredAt: string): void => {
    const eventId = countsTowardEventId(rootId, scope, occurrence);
    const prior = byId.get(eventId);
    if (!prior || toMs(occurredAt) < toMs(prior.occurredAt)) byId.set(eventId, { eventId, rootId, occurrence, occurredAt });
  };
  const evaluate = (ctx: CompoundWindowContext): ContributionState =>
    resolveContributionState(task, inputs.childrenByCompound, inputs.taskById, ctx.eventsByTaskId, ctx);
  const lifetimeCtx: CompoundWindowContext = { ...LIFETIME_WINDOW, eventsByTaskId: inputs.eventsByTaskId };

  if (task.type === TaskType.NORMAL) {
    for (const e of inputs.eventsByTaskId[task.id] ?? []) {
      if (!e.isDeleted && e.kind === 'completion') want(eventOccurrence(e.id, task.id, inputs, resolver), e.occurredAt);
    }
  } else if (task.type === TaskType.COUNTING) {
    if (task.sharedCounterId) return [];
    const windows = liveWindowsOf(task, inputs);
    for (const ctx of windows.length > 0 ? windows.map((w) => w.ctx) : [lifetimeCtx]) {
      const s = evaluate(ctx);
      if (s.isCompleted && s.completingEventId) {
        want(eventOccurrence(s.completingEventId, s.completingTaskId ?? task.id, inputs, resolver), s.completedAt as string);
      }
    }
  } else if (task.type === TaskType.COMPOUND) {
    const childEvent = (s: ContributionState): ContributionOccurrence | null => {
      if (!s.completingEventId) return null;
      const resolved = eventOccurrence(s.completingEventId, s.completingTaskId ?? task.id, inputs, resolver);
      return resolved.kind === 'event' ? { kind: 'childEvent', eventId: resolved.eventId } : resolved;
    };
    const windows = liveWindowsOf(task, inputs);
    if (windows.length === 0) {
      const s = evaluate(lifetimeCtx);
      if (s.isCompleted) want(childEvent(s) ?? { kind: 'lifetime' }, s.completedAt as string);
    }
    for (const w of windows) {
      const s = evaluate(w.ctx);
      if (s.isCompleted) want(childEvent(s) ?? { kind: 'board', boardId: w.boardId }, s.completedAt as string);
    }
  }
  return [...byId.values()].sort((a, b) => compareIds(a.eventId, b.eventId));
}

/**
 * D11 (ruled 2026-10-10) — "count from now on": an occurrence credits only
 * when its instant (the credit's `occurredAt`) is at or after the
 * contributor's `countsTowardSince` (the instant the flag was set or
 * re-pointed). A contributor with no `since` (a legacy row) credits every
 * occurrence. An unparseable `since` applies no bound; an unparseable
 * instant is never wanted. The single place the "wanted" policy lives — the
 * planner and the lineage union both go through it.
 *
 * @param contributor - The task (its `countsTowardSince` is read).
 * @param credit - The occurrence under consideration.
 */
export function isOccurrenceWanted(contributor: Pick<Task, 'countsTowardSince'>, credit: Pick<ContributionCredit, 'occurredAt'>): boolean {
  const since = contributor.countsTowardSince;
  if (since == null) return true;
  const sinceMs = toMs(since);
  if (Number.isNaN(sinceMs)) return true;
  const at = toMs(credit.occurredAt);
  return !Number.isNaN(at) && at >= sinceMs;
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

/**
 * Whether `task` can hold or want a credit at all: not a counter root, not a
 * linked copy, not an Achievement (none may carry the flag — Zod shape rule).
 * The writers skip such rows before any candidate work.
 *
 * @param task - The candidate contributor.
 */
export function canContribute(task: Pick<Task, 'type' | 'isCounter' | 'sharedCounterId'>): boolean {
  return task.isCounter !== true && task.sharedCounterId == null && task.type !== TaskType.ACHIEVEMENT;
}

/**
 * The credit ids the planner would KEEP for `contributor` — its wanted
 * credits gated by the flag, the target and {@link isOccurrenceWanted} — the
 * same gate {@link planCountsTowardActions} applies, exposed so a lineage
 * member's wants can be unioned ({@link planCountsTowardActions}'
 * `lineageWantedIds`).
 *
 * @param contributor - The lineage member.
 * @param inputs - Its {@link ContributionInputs} (own placements).
 * @returns The credit ids, or `[]` when it can credit nothing.
 */
export function keptCreditIdsFor(contributor: Task, inputs: ContributionInputs): string[] {
  const targetId = contributor.countsTowardCounterId ?? null;
  const target = targetId != null ? inputs.taskById[targetId] : undefined;
  if (contributor.isDeleted || !canContribute(contributor) || !isCountsTowardTarget(target)) return [];
  return resolveContributionCredits(contributor, inputs)
    .filter((c) => isOccurrenceWanted(contributor, c))
    .map((c) => c.eventId);
}

/** The task ids a compound's candidate keys reach: its subtree (links in any state) and the roots its linked children read. */
function candidateSubtreeIds(task: Task, inputs: ContributionInputs): string[] {
  const links = inputs.allChildrenByCompound ?? inputs.childrenByCompound;
  const seen = new Set<string>([task.id]);
  const out = new Set<string>();
  const stack = [task.id];
  while (stack.length > 0) {
    const parent = stack.pop() as string;
    for (const link of links[parent] ?? []) {
      const childId = link.childTaskId;
      if (seen.has(childId)) continue;
      seen.add(childId);
      out.add(childId);
      const child = inputs.taskById[childId];
      if (!child) continue;
      if (child.sharedCounterId) out.add(child.sharedCounterId);
      if (child.type === TaskType.COMPOUND) stack.push(childId);
    }
  }
  return [...out];
}

/**
 * Every credit id `task` MAY own on any of `rootIds` — a superset of
 * {@link resolveContributionCredits} built from live AND tombstoned data:
 * every event of the task (raw id, and its fork-resolved id when that
 * differs), for a compound every event of its subtree and of the roots its
 * linked children read (raw + resolved, links in any state), one `board` key
 * per placement (any state, boards any state), and the `lifetime` key — each
 * minted on every root in `rootIds`. A stored credit at any of these ids that
 * is no longer wanted is tombstoned.
 *
 * `rootIds` is what the writer can derive: the task's current target, the
 * current targets of its loaded lineage members, and a previous target the
 * write path knows (a re-point / clear, a pulled row that was flagged). A
 * previous root nobody remembers (an interrupted re-point) is reconciled by
 * the next cascade that learns it.
 *
 * @param task - The contributor (flagged or not).
 * @param inputs - See {@link ContributionInputs}.
 * @param rootIds - The counter roots to enumerate keys on.
 * @returns Sorted, deduplicated credit ids.
 */
export function candidateContributionIds(task: Task, inputs: ContributionInputs, rootIds: ReadonlyArray<string>): string[] {
  const roots = [...new Set(rootIds)];
  if (roots.length === 0) return [];
  const resolver = resolverOf(inputs);
  const scope = lineageRootId(task, inputs.taskById);
  const occurrences: ContributionOccurrence[] = [{ kind: 'lifetime' }];
  const addEventsOf = (ownerId: string, kind: 'event' | 'childEvent'): void => {
    const owner = inputs.taskById[ownerId];
    for (const e of inputs.allEventsByTaskId[ownerId] ?? []) {
      occurrences.push({ kind, eventId: e.id });
      const canonical = owner ? resolver.resolve(e.id, owner) : e.id;
      if (canonical !== e.id) occurrences.push({ kind, eventId: canonical });
    }
  };
  addEventsOf(task.id, 'event');
  if (task.type === TaskType.COMPOUND) for (const id of candidateSubtreeIds(task, inputs)) addEventsOf(id, 'childEvent');
  for (const p of inputs.placements) if (p.taskId === task.id) occurrences.push({ kind: 'board', boardId: p.boardId });
  const ids = new Set<string>();
  for (const rootId of roots) for (const o of occurrences) ids.add(countsTowardEventId(rootId, scope, o));
  return [...ids].sort(compareIds);
}

/**
 * The amount a lineage writes on `rootId` — one deterministic rule when
 * members disagree: the lineage root's (top ancestor's) amount when it is a
 * live, flagged member targeting `rootId`, else the amount of the member
 * with the smallest id among those. `1` when none qualifies.
 *
 * @param rootId - The counter root.
 * @param members - The contributor and every loaded lineage member.
 * @param lineageRootTaskId - {@link lineageRootId} of the lineage.
 */
export function lineageCreditDelta(rootId: string, members: ReadonlyArray<Task>, lineageRootTaskId: string): number {
  const targeting = members
    .filter((m) => !m.isDeleted && canContribute(m) && m.countsTowardCounterId === rootId)
    .sort((a, b) => compareIds(a.id, b.id));
  const chosen = targeting.find((m) => m.id === lineageRootTaskId) ?? targeting[0];
  return chosen ? countsTowardAmountOf(chosen) : 1;
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

const EMPTY_IDS: ReadonlySet<string> = new Set();

/** What the writer knows about the contributor's fork lineage, for {@link planCountsTowardActions}. */
export interface LineageContext {
  /** Credit ids the OTHER live, flagged lineage members keep ({@link keptCreditIdsFor}). */
  wantedIds?: ReadonlySet<string>;
  /**
   * The amount the lineage writes on a root ({@link lineageCreditDelta}).
   * Applied ONLY to a credit another lineage member also wants (one in
   * `wantedIds`); a credit wanted by this contributor alone — a fork's own
   * completion — carries the contributor's own amount, so a board-scoped
   * amount edit on a fork governs the fork's own completions. Default: the
   * contributor's own amount everywhere.
   */
  deltaForRoot?: (rootId: string) => number;
}

/**
 * Reconcile a contributor's credit SET: compare the wanted credits with the
 * stored events at every candidate id and decide each write.
 *
 *   - Wanted (live contributor, flagged, target valid, occurrence at or after
 *     `countsTowardSince` — {@link isOccurrenceWanted}) + no event → `insert`.
 *   - Wanted + a tombstoned event → `revise` (revive).
 *   - Wanted + a live event that differs (amount or instant) → `revise`;
 *     identical → nothing (replay is a no-op). A moved counter is never a
 *     revise: the key carries the root, so the old credit is tombstoned and a
 *     new one inserted.
 *   - Not wanted + a live event → `tombstone` — an undone completion, a
 *     removed placement, a cleared flag (which tombstones every live credit),
 *     an occurrence before `since`, a re-pointed counter — UNLESS another
 *     live, flagged member of the contributor's fork lineage still wants that
 *     credit (`lineage.wantedIds`, from {@link keptCreditIdsFor} over the
 *     lineage): the credit belongs to the lineage, not to whichever member
 *     reconciled last.
 *   - Counter deleted (or not pulled yet) → nothing: its events go with it
 *     (§3e) — no write either way. A fork whose lineage is not fully loaded →
 *     nothing (its keys are not yet derivable).
 *
 * @param contributor - The task (flagged or not).
 * @param taskById - Every task by id (resolves the counter roots).
 * @param wanted - {@link resolveContributionCredits} for `contributor` (unfiltered).
 * @param candidateIds - {@link candidateContributionIds} for `contributor`.
 * @param storedById - The stored events at the wanted + candidate ids (any state).
 * @param lineage - See {@link LineageContext}.
 * @returns The actions, ordered by credit id (deterministic).
 */
export function planCountsTowardActions(
  contributor: Task,
  taskById: Record<string, Task>,
  wanted: ReadonlyArray<ContributionCredit>,
  candidateIds: ReadonlyArray<string>,
  storedById: Record<string, TaskEvent | undefined>,
  lineage: LineageContext = {},
): CountsTowardAction[] {
  const targetId = contributor.countsTowardCounterId ?? null;
  const target = targetId != null ? taskById[targetId] : undefined;
  if (targetId != null && (!target || target.isDeleted)) return [];
  if (!isForkLineageLoaded(contributor, taskById)) return [];
  const lineageWantedIds = lineage.wantedIds ?? EMPTY_IDS;
  const ownAmount = countsTowardAmountOf(contributor);
  const deltaFor = lineage.deltaForRoot ?? (() => ownAmount);

  const canCredit = !contributor.isDeleted && canContribute(contributor) && isCountsTowardTarget(target);
  const wantedById = new Map<string, { rootId: string; delta: number; occurredAt: string }>();
  if (canCredit) {
    for (const w of wanted) {
      if (w.rootId !== target.id || !isOccurrenceWanted(contributor, w)) continue;
      // A credit shared with another lineage member takes the lineage's amount;
      // one only this contributor wants takes its own.
      const delta = lineageWantedIds.has(w.eventId) ? deltaFor(target.id) : ownAmount;
      wantedById.set(w.eventId, { rootId: target.id, delta, occurredAt: w.occurredAt });
    }
  }
  const ids = [...new Set([...wantedById.keys(), ...candidateIds])].sort(compareIds);

  const actions: CountsTowardAction[] = [];
  for (const eventId of ids) {
    const existing = storedById[eventId];
    const want = wantedById.get(eventId);
    if (existing && !existing.isDeleted) {
      if (!want) {
        if (lineageWantedIds.has(eventId)) continue;
        const root = taskById[existing.taskId];
        if (!root || root.isDeleted) continue;
        actions.push({ kind: 'tombstone', eventId, rootId: existing.taskId, occurredAt: existing.occurredAt });
        continue;
      }
      const same =
        existing.kind === 'increment' &&
        existing.taskId === want.rootId &&
        existing.delta === want.delta &&
        sameInstant(existing.occurredAt, want.occurredAt);
      if (same) continue;
      actions.push({ kind: 'revise', eventId, ...want, previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: false });
      continue;
    }
    if (!want) continue;
    if (existing) {
      actions.push({ kind: 'revise', eventId, ...want, previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: true });
      continue;
    }
    actions.push({ kind: 'insert', eventId, ...want });
  }
  return actions;
}

/** The roots an action touches, each with the instant it writes there. */
export function creditActionReach(action: CountsTowardAction): Array<{ rootId: string; occurredAt: string }> {
  const reach = [{ rootId: action.rootId, occurredAt: action.occurredAt }];
  if (action.kind === 'revise') reach.push({ rootId: action.previousRootId, occurredAt: action.previousOccurredAt });
  return reach;
}

/**
 * D11 (ruled 2026-10-10) — credits honour the counter's sealed windows like
 * every other event: an insert / revise / tombstone is SKIPPED when the
 * instant it writes (the credit's `occurredAt`; for a revise also the
 * previous instant, on the previous root) sits inside a seal-immune window
 * of a sealed board holding that root or one of its copies
 * (`getSealImmuneWindowsForTask(root)` ↔ `sealImmuneWindows(db:taskId:)`,
 * through {@link isEventSealImmune} — a credit carries no `boardId`, so the
 * late-log relaxation never applies to the credit row itself). The one
 * exception is the closed-board LATE-LOG path, which re-derives every sealed
 * board deterministically: it passes the instant it stamped
 * (`lateLogStamp`, the closed board's `endDate`), and only an instant EQUAL
 * to that stamp is exempt — a chained credit deeper in the same cascade at
 * another instant stays suppressed. The single place the write-skip policy
 * lives.
 *
 * @param action - The planned write.
 * @param immuneWindowsByRoot - The immune windows per root the action reaches.
 * @param now - The write instant (the credit row's `createdAt`).
 * @param lateLogStamp - The late-logged instant, or `null` outside that path.
 */
export function isCreditWriteSealSuppressed(
  action: CountsTowardAction,
  immuneWindowsByRoot: Record<string, ReadonlyArray<SealImmuneWindow>>,
  now: string,
  lateLogStamp: string | null,
): boolean {
  return creditActionReach(action).some(({ rootId, occurredAt }) => {
    if (lateLogStamp != null && sameInstant(occurredAt, lateLogStamp)) return false;
    const windows = immuneWindowsByRoot[rootId] ?? [];
    return windows.length > 0 && isEventSealImmune({ occurredAt, createdAt: now, boardId: undefined }, windows);
  });
}
