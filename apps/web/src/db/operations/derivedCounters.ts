import type { Collection } from 'dexie';
import {
  isWindowStampedDerivedCompound,
  SyncOperationType,
  computeWindowBaseline,
  derivedTaskId,
  isWindowStampedDerived,
  sameWindowStart,
  type Board,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { buildBoardTaskTombstone } from './boardTasks';

/**
 * derivedCounters.ts — the LEGACY window-stamped derived-row upkeep
 * (docs/BOARD_SOURCES.md §Member rules → *Baseline*; retired by
 * docs/TASK_WINDOW_REWORK.md slice 5).
 *
 * Since slice 3b nothing MINTS a derived row any more: the planner emits
 * placement parameters (`planDerivedTasks` → `PlannedPlacement`) and the
 * writers put them on `board_tasks`. What remains is the upkeep of rows an
 * earlier build already minted:
 *
 *  1. **Refresh** — keep a live derived counter's `baseline` honest as the
 *     root's event log changes underneath it (local counter writes and the
 *     sync pull path), as a NON-AUTHORED write: no `version` bump, no sync
 *     enqueue.
 *  2. **Retire** — when a derived row's root is deleted, or the last live
 *     board carrying it goes away, tombstone the row with its placements and
 *     links (see the *Deletion* section at the bottom of this file).
 *
 * Every exported function here MUST be called from inside an already-open
 * Dexie transaction that scopes the tables it touches (`tasks`,
 * `compoundChildren`, `taskEvents`, `syncQueue`). None of them opens a
 * transaction of its own.
 *
 * Swift twin: `AppDatabase+DerivedCounters.swift` — the write rulings here
 * must stay identical on both platforms.
 */

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

// `sameWindowStart` (final-review M2) now lives in `@oybc/shared`
// (`linkedCounterWindowHeal.ts`, shared) so the placement gate `isWindowStampedForBoard`
// and this file's `isMintedForBoard` share one instant-compare definition.

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
      await db.boardTasks.put(tombstoned);
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
