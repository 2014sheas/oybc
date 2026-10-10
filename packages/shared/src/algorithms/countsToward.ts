/**
 * countsToward.ts — "counts toward": any task as the unit of a Discrete
 * shared counter (docs/SHARED_COUNTER_SETTINGS.md §3, PR 3 — data + cascade).
 *
 * A contributing task carries `countsTowardCounterId` (+ optional
 * `countsTowardAmount`, default 1). Its counter ROOT receives ONE increment
 * event per COMPLETION OCCURRENCE of the contributor (D10, ruled 2026-10-10:
 * once per occurrence, not once per task lifetime — a manual square on a
 * repeating weekly board is the SAME task every week, and counts every week
 * it is completed). Each occurrence has a stable key and a deterministic
 * credit id ({@link countsTowardEventId}); when an occurrence is no longer
 * derived (an undo, a removed placement, a cleared flag) its credit is
 * tombstoned. The write happens in the board cascade on both platforms (web
 * `db/operations/countsToward.ts` ↔ iOS `AppDatabase+CountsToward.swift`);
 * this module is the pure half:
 *
 *   - {@link countsTowardEventId} — the uuidv5 seam, so every device's
 *     re-derivation produces the same row and union-by-id sync stays correct.
 *   - {@link resolveContributionCredits} — the WANTED credits, from live data.
 *   - {@link candidateContributionIds} — every credit id the contributor may
 *     have owned (live AND tombstoned data), so a withdrawn occurrence is found
 *     and tombstoned.
 *   - {@link planCountsTowardActions} — the per-contributor set reconciliation:
 *     insert / revise / tombstone per credit id (idempotent).
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
 *     derivation is complete; key = `window:<board startDate>` (unplaced →
 *     `lifetime`). Compounds own no events, so the window stands in.
 *
 * An event key is globally unique, so the credit id for an event-keyed
 * occurrence does NOT include the contributor id: a board-scoped fork copies
 * the original's in-window events onto itself (`forkedEventId`) — a copy is
 * resolved back to its SOURCE event's id through the `forkedFromTaskId`
 * lineage ({@link canonicalOccurrenceEventId}), so the original and its fork
 * share one credit instead of double-counting.
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
import { forkedEventId } from './boardScopedFork';
import { quantizeCount, resolveCountKind } from './countValue';
import { isWindowStampedDerived } from './memberRules';
import {
  boardWindowEnd,
  boundWindowContextAtSeal,
  resolveDerivedCounterWindowState,
  resolveTaskWindowState,
  resolveWindowStampedDerivedState,
  type CompoundWindowContext,
} from './taskEvents';
import { uuidv5 } from './uuidv5';

/** uuidv5 name prefix for a contributing task's counts-toward increments. */
export const COUNTS_TOWARD_NAMESPACE = 'counts-toward:event';

/** One completion occurrence of a contributor — the key its credit is minted under. */
export type ContributionOccurrence =
  | { kind: 'event'; eventId: string }
  | { kind: 'window'; startDate: string }
  | { kind: 'lifetime' };

/**
 * Deterministic id of the credit `contributorId` writes on its counter root
 * for `occurrence`.
 *
 *   - `event`    → `uuidv5("counts-toward:event:<eventId>")` — the event id is
 *                  globally unique, so the contributor is NOT part of the name
 *                  (a fork's copied event resolves to the same credit).
 *   - `window`   → `uuidv5("counts-toward:event:<contributorId>:window:<startDate>")`.
 *   - `lifetime` → `uuidv5("counts-toward:event:<contributorId>:lifetime")`.
 *
 * @param contributorId - The task carrying `countsTowardCounterId`.
 * @param occurrence - The occurrence key.
 * @returns A stable uuidv5 — every device derives the same id.
 */
export function countsTowardEventId(contributorId: string, occurrence: ContributionOccurrence): string {
  switch (occurrence.kind) {
    case 'event':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${occurrence.eventId}`);
    case 'window':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${contributorId}:window:${occurrence.startDate}`);
    case 'lifetime':
      return uuidv5(`${COUNTS_TOWARD_NAMESPACE}:${contributorId}:lifetime`);
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
  /** For an event-owning contributor: the event that completed it (its crossing / first completion). */
  completingEventId?: string;
}

const INCOMPLETE: ContributionState = { isCompleted: false, completedAt: null };

/** A window a contribution is evaluated over (`null` bounds = lifetime). */
export type ContributionWindow = Pick<CompoundWindowContext, 'windowStart' | 'windowEnd'>;

/** The lifetime window: no bounds. */
export const LIFETIME_WINDOW: ContributionWindow = { windowStart: null, windowEnd: null };

const toMs = (iso: string): number => new Date(iso).getTime();

const compareIds = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/** Ascending by parsed instant, then by string (deterministic ties). */
function sortInstants(instants: string[]): string[] {
  return [...instants].sort((a, b) => toMs(a) - toMs(b) || compareIds(a, b));
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
  return event ? { isCompleted: true, completedAt: event.occurredAt, completingEventId: event.id } : INCOMPLETE;
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
 *     (`completingEventId`).
 *   - Window-stamped linked COUNTING (a compound child) — the root's events
 *     inside its own window, same crossing rule. Any other linked child
 *     resolves over the HOST window (owner rule 2026-10-01); only a lifetime
 *     window reads its latch (`completedAt`), as `evaluateCompound` does.
 *   - COMPOUND — the operator over its live children (the same states
 *     `evaluateCompound` gives in that window); the instant is when the rule
 *     became satisfied: All of → the LAST child's instant (the max), Any of →
 *     the first, At least N → the N-th. A counts-toward container with no
 *     children is incomplete.
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
 * @returns `{ isCompleted, completedAt, completingEventId? }`.
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
  return { isCompleted: true, completedAt: s.completedAt ?? task.createdAt, ...(s.completingEventId ? { completingEventId: s.completingEventId } : {}) };
}

/** The data a contributor's credits are derived from. */
export interface ContributionInputs {
  /** Every task by id (resolves the counter root, compound children, fork lineage). */
  taskById: Record<string, Task>;
  /** `compoundTaskId` → links (deleted ones ignored). */
  childrenByCompound: Record<string, CompoundChild[]>;
  /** Non-deleted events grouped by `taskId` (the kernel convention). */
  eventsByTaskId: Record<string, TaskEvent[]>;
  /**
   * EVERY event (tombstones included) of the contributor and of its fork
   * ancestors, grouped by `taskId` — the candidate keys, and the fork lineage
   * a copied event is resolved through.
   */
  allEventsByTaskId: Record<string, TaskEvent[]>;
  /** The contributor's placements, any state (rows for other tasks are ignored). */
  placements: ReadonlyArray<Pick<BoardTask, 'boardId' | 'taskId' | 'isDeleted'>>;
  /** Boards referenced by `placements`, any state. A board absent here is treated as not live. */
  boardById: Record<string, Pick<Board, 'id' | 'isDeleted' | 'status' | 'startDate' | 'endDate' | 'sealedAt'>>;
}

/** One credit a contributor wants on its counter root. */
export interface ContributionCredit {
  /** The credit's deterministic id ({@link countsTowardEventId}). */
  eventId: string;
  occurrence: ContributionOccurrence;
  /** The completion instant the credit is stamped at. */
  occurredAt: string;
}

/** Deepest `forkedFromTaskId` chain followed when resolving a copied event. */
const MAX_FORK_LINEAGE = 8;

/**
 * The SOURCE event id an event of `task` is keyed by: for a board-scoped
 * fork, a copied event (`forkedEventId(fork.id, source.id)`) resolves to the
 * original's event, transitively up the `forkedFromTaskId` lineage; any
 * other event is its own key.
 *
 * @param eventId - An event of `task`.
 * @param task - The event's owner.
 * @param taskById - Every task by id.
 * @param allEventsByTaskId - Every event (any state) of the lineage, by `taskId`.
 * @returns The canonical event id.
 */
export function canonicalOccurrenceEventId(
  eventId: string,
  task: Pick<Task, 'id' | 'forkedFromTaskId'>,
  taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>,
  allEventsByTaskId: Record<string, TaskEvent[]>,
): string {
  let current = task;
  let id = eventId;
  for (let depth = 0; depth < MAX_FORK_LINEAGE; depth += 1) {
    const sourceId = current.forkedFromTaskId;
    if (sourceId == null) return id;
    const source = taskById[sourceId];
    if (!source) return id;
    const match = (allEventsByTaskId[sourceId] ?? []).find((e) => forkedEventId(current.id, e.id) === id);
    if (!match) return id;
    id = match.id;
    current = source;
  }
  return id;
}

/** The live boards placing `task`, each as the window its square is evaluated over (sealed → bounded at `sealedAt`). */
function liveWindowsOf(task: Task, inputs: ContributionInputs): Array<{ startDate: string; ctx: CompoundWindowContext }> {
  const seen = new Set<string>();
  const out: Array<{ startDate: string; ctx: CompoundWindowContext }> = [];
  for (const p of inputs.placements) {
    if (p.isDeleted || p.taskId !== task.id || seen.has(p.boardId)) continue;
    seen.add(p.boardId);
    const b = inputs.boardById[p.boardId];
    if (!b || b.isDeleted || b.status === BoardStatus.DRAFT) continue;
    const sealedAtMs = b.sealedAt != null ? toMs(b.sealedAt) : NaN;
    const eventsByTaskId = Number.isNaN(sealedAtMs)
      ? inputs.eventsByTaskId
      : boundWindowContextAtSeal(inputs.eventsByTaskId, sealedAtMs).eventsByTaskId;
    out.push({ startDate: b.startDate, ctx: { windowStart: b.startDate, windowEnd: boardWindowEnd(b), eventsByTaskId } });
  }
  return out.sort((a, b) => toMs(a.startDate) - toMs(b.startDate) || compareIds(a.startDate, b.startDate));
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
 *     complete, keyed `window:<board startDate>` (two boards sharing a start
 *     date credit once — the known caveat); placed nowhere → `lifetime`.
 *   - A linked row, an achievement or a deleted task — none.
 *
 * Does NOT consult the flag or the target: {@link planCountsTowardActions}
 * applies those.
 *
 * @param task - The contributor.
 * @param inputs - See {@link ContributionInputs}.
 * @returns The wanted credits, deduplicated by id, in a deterministic order.
 */
export function resolveContributionCredits(task: Task, inputs: ContributionInputs): ContributionCredit[] {
  if (task.isDeleted) return [];
  const byId = new Map<string, ContributionCredit>();
  const want = (occurrence: ContributionOccurrence, occurredAt: string): void => {
    const eventId = countsTowardEventId(task.id, occurrence);
    const prior = byId.get(eventId);
    if (!prior || toMs(occurredAt) < toMs(prior.occurredAt)) byId.set(eventId, { eventId, occurrence, occurredAt });
  };
  const eventKey = (eventId: string): ContributionOccurrence => ({
    kind: 'event',
    eventId: canonicalOccurrenceEventId(eventId, task, inputs.taskById, inputs.allEventsByTaskId),
  });

  if (task.type === TaskType.NORMAL) {
    for (const e of inputs.eventsByTaskId[task.id] ?? []) {
      if (!e.isDeleted && e.kind === 'completion') want(eventKey(e.id), e.occurredAt);
    }
  } else if (task.type === TaskType.COUNTING) {
    if (task.sharedCounterId) return [];
    const windows = liveWindowsOf(task, inputs);
    const contexts = windows.length > 0 ? windows.map((w) => w.ctx) : [{ ...LIFETIME_WINDOW, eventsByTaskId: inputs.eventsByTaskId }];
    for (const ctx of contexts) {
      const s = resolveContributionState(task, inputs.childrenByCompound, inputs.taskById, ctx.eventsByTaskId, ctx);
      if (s.isCompleted && s.completingEventId) want(eventKey(s.completingEventId), s.completedAt as string);
    }
  } else if (task.type === TaskType.COMPOUND) {
    const windows = liveWindowsOf(task, inputs);
    if (windows.length === 0) {
      const s = resolveContributionState(task, inputs.childrenByCompound, inputs.taskById, inputs.eventsByTaskId);
      if (s.isCompleted) want({ kind: 'lifetime' }, s.completedAt as string);
    }
    for (const w of windows) {
      const s = resolveContributionState(task, inputs.childrenByCompound, inputs.taskById, w.ctx.eventsByTaskId, w.ctx);
      if (s.isCompleted) want({ kind: 'window', startDate: w.startDate }, s.completedAt as string);
    }
  }
  return [...byId.values()].sort((a, b) => compareIds(a.eventId, b.eventId));
}

/**
 * Every credit id `task` MAY own — a superset of
 * {@link resolveContributionCredits} built from live AND tombstoned data:
 * every event of the task (raw id and its fork-resolved id), one window key
 * per placement (any state, boards any state), and the lifetime key. A
 * stored credit at any of these ids that is no longer wanted is tombstoned.
 *
 * @param task - The contributor (flagged or not).
 * @param inputs - See {@link ContributionInputs}.
 * @returns Sorted, deduplicated credit ids.
 */
export function candidateContributionIds(task: Task, inputs: ContributionInputs): string[] {
  const ids = new Set<string>();
  for (const e of inputs.allEventsByTaskId[task.id] ?? []) {
    ids.add(countsTowardEventId(task.id, { kind: 'event', eventId: e.id }));
    ids.add(
      countsTowardEventId(task.id, {
        kind: 'event',
        eventId: canonicalOccurrenceEventId(e.id, task, inputs.taskById, inputs.allEventsByTaskId),
      }),
    );
  }
  for (const p of inputs.placements) {
    if (p.taskId !== task.id) continue;
    const b = inputs.boardById[p.boardId];
    if (b) ids.add(countsTowardEventId(task.id, { kind: 'window', startDate: b.startDate }));
  }
  ids.add(countsTowardEventId(task.id, { kind: 'lifetime' }));
  return [...ids].sort(compareIds);
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
 * Reconcile a contributor's credit SET: compare the wanted credits with the
 * stored events at every candidate id and decide each write.
 *
 *   - Wanted (live contributor, flagged, target valid) + no event → `insert`.
 *   - Wanted + a tombstoned event → `revise` (revive).
 *   - Wanted + a live event that differs (counter, amount or instant) →
 *     `revise`; identical → nothing (replay is a no-op).
 *   - Not wanted + a live event → `tombstone` — an undone completion, a
 *     removed placement, a cleared flag (which tombstones every live credit).
 *   - Counter deleted (or not pulled yet) → nothing: its events go with it
 *     (§3e) — no write either way.
 *
 * @param contributor - The task (flagged or not).
 * @param taskById - Every task by id (resolves the counter roots).
 * @param wanted - {@link resolveContributionCredits} for `contributor`.
 * @param candidateIds - {@link candidateContributionIds} for `contributor`.
 * @param storedById - The stored events at the wanted + candidate ids (any state).
 * @returns The actions, ordered by credit id (deterministic).
 */
export function planCountsTowardActions(
  contributor: Task,
  taskById: Record<string, Task>,
  wanted: ReadonlyArray<ContributionCredit>,
  candidateIds: ReadonlyArray<string>,
  storedById: Record<string, TaskEvent | undefined>,
): CountsTowardAction[] {
  const targetId = contributor.countsTowardCounterId ?? null;
  const target = targetId != null ? taskById[targetId] : undefined;
  if (targetId != null && (!target || target.isDeleted)) return [];

  const canCredit = !contributor.isDeleted && isCountsTowardTarget(target);
  const wantedById = new Map<string, { rootId: string; delta: number; occurredAt: string }>();
  if (canCredit) {
    for (const w of wanted) wantedById.set(w.eventId, { rootId: target.id, delta: countsTowardAmountOf(contributor), occurredAt: w.occurredAt });
  }
  const ids = [...new Set([...wantedById.keys(), ...candidateIds])].sort(compareIds);

  const actions: CountsTowardAction[] = [];
  for (const eventId of ids) {
    const existing = storedById[eventId];
    const want = wantedById.get(eventId);
    if (existing && !existing.isDeleted) {
      if (!want) {
        const root = taskById[existing.taskId];
        if (!root || root.isDeleted) continue;
        actions.push({ kind: 'tombstone', eventId, rootId: existing.taskId, occurredAt: existing.occurredAt });
        continue;
      }
      const same =
        existing.kind === 'increment' &&
        existing.taskId === want.rootId &&
        existing.delta === want.delta &&
        toMs(existing.occurredAt) === toMs(want.occurredAt);
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
