import type { Collection } from 'dexie';
import {
  SyncOperationType,
  TaskType,
  buildDerivedRows,
  computeWindowBaseline,
  derivedTaskId,
  expandToWindowStampedDerived,
  isWindowStampedDerived,
  planDerivedTasks,
  type Board,
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
import { buildBoardTaskTombstone } from './boardTasks';

/**
 * derivedCounters.ts — Board Sources "member rules" B2, web half
 * (docs/BOARD_SOURCES.md §Member rules → *Resolution pipeline* steps 1/3/5,
 * *Baseline*).
 *
 * Three jobs, all of them writes that the shared `memberRules.ts` algorithms
 * only describe:
 *
 *  1. **Mint** — at board persist and at recurring spawn, turn the planned
 *     window-stamped derived counters / derived compounds into real
 *     `tasks` + `compound_children` rows, BEFORE the `board_tasks` rows that
 *     point at them, and hand the caller back the placement ids to use.
 *     Only a board that is being persisted ACTIVE mints: a derived id is
 *     `uuidv5(boardId, root)` and does not encode the window, while a DRAFT's
 *     window is still editable — so minting for a draft and then skipping the
 *     live row on the activating save would freeze the board into a
 *     window it no longer has. A draft places its original member ids;
 *     activation derives the window once, from final values.
 *  2. **Refresh** — keep a live derived counter's `baseline` honest as the
 *     root's event log changes underneath it (local counter writes and the
 *     sync pull path), as a NON-AUTHORED write: no `version` bump, no sync
 *     enqueue. The baseline is a cache derived from events, exactly like the
 *     lifetime caches `recomputeTaskCachesFromPull` restamps; authoring it
 *     would make two devices fight over a value both can recompute.
 *  3. **Retire** — when a derived row's root is deleted, or the last live
 *     board carrying it goes away, tombstone the row with its placements and
 *     links (see the *Deletion* section at the bottom of this file). A
 *     per-window derived row is an artifact of one board's window, not
 *     library content, so it is retired rather than unlinked-and-kept.
 *
 * Every exported function here MUST be called from inside an already-open
 * Dexie transaction that scopes the tables it touches (`tasks`,
 * `compoundChildren`, `taskEvents`, `syncQueue`). None of them opens a
 * transaction of its own — the mint has to commit or roll back together with
 * the board rows it feeds, and the refresh has to be atomic with the event
 * write that made it necessary.
 *
 * Swift twin: `AppDatabase+DerivedCounters.swift` — the write rulings here
 * must stay identical on both platforms.
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
 * Module-private: {@link refreshDerivedBaselines} and
 * {@link windowStampedDerivedIdsForRoot} (the deletion sweep's entry point)
 * are its two callers.
 *
 * @param rootTaskId - The shared-counter root.
 * @returns A Dexie collection of the matching live rows.
 */
function windowStampedDerivedQuery(rootTaskId: string): Collection<Task, string, Task> {
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
 * Each row's boundary is its own `startDate` — always present, because
 * `isWindowStampedDerived` is what selects the rows and it requires one. The
 * consequence worth stating: a derived counter minted for a board with NO
 * `startDate` (an INDEFINITE board, where RB2 used the mint instant) carries
 * no window stamp, fails that predicate, and is therefore never refreshed on
 * any path. That is the spec's own window-stamped scoping, not a gap — such a
 * board has no window for a baseline to be relative to.
 *
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
    // `row.startDate` is non-null by construction — see the note above.
    const baseline = computeWindowBaseline(rootTaskId, rootEvents, row.startDate!);
    if ((row.baseline ?? 0) === baseline) continue;
    await db.tasks.update(row.id, { baseline });
    touched += 1;
  }
  return touched;
}

/**
 * Live-cascade reachability for a pull that moved some roots' event sets:
 * `taskIds` plus every live window-stamped derived row linked to one of them
 * (shared `expandToWindowStampedDerived`, indexed on `sharedCounterId`). The
 * root is never placed, but those rows resolve from its events in the
 * derivation kernel, so the batched board cascade must start from them too —
 * otherwise a pulled root event leaves every live board placing its derived
 * row with stale `completedTasks`/lines until an unrelated write.
 *
 * Must run inside the caller's open transaction (scoping `tasks`).
 *
 * @param taskIds - The tasks whose events changed in this pull.
 * @returns A new set: `taskIds` plus the reachable derived row ids.
 */
export async function withWindowStampedDerived(taskIds: Set<string>): Promise<Set<string>> {
  if (taskIds.size === 0) return new Set(taskIds);
  const linked = await db.tasks.where('sharedCounterId').anyOf([...taskIds]).toArray();
  return expandToWindowStampedDerived(taskIds, linked);
}

/**
 * Re-derive ONE just-pulled derived counter's `baseline` from the LOCAL event
 * log of its root (final-review FI1).
 *
 * `baseline` rides the wire — every authored write to a derived row ships the
 * whole `Task` — so a device that minted the row while missing a pre-window
 * increment pushes a SHORT baseline, and a receiving device whose event union
 * is complete has its correct value clobbered by ordinary LWW. On that device
 * the ROOT's count is not short, so every read of the member is inflated by the
 * missing delta, silently, until someone increments that root locally.
 *
 * The cure takes the same posture {@link refreshDerivedBaselines} already takes
 * on the `taskEvents` pull: recompute from rows this device already holds and
 * write `baseline` and nothing else — no `updatedAt`, no `version` bump, no
 * sync enqueue — so the value converges without either side authoring it.
 * Called from the `tasks` branch of the pull-apply path, right after the
 * remote-wins upsert and BEFORE the board cascade, so the cascade sees the
 * corrected number.
 *
 * A row that isn't a live window-stamped derived counter, or whose baseline is
 * already right, is not touched at all.
 *
 * Must run inside the caller's open transaction (scoping `tasks` +
 * `taskEvents`).
 *
 * @param task - The row the pull just applied.
 * @returns True when the row's `baseline` was actually rewritten.
 */
export async function refreshPulledDerivedBaseline(task: Task): Promise<boolean> {
  if (task.isDeleted || !isWindowStampedDerived(task)) return false;
  const rootTaskId = task.sharedCounterId!;
  const rootEvents = await db.taskEvents.where('taskId').equals(rootTaskId).toArray();
  // `task.startDate` is non-null by construction — `isWindowStampedDerived`.
  const baseline = computeWindowBaseline(rootTaskId, rootEvents, task.startDate!);
  if ((task.baseline ?? 0) === baseline) return false;
  await db.tasks.update(task.id, { baseline });
  return true;
}

// ─── Deletion sweep (docs/BOARD_SOURCES.md §Member rules — *Deletion*) ────────

/**
 * Is this STORED row one of our per-window derived COMPOUNDS?
 *
 * The compound twin of `isWindowStampedDerived` (which keys off the
 * shared-counter link a compound doesn't have): a window start plus the
 * wizard-born provenance flag on a compound row. A hand-made compound carries
 * neither, and a timeboxed one carries only the first — so the pair is what
 * identifies a row the planner re-targeted for exactly one window.
 *
 * @param t - The task row to test.
 * @returns True when the row is a per-window derived compound.
 */
export function isWindowStampedDerivedCompound(
  t: Pick<Task, 'type' | 'startDate' | 'createdInWizard'>,
): boolean {
  return t.type === TaskType.COMPOUND && !!t.startDate && t.createdInWizard === true;
}

/**
 * The live window-stamped derived counters that derive from `rootTaskId`.
 *
 * The deletion sweep's read half: a root's retirement takes its per-window
 * derived counters with it, because such a row is an artifact of one board's
 * window and means nothing once its root is gone. Ordinary linked members
 * (no window stamp) are NOT returned — those are the user's own rows and are
 * unlinked-and-preserved by `deleteCounterWithUnlink` instead.
 *
 * @param rootTaskId - The shared-counter root being deleted.
 * @returns The ids of its live window-stamped derived counters.
 */
export async function windowStampedDerivedIdsForRoot(rootTaskId: string): Promise<string[]> {
  const rows = await windowStampedDerivedQuery(rootTaskId).toArray();
  return rows.map((t) => t.id);
}

/**
 * Does this task still have a live placement somewhere other than `boardId`?
 *
 * RB5's test, factored out so the placed sweep and the compound-part sweep
 * below cannot drift apart: a live placement is a `board_tasks` row with
 * `isDeleted === false` whose board is ALSO live. A tombstoned board holds
 * nothing alive — which is why the board being deleted is excluded twice
 * over, by id here and by its own fresh tombstone.
 *
 * @param taskId - The task being tested.
 * @param excludeBoardId - The board being deleted.
 * @returns True when some other live board still places it.
 */
async function hasLivePlacementElsewhere(
  taskId: string,
  excludeBoardId: string,
): Promise<boolean> {
  const elsewhere = await db.boardTasks
    .where('taskId')
    .equals(taskId)
    .filter((bt) => !bt.isDeleted && bt.boardId !== excludeBoardId)
    .toArray();
  for (const bt of elsewhere) {
    const board = await db.boards.get(bt.boardId);
    if (board && !board.isDeleted) return true;
  }
  return false;
}

/**
 * Do two stored `startDate`s name the same window opening (final-review M2)?
 *
 * `Board.startDate` has TWO live encodings — the local ISO the wizard writes
 * (`2026-09-18T00:00:00`, no offset) and the full UTC form a sync round-trip
 * can hand back — and a derived row copies whichever one its board carried at
 * mint time. Those two never compare equal as strings, so a plain `!==` would
 * make {@link isMintedForBoard} answer "not mine" for a re-encoded pull and
 * silently skip the retire. Comparing INSTANTS is what makes the two
 * encodings agree; a stamp that doesn't parse on either side falls back to
 * string equality rather than claiming a match.
 *
 * @param a - One stored start date (a derived row's).
 * @param b - The other (its candidate board's).
 * @returns True when both name the same instant (or the same literal string).
 */
function sameWindowStart(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return a === b;
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  if (Number.isNaN(ta) || Number.isNaN(tb)) return a === b;
  return ta === tb;
}

/**
 * Was this row MINTED FOR `board` — i.e. is it this board's own per-window
 * artifact rather than some other board's row that merely passed through?
 *
 * The gate that makes the tombstoned-placement widening below safe. A stale
 * `board_tasks` row proves only that a task once sat here; it says nothing
 * about whose artifact the task is, and a derived row's whole identity is the
 * board it was minted for.
 *
 *   - **Derived counter** — exact: its id IS `derivedTaskId(boardId, root)`,
 *     so the check is a pure recomputation with no stored provenance needed.
 *   - **Derived compound** — approximate, because `derivedCompoundId` keys off
 *     the SOURCE compound's id, which the row does not record. We qualify it
 *     instead by window identity (same `startDate` + `timeframe` as the board)
 *     plus a link-shaped corroboration: either it has a child that IS this
 *     board's derived counter (the One-square signature — conclusive), or it
 *     has children at all and no other live board still places it. Exact
 *     provenance arrives in B3; until then this errs toward NOT retiring a
 *     compound that any other live board is still using.
 *
 * @param task - The candidate row.
 * @param board - The board being deleted (its window is the comparison).
 * @returns True when the row belongs to this board's window.
 */
async function isMintedForBoard(task: Task, board: Board): Promise<boolean> {
  if (isWindowStampedDerived(task)) {
    return task.sharedCounterId != null && task.id === derivedTaskId(board.id, task.sharedCounterId);
  }
  if (!isWindowStampedDerivedCompound(task)) return false;
  if (!sameWindowStart(task.startDate, board.startDate) || task.timeframe !== board.timeframe) {
    return false;
  }
  // Live-or-tombstoned links: the compound's own retirement tombstones them,
  // and a re-entrant sweep must still recognise its own handiwork.
  const links = await db.compoundChildren.where('compoundTaskId').equals(task.id).toArray();
  if (links.length === 0) return false;
  for (const link of links) {
    const child = await db.tasks.get(link.childTaskId);
    if (
      child &&
      isWindowStampedDerived(child) &&
      child.sharedCounterId != null &&
      child.id === derivedTaskId(board.id, child.sharedCounterId)
    ) {
      return true;
    }
  }
  return !(await hasLivePlacementElsewhere(task.id, board.id));
}

/**
 * The window-stamped derived rows a board's deletion orphans.
 *
 * A "live placement" is a `board_tasks` row with `isDeleted === false` whose
 * board is itself live — so a derived row placed on another live board
 * SURVIVES `boardId`'s deletion, while one whose only other placement sits on
 * an already-tombstoned board does not. Call this AFTER the board row is
 * tombstoned: `boardId` is then excluded by the live-board rule anyway, and
 * the explicit id check keeps the helper correct if a caller reverses that.
 *
 * **Ordering** — candidates come from EVERY `board_tasks` row of this board,
 * the tombstoned ones included, exactly so the answer cannot depend on when
 * the caller runs relative to any placement tombstoning. `deleteBoard` does
 * not tombstone its own placements; were it to start, a live-only candidate
 * query would find nothing and silently retire nothing — a no-op no test
 * would catch.
 *
 * That widening is only safe because a stale placement alone no longer makes
 * a candidate: {@link isMintedForBoard} additionally requires the row to be
 * THIS board's own artifact. So a derived counter minted for board B that was
 * swapped out of B (Board Edit) and placed nowhere else live still dies with
 * B — its id encodes B and it can never legitimately belong to another board
 * — while a row minted for a DIFFERENT board that merely left a tombstoned
 * placement behind here is untouched.
 *
 * Two kinds of orphan come back:
 *   1. **Placed** derived rows — counters and per-window derived compounds.
 *   2. **Parts of a derived compound being retired** — a derived counter
 *      minted as a child of a One-square derived compound has no placement of
 *      its own, so it is unreachable from `board_tasks`. Left behind it would
 *      be a per-window row with no board, still collecting
 *      {@link refreshDerivedBaselines} writes forever — and the root-delete
 *      path DOES retire it, so skipping it here would leave the two deletion
 *      paths disagreeing. A part qualifies only when its parent is itself
 *      being retired, it has no live placement of its own, and no OTHER live
 *      parent link
 *      outside the retired set still holds it.
 *
 * Reads only — the caller feeds the result to
 * {@link softDeleteWindowStampedDerived} inside its own transaction.
 *
 * @param boardId - The board being deleted.
 * @returns The ids of the window-stamped derived tasks left with no live
 *   placement anywhere.
 */
export async function windowStampedDerivedOrphanedByBoard(boardId: string): Promise<string[]> {
  const board = await db.boards.get(boardId);
  if (!board) return [];
  const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
  const candidateIds = [...new Set(placed.map((bt) => bt.taskId))];
  if (candidateIds.length === 0) return [];
  const rows = (await db.tasks.where('id').anyOf(candidateIds).toArray()).filter(
    (t) => !t.isDeleted,
  );
  const candidates: Task[] = [];
  for (const row of rows) {
    if (await isMintedForBoard(row, board)) candidates.push(row);
  }

  const orphaned: string[] = [];
  for (const task of candidates) {
    if (!(await hasLivePlacementElsewhere(task.id, boardId))) orphaned.push(task.id);
  }

  // Only the compounds actually being retired take their parts with them —
  // one kept alive by another live board keeps its parts too.
  const orphanedSet = new Set(orphaned);
  const retiredCompoundIds = candidates
    .filter((t) => orphanedSet.has(t.id) && isWindowStampedDerivedCompound(t))
    .map((t) => t.id);
  if (retiredCompoundIds.length === 0) return orphaned;

  const retiredCompoundSet = new Set(retiredCompoundIds);
  const partIds = new Set<string>();
  const links = await db.compoundChildren
    .where('compoundTaskId')
    .anyOf(retiredCompoundIds)
    .filter((c) => !c.isDeleted)
    .toArray();
  for (const link of links) {
    if (!orphanedSet.has(link.childTaskId)) partIds.add(link.childTaskId);
  }
  if (partIds.size === 0) return orphaned;

  // A part that is the user's own task (an original child a One-square
  // compound re-targeted) has no window stamp and is never returned — nor is
  // one minted for a different board, by the same `isMintedForBoard` rule the
  // placed candidates pass (a genuine part's id is `derivedTaskId(boardId,
  // its root)`, since the planner mints parent and parts in one pass).
  const partRows = (await db.tasks.where('id').anyOf([...partIds]).toArray()).filter(
    (t) => !t.isDeleted && isWindowStampedDerived(t),
  );
  const parts: Task[] = [];
  for (const row of partRows) {
    if (await isMintedForBoard(row, board)) parts.push(row);
  }
  for (const part of parts) {
    if (await hasLivePlacementElsewhere(part.id, boardId)) continue;
    const otherParents = await db.compoundChildren
      .where('childTaskId')
      .equals(part.id)
      .filter((c) => !c.isDeleted && !retiredCompoundSet.has(c.compoundTaskId))
      .toArray();
    if (otherParents.length > 0) continue;
    orphaned.push(part.id);
  }
  return orphaned;
}

/**
 * Retire per-window derived rows: tombstone each task, its live placements
 * and its live compound links, every one of them an authored delete.
 *
 * Authored means `version + 1` AND its own sync-queue DELETE on every row
 * touched — a soft-delete helper that skips the enqueue leaves the tombstone
 * local-only and the row RESURRECTS on the next pull (the defect
 * `deleteBoard`'s missing enqueue caused on iOS; see also
 * docs/BOARD_INTEGRITY.md PR-1 for why the version bump is what wins the LWW
 * tie-break against a concurrently-edited remote copy).
 *
 * Link handling is symmetric on purpose: rows where the task is the CHILD (a
 * derived counter that is a part of a derived compound) and rows where it is
 * the PARENT (a derived compound's own child links) both go. The child TASKS
 * are left alone — a part that is itself a derived counter is retired by its
 * own entry in `taskIds` (both callers supply it:
 * {@link windowStampedDerivedIdsForRoot} reaches it through its root's
 * `sharedCounterId`, {@link windowStampedDerivedOrphanedByBoard} through its
 * retired parent), and anything else is the user's library content.
 *
 * Idempotent: a missing or already-tombstoned id writes nothing and is not
 * counted, so a second sweep over the same ids (a root delete that follows a
 * board delete, say) is a true no-op.
 *
 * Runs INSIDE the caller's open transaction, which must scope `tasks`,
 * `boardTasks`, `compoundChildren` and `syncQueue`.
 *
 * @param taskIds - The window-stamped derived rows to retire.
 * @param now - The caller's shared write instant.
 * @returns How many tasks were actually tombstoned.
 */
export async function softDeleteWindowStampedDerived(
  taskIds: string[],
  now: string,
): Promise<number> {
  let deleted = 0;
  for (const id of taskIds) {
    const task = await db.tasks.get(id);
    if (!task || task.isDeleted) continue;

    const placements = await db.boardTasks
      .where('taskId')
      .equals(id)
      .filter((bt) => !bt.isDeleted)
      .toArray();
    for (const bt of placements) {
      const tombstoned = buildBoardTaskTombstone(bt, now);
      await db.boardTasks.update(bt.id, tombstoned);
      await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, tombstoned);
    }

    // Two INDEXED reads merged by link id (both columns are indexed — see
    // `database.ts`), not one full-table `.filter` scan: this runs once per
    // retired row, and the Swift twin will copy whatever shape it finds here.
    const byId = new Map<string, CompoundChild>();
    for (const column of ['childTaskId', 'compoundTaskId'] as const) {
      const rows = await db.compoundChildren
        .where(column)
        .equals(id)
        .filter((c) => !c.isDeleted)
        .toArray();
      for (const link of rows) byId.set(link.id, link);
    }
    for (const link of byId.values()) {
      const tombstoned: CompoundChild = {
        ...link,
        isDeleted: true,
        deletedAt: now,
        updatedAt: now,
        version: (link.version ?? 0) + 1,
      };
      await db.compoundChildren.put(tombstoned);
      await addToSyncQueue('compoundChildren', link.id, SyncOperationType.DELETE, tombstoned);
    }

    const tombstonedTask: Task = {
      ...task,
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (task.version ?? 0) + 1,
    };
    await db.tasks.put(tombstonedTask);
    await addToSyncQueue('tasks', id, SyncOperationType.DELETE, tombstonedTask);
    deleted += 1;
  }
  return deleted;
}
