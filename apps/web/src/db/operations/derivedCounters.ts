import {
  SyncOperationType,
  TaskType,
  buildDerivedRows,
  computeWindowBaseline,
  isWindowStampedDerived,
  planDerivedTasks,
  type BoardWindow,
  type CompoundChild,
  type DerivedRows,
  type ExpandedSupply,
  type PlanMode,
  type Task,
  type TaskEvent,
  type VaryLevel,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';

/**
 * derivedCounters.ts — Board Sources "member rules" B2, web half
 * (docs/BOARD_SOURCES.md §Member rules → *Resolution pipeline* steps 1/3/5,
 * *Baseline*).
 *
 * Two jobs, both of them writes that the shared `memberRules.ts` algorithms
 * only describe:
 *
 *  1. **Mint** — at board persist and at recurring spawn, turn the planned
 *     window-stamped derived counters / derived compounds into real
 *     `tasks` + `compound_children` rows, BEFORE the `board_tasks` rows that
 *     point at them, and hand the caller back the placement ids to use.
 *  2. **Refresh** — keep a live derived counter's `baseline` honest as the
 *     root's event log changes underneath it (local counter writes and the
 *     sync pull path), as a NON-AUTHORED write: no `version` bump, no sync
 *     enqueue. The baseline is a cache derived from events, exactly like the
 *     lifetime caches `recomputeTaskCachesFromPull` restamps; authoring it
 *     would make two devices fight over a value both can recompute.
 *
 * Every exported function here MUST be called from inside an already-open
 * Dexie transaction that scopes the tables it touches (`tasks`,
 * `compoundChildren`, `taskEvents`, `syncQueue`). None of them opens a
 * transaction of its own — the mint has to commit or roll back together with
 * the board rows it feeds, and the refresh has to be atomic with the event
 * write that made it necessary.
 *
 * Has a Swift twin (B2 tasks 5–6); the write rulings below are pinned in the
 * plan as RB2/RB3/RB6 and must stay identical on both platforms.
 */

/** Inputs to {@link planAndMintDerivedRows}. */
export interface PlanAndMintDerivedRowsArgs {
  /** The board being assembled — half of every derived row's deterministic id. */
  boardId: string;
  userId: string;
  /** ISO8601 mint instant — `createdAt`/`updatedAt` on every row written. */
  now: string;
  /** The task ids picked for the board, in placement order (centre included). */
  selectedIds: string[];
  /** Per-source supplies, exclude-filtered and Split-up expanded (`applyMemberRules`). */
  supplies: ExpandedSupply[];
  /** Hand-added ids — they win over any source copy. */
  manualTaskIds: string[];
  /** Hand-added members' vary levels (RB7/RB9: `{}` until a UI authors them). */
  manualTaskVary: Record<string, VaryLevel>;
  /** The window being assembled. */
  window: BoardWindow;
  mode: PlanMode;
  /** Every id `selectedIds` / the supplies / the compound links can name. */
  tasksById: Record<string, Task>;
  childrenByCompoundId: Record<string, CompoundChild[]>;
  /** Board-source members' (and their compound children's) source windows. */
  sourceWindowByTaskId: Record<string, BoardWindow | undefined>;
  /** Candidate roots' `task_events` rows (see {@link candidateRootIds}). */
  events: TaskEvent[];
  /** RB6 — unseeded `Math.random` in production; injected in tests. */
  rng?: () => number;
}

/** Output of {@link planAndMintDerivedRows}. */
export interface PlanAndMintDerivedRowsResult {
  /**
   * What the caller must place, positionally 1:1 with `selectedIds` — a
   * replaced id keeps its cell, so a pinned/centre square that resolves to a
   * derived counter stays exactly where the user put it.
   */
  placementIds: string[];
  /** The rows actually materialised by the plan (before the RB3 write loop). */
  minted: DerivedRows;
}

/**
 * The shared-counter roots a plan over `selectedIds` could touch: every
 * counting member's root (`sharedCounterId ?? id`), plus the roots of every
 * counting child of a selected compound (a One-square compound re-targets its
 * parts, so their roots matter even though the child itself isn't selected).
 *
 * Callers use this to scope the `task_events` read that feeds the baselines —
 * reading the whole event log to mint one board would be quadratic on a
 * device with a real history.
 *
 * @param selectedIds - The ids picked for the board.
 * @param tasksById - Id → task, for every id `selectedIds` and the links name.
 * @param childrenByCompoundId - Compound id → its live `compound_children` rows.
 * @returns The deduped candidate root ids.
 */
export function candidateRootIds(
  selectedIds: string[],
  tasksById: Record<string, Pick<Task, 'id' | 'type' | 'sharedCounterId'>>,
  childrenByCompoundId: Record<string, Pick<CompoundChild, 'childTaskId'>[]>,
): string[] {
  const roots = new Set<string>();
  const addRoot = (t: Pick<Task, 'id' | 'type' | 'sharedCounterId'> | undefined): void => {
    if (!t || t.type !== TaskType.COUNTING) return;
    roots.add(t.sharedCounterId ?? t.id);
  };
  for (const id of selectedIds) {
    const t = tasksById[id];
    if (!t) continue;
    addRoot(t);
    if (t.type !== TaskType.COMPOUND) continue;
    for (const k of childrenByCompoundId[id] ?? []) addRoot(tasksById[k.childTaskId]);
  }
  return [...roots];
}

/**
 * RB3 — write one planned row idempotently.
 *
 * Three cases, because the row's id is a pure function of `(boardId, root)`
 * and so re-deriving the same window hits the same primary key:
 *   - **absent** → insert + enqueue a CREATE (the ordinary mint);
 *   - **live** → skip entirely. No write, no enqueue, no `updatedAt` churn:
 *     a second spawn/save of the same window must be a true no-op, or every
 *     re-entry would push a redundant row to Firestore and clobber a
 *     concurrently-edited target;
 *   - **tombstoned** → a versioned revive (`version + 1`, `isDeleted` false,
 *     `deletedAt` gone) + an UPDATE enqueue, so the revive OUTRANKS the
 *     tombstone under LWW instead of losing to it and self-reverting (the
 *     same defect `BoardTask` tombstones fixed in docs/BOARD_INTEGRITY.md
 *     PR-1). `createdAt` is preserved — the row's birth hasn't moved.
 *
 * @param table - `'tasks'` or `'compoundChildren'` (the sync collection name).
 * @param row - The freshly built row, carrying this window's field values.
 * @param now - The mint instant, stamped on a revive.
 * @returns True when a row was written (insert or revive).
 */
async function writeMintedRow<T extends Task | CompoundChild>(
  table: 'tasks' | 'compoundChildren',
  row: T,
  now: string,
): Promise<boolean> {
  const store = table === 'tasks' ? db.tasks : db.compoundChildren;
  const existing = (await store.get(row.id)) as T | undefined;
  if (existing === undefined) {
    await (store as { add: (r: T) => Promise<unknown> }).add(row);
    await addToSyncQueue(table, row.id, SyncOperationType.CREATE, row);
    return true;
  }
  if (!existing.isDeleted) return false;
  const revived = {
    ...row,
    createdAt: existing.createdAt,
    updatedAt: now,
    version: (existing.version ?? 0) + 1,
    isDeleted: false,
  } as T;
  delete (revived as { deletedAt?: string }).deletedAt;
  await (store as { put: (r: T) => Promise<unknown> }).put(revived);
  await addToSyncQueue(table, row.id, SyncOperationType.UPDATE, revived);
  return true;
}

/**
 * Plan the member rules for one board and materialise what they produce
 * (docs/BOARD_SOURCES.md §Member rules — *Resolution pipeline* steps 3 + 5).
 *
 * Runs INSIDE the caller's open transaction, which must scope `tasks`,
 * `compoundChildren` and `syncQueue`. The caller places `placementIds`
 * instead of its own `selectedIds`, positionally — the two arrays are the
 * same length and a replaced id keeps its cell.
 *
 * Baselines are computed at RB2's boundary: the board's `startDate` when it
 * has one, else the mint `now` (an INDEFINITE board's window opens the moment
 * it is created). `startDate` is passed through verbatim — web board dates are
 * LOCAL ISO with a time component, and `computeWindowBaseline` compares
 * instants, so re-stamping it as UTC would move the boundary by the local
 * offset.
 *
 * @param args - See {@link PlanAndMintDerivedRowsArgs}.
 * @returns The placement ids to write, and the rows the plan produced.
 */
export async function planAndMintDerivedRows(
  args: PlanAndMintDerivedRowsArgs,
): Promise<PlanAndMintDerivedRowsResult> {
  const {
    boardId,
    userId,
    now,
    selectedIds,
    supplies,
    manualTaskIds,
    manualTaskVary,
    window,
    mode,
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
    events,
    rng = Math.random,
  } = args;

  // RB2 — the window boundary. `startDate` is a full local-ISO timestamp on
  // every board that has one; a date-less (INDEFINITE) board opens now.
  const boundary = window.startDate ?? now;
  const baselineByRootId: Record<string, number> = {};
  for (const root of candidateRootIds(selectedIds, tasksById, childrenByCompoundId)) {
    baselineByRootId[root] = computeWindowBaseline(root, events, boundary);
  }

  const drafts = planDerivedTasks({
    selectedIds,
    supplies,
    manualTaskIds,
    manualTaskVary,
    boardId,
    window,
    mode,
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
    baselineByRootId,
    rng,
  });

  if (drafts.derivedTasks.length === 0 && drafts.derivedCompounds.length === 0) {
    return { placementIds: drafts.placementIds, minted: { tasks: [], links: [] } };
  }

  // `buildDerivedRows` degrades quietly rather than throwing when a root or a
  // source compound is missing from its maps (see `DerivedRowsInput`), so fill
  // them for EVERY id the drafts reference — `tasksById` covers the selected
  // members, but a member that is itself a derived counter points at a root
  // that may not be on this board at all.
  const rootsById: Record<string, Task> = {};
  for (const d of drafts.derivedTasks) {
    const local = tasksById[d.rootTaskId] ?? (await db.tasks.get(d.rootTaskId));
    if (local) rootsById[d.rootTaskId] = local;
  }
  const compoundsById: Record<string, Task> = {};
  for (const c of drafts.derivedCompounds) {
    const local = tasksById[c.sourceCompoundId] ?? (await db.tasks.get(c.sourceCompoundId));
    if (local) compoundsById[c.sourceCompoundId] = local;
  }

  const minted = buildDerivedRows({ drafts, userId, now, rootsById, compoundsById });

  for (const row of minted.tasks) await writeMintedRow('tasks', row, now);
  for (const link of minted.links) await writeMintedRow('compoundChildren', link, now);

  return { placementIds: drafts.placementIds, minted };
}

/**
 * The live window-stamped derived counters that derive from `rootTaskId`.
 *
 * All three marks (`isWindowStampedDerived`) are required — a hand-made
 * linked counter shares the `sharedCounterId` index with them and must never
 * have its `baseline` rewritten by this pipeline.
 *
 * @param rootTaskId - The shared-counter root.
 * @returns A Dexie collection of the matching live rows.
 */
export function windowStampedDerivedQuery(rootTaskId: string) {
  return db.tasks
    .where('sharedCounterId')
    .equals(rootTaskId)
    .filter((t) => !t.isDeleted && isWindowStampedDerived(t));
}

/**
 * Recompute every window-stamped derived counter's `baseline` from the root's
 * current event log (docs/BOARD_SOURCES.md §Member rules — *Baseline*).
 *
 * A NON-AUTHORED write, exactly like `recomputeTaskCachesFromPull`: it writes
 * `baseline` and nothing else — no `updatedAt`, no `version` bump, no sync
 * enqueue. The baseline is a pure function of `(root events, window start)`,
 * so every device recomputes the same value from rows it already has;
 * authoring it would put two devices into an LWW fight over a derived number.
 *
 * Each row's boundary is its own `startDate` (its window), falling back to
 * `createdAt` for the INDEFINITE case where RB2 used the mint instant.
 * A row whose baseline is already correct is not touched at all, so calling
 * this after every counter write is cheap and idempotent.
 *
 * Must run inside the caller's open transaction (scoping `tasks`, and
 * `taskEvents` unless `events` is supplied).
 *
 * @param rootTaskId - The shared-counter root whose derived members to refresh.
 * @param events - The root's events, when the caller already has them in hand;
 *   omitted, they are read inside the caller's transaction.
 * @returns How many rows were actually rewritten.
 */
export async function refreshDerivedBaselines(
  rootTaskId: string,
  events?: TaskEvent[],
): Promise<number> {
  const rows = await windowStampedDerivedQuery(rootTaskId).toArray();
  if (rows.length === 0) return 0;
  const rootEvents = events ?? (await db.taskEvents.where('taskId').equals(rootTaskId).toArray());
  let touched = 0;
  for (const row of rows) {
    const boundary = row.startDate ?? row.createdAt;
    const baseline = computeWindowBaseline(rootTaskId, rootEvents, boundary);
    if ((row.baseline ?? 0) === baseline) continue;
    await db.tasks.update(row.id, { baseline });
    touched += 1;
  }
  return touched;
}
