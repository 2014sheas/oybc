/**
 * countsTowardCredits.ts — the Counter Detail "Counts toward" section's
 * per-contributor CREDIT COUNT (docs/SHARED_COUNTER_SETTINGS.md §3d, PR 4;
 * ruling 2026-10-10: the row shows the contributor's live credit count as a
 * muted "× N" only when N ≥ 2 — a repeating contributor; a one-off looks
 * like the drawing).
 *
 * A credit is a live increment on the counter ROOT whose id is one of the
 * contributor's candidate ids ({@link candidateContributionIds}) — the same
 * key space the cascade writes under. A fork and its original share one
 * scope ({@link lineageRootId}) and so one count: contributors are grouped by
 * lineage, the group's candidate set is the union of its members', and the
 * count is the number of live root increments inside it. The grouping is
 * pure so both platforms list identical rows.
 *
 * Swift twin: `CountsToward.contributorCreditGroups` in
 * `Helpers/CountsToward.swift`, pinned by the `creditGroups` group of
 * `tests/fixtures/countsTowardVectors.json`.
 */

import { TaskType } from '../constants/enums';
import type { Board } from '../types/board';
import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { evaluateCompound, resolvePrimitiveChildState } from './compoundEvaluation';
import {
  canContribute,
  candidateContributionIds,
  countsTowardAmountOf,
  resolveContributionState,
  type ContributionInputs,
} from './countsToward';
import { lineageRootId } from './countsTowardLineage';
import { pickPrimaryBoard } from './sharedCounterGroups';
import { boardWindowEnd, boundWindowContextAtSeal, resolveTaskWindowState, type CompoundWindowContext } from './taskEvents';

/** One fork lineage of contributors to a counter root, with its shared credit count. */
export interface ContributorCreditGroup {
  /** The lineage root id — the scope the lineage's credit keys are minted under. */
  scopeId: string;
  /** The live, flagged members (sorted by id). */
  memberIds: string[];
  /**
   * The member a row stands for: the lineage root when it is itself a live,
   * flagged member, else the smallest member id (the rule
   * `lineageCreditDelta` picks the amount by).
   */
  representativeId: string;
  /** Live increments on the root that belong to this lineage. */
  creditCount: number;
  /** The latest `occurredAt` among those credits; `null` when there are none. */
  latestOccurredAt: string | null;
}

const compareIds = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/**
 * Groups the live contributors of counter root `rootId` by fork lineage and
 * counts each lineage's live credits on the root.
 *
 * A contributor is a non-deleted task with `countsTowardCounterId === rootId`
 * that {@link canContribute}. `inputs` must carry every contributor's events
 * (any state), its compound subtree and the root's live events
 * (`eventsByTaskId[rootId]`, which the kernel keeps non-deleted); increments
 * only are counted (a completion event on a root is not a credit).
 *
 * @param rootId - The counter root.
 * @param tasks - Every task (contributors are selected from it).
 * @param inputs - See {@link ContributionInputs}.
 * @returns One group per lineage, sorted by `scopeId`.
 */
export function contributorCreditGroups(rootId: string, tasks: ReadonlyArray<Task>, inputs: ContributionInputs): ContributorCreditGroup[] {
  const contributors = tasks
    .filter((t) => !t.isDeleted && t.countsTowardCounterId === rootId && canContribute(t))
    .sort((a, b) => compareIds(a.id, b.id));
  if (contributors.length === 0) return [];

  const rootEvents = (inputs.eventsByTaskId[rootId] ?? []).filter((e) => !e.isDeleted && e.kind === 'increment');
  const liveById = new Map(rootEvents.map((e) => [e.id, e]));

  const byScope = new Map<string, Task[]>();
  for (const t of contributors) {
    const scope = lineageRootId(t, inputs.taskById);
    const members = byScope.get(scope);
    if (members) members.push(t);
    else byScope.set(scope, [t]);
  }

  const groups: ContributorCreditGroup[] = [];
  for (const [scopeId, members] of byScope) {
    const candidateIds = new Set<string>();
    for (const m of members) for (const id of candidateContributionIds(m, inputs, [rootId])) candidateIds.add(id);
    let creditCount = 0;
    let latestOccurredAt: string | null = null;
    for (const id of candidateIds) {
      const e = liveById.get(id);
      if (!e) continue;
      creditCount += 1;
      if (latestOccurredAt == null || e.occurredAt > latestOccurredAt) latestOccurredAt = e.occurredAt;
    }
    const memberIds = members.map((m) => m.id);
    groups.push({
      scopeId,
      memberIds,
      representativeId: memberIds.includes(scopeId) ? scopeId : memberIds[0],
      creditCount,
      latestOccurredAt,
    });
  }
  return groups.sort((a, b) => compareIds(a.scopeId, b.scopeId));
}

// ---------------------------------------------------------------------------
// Section rows
// ---------------------------------------------------------------------------

/** The StatusPill a Counter Detail "Counts toward" row shows. */
export type ContributorRowStatus = 'done' | 'inProgress' | 'notStarted';

/** One row of the Counter Detail "Counts toward" section — one per fork lineage. */
export interface ContributorRow {
  /** The lineage's representative task (its title / type / tap target). */
  taskId: string;
  /** The representative's CURRENT state on its primary board (lifetime when unplaced). */
  status: ContributorRowStatus;
  /** The primary board ({@link pickPrimaryBoard}); `null` when unplaced. */
  boardId: string | null;
  /** The representative's `countsTowardAmount` (1 when absent). */
  amount: number;
  /** The lineage's live credits on the root ({@link contributorCreditGroups}). */
  creditCount: number;
  /** The latest credit instant; `null` with no credits. */
  latestOccurredAt: string | null;
}

/** The window a task is evaluated over on `board` — sealed boards bounded at `sealedAt`. */
function windowContextOf(
  board: Pick<Board, 'startDate' | 'endDate' | 'sealedAt'> | null,
  eventsByTaskId: Record<string, TaskEvent[]>,
): CompoundWindowContext {
  if (!board) return { windowStart: null, windowEnd: null, eventsByTaskId };
  const sealedAtMs = board.sealedAt != null ? new Date(board.sealedAt).getTime() : NaN;
  const bounded = Number.isNaN(sealedAtMs) ? eventsByTaskId : boundWindowContextAtSeal(eventsByTaskId, sealedAtMs).eventsByTaskId;
  return { windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: bounded };
}

/** A direct child's completion in `ctx` (a nested compound derives; a primitive resolves windowed). */
function childDone(child: Task, inputs: ContributionInputs, ctx: CompoundWindowContext): boolean {
  if (child.isDeleted) return false;
  if (child.type === TaskType.COMPOUND) return evaluateCompound(child, inputs.childrenByCompound, inputs.taskById, ctx);
  return resolvePrimitiveChildState(child, ctx);
}

/**
 * A contributor's StatusPill state on `board` (lifetime when `null`):
 *
 *   - `done` — its derived completion holds in that window
 *     ({@link resolveContributionState}: the same derivation the credit uses).
 *   - `inProgress` — a plain Counting task with an in-window count above
 *     zero, or a Compound with at least one child complete in the window.
 *   - `notStarted` — otherwise (a Simple task is never in progress).
 *
 * @param task - The contributor (never a linked row or an achievement).
 * @param inputs - See {@link ContributionInputs} (its live events).
 * @param board - The board to evaluate on, or `null` for lifetime.
 */
export function contributorRowStatus(
  task: Task,
  inputs: ContributionInputs,
  board: Pick<Board, 'startDate' | 'endDate' | 'sealedAt'> | null,
): ContributorRowStatus {
  const ctx = windowContextOf(board, inputs.eventsByTaskId);
  const window = { windowStart: ctx.windowStart, windowEnd: ctx.windowEnd };
  if (resolveContributionState(task, inputs.childrenByCompound, inputs.taskById, ctx.eventsByTaskId, window).isCompleted) return 'done';
  if (task.type === TaskType.COUNTING) {
    const state = resolveTaskWindowState(task, ctx.eventsByTaskId[task.id] ?? [], ctx.windowStart, ctx.windowEnd);
    return state.count > 0 ? 'inProgress' : 'notStarted';
  }
  if (task.type === TaskType.COMPOUND) {
    const links = (inputs.childrenByCompound[task.id] ?? []).filter((l) => !l.isDeleted);
    for (const l of links) {
      const child = inputs.taskById[l.childTaskId];
      if (child && childDone(child, inputs, ctx)) return 'inProgress';
    }
  }
  return 'notStarted';
}

const STATUS_ORDER: Record<ContributorRowStatus, number> = { done: 0, inProgress: 1, notStarted: 2 };

/**
 * The Counter Detail "Counts toward" rows for counter root `rootId`: one per
 * fork lineage ({@link contributorCreditGroups}), standing for the lineage's
 * representative, placed on the representative's primary board
 * ({@link pickPrimaryBoard} over `inputs.placements` / `inputs.boardById`),
 * in the handoff's order — Done, In progress, Not started — then by title
 * (case-insensitive), then id.
 *
 * @param rootId - The counter root.
 * @param tasks - Every task.
 * @param inputs - See {@link ContributionInputs}; `placements` and
 *   `boardById` must cover every contributor's placements.
 */
export function countsTowardRows(rootId: string, tasks: ReadonlyArray<Task>, inputs: ContributionInputs): ContributorRow[] {
  const boardsById = new Map(Object.entries(inputs.boardById));
  const rows: Array<ContributorRow & { title: string }> = [];
  for (const g of contributorCreditGroups(rootId, tasks, inputs)) {
    const task = inputs.taskById[g.representativeId];
    if (!task) continue;
    const board = pickPrimaryBoard(task.id, inputs.placements, boardsById);
    rows.push({
      taskId: task.id,
      status: contributorRowStatus(task, inputs, board),
      boardId: board?.id ?? null,
      amount: countsTowardAmountOf(task),
      creditCount: g.creditCount,
      latestOccurredAt: g.latestOccurredAt,
      title: task.title.toLowerCase(),
    });
  }
  rows.sort((a, b) => STATUS_ORDER[a.status] - STATUS_ORDER[b.status] || compareIds(a.title, b.title) || compareIds(a.taskId, b.taskId));
  return rows.map(({ title: _t, ...row }) => row);
}
