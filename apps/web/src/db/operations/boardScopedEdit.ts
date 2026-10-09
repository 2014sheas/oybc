/**
 * Board-scoped task edits — the commit half (PR 2 of the train in
 * docs/BOARD_SCOPED_TASK_EDITS.md). An edit made from a board (Board Edit's
 * square sheet, the board wizard's inline row edit) must affect the task on
 * THAT board only: when the task is placed on any other board, the edit lands
 * on a deterministic **fork** that replaces the original on this board.
 *
 * {@link ensureBoardScopedTask} is the one entry point both commit paths call
 * BEFORE applying their edit: it runs the shared pure planner
 * (`planBoardScopedFork`) against the SAME transaction's rows and, for a
 * fork, writes everything the plan calls for:
 *
 *   1. the fork row, its in-window event copies and (for a compound) its
 *      copied child links — each enqueued as a CREATE; an already-present row
 *      (a replayed commit, or another device's identical fork pulled in) is
 *      kept, so replay converges on the same rows (§7);
 *   2. the direct placement on this board repointed at the fork through
 *      `updateBoardTaskAndCascade` (version bump + enqueue + cascade, exactly
 *      like a Replace);
 *   3. every compound placed on this board that contains the task (the
 *      plan's `onBoardHolderCompoundIds`): the holder is made board-private
 *      FIRST (forked itself when it is placed elsewhere — its own placement
 *      repointed, its links copied), then the link to the task inside the
 *      holder's subtree is rewritten to the fork (intermediate compounds on
 *      the path are made board-private the same way);
 *   4. one batched cascade over the fork and the original (sealed boards are
 *      skipped by the cascade itself).
 *
 * The caller then applies its edit to the returned id and calls
 * {@link stampForkCaches} so the fork's lifetime caches are derived from its
 * own events AFTER the edit (they depend on the post-edit type / goal).
 *
 * REQUIRES an active Dexie transaction over `boards`, `boardTasks`, `tasks`,
 * `compoundChildren`, `taskEvents` and `syncQueue`.
 *
 * iOS twin: `AppDatabase+BoardScopedEdit.swift`.
 */
import {
  SyncOperationType,
  findTransitiveParentCompounds,
  planBoardScopedFork,
  wouldForkOnBoard,
  type Board,
  type BoardTask,
  type CompoundChild,
  type TaskType,
} from '@oybc/shared';
import { db } from '../internal';
import { updateBoardTaskAndCascade } from './boardTasks';
import { runBoardCascadeForTasks } from './orchestration';
import { addToSyncQueue } from './syncQueue';
import { stampTaskCachesAuthored } from './taskEvents';

/** Outcome of {@link ensureBoardScopedTask}. */
export interface BoardScopedTarget {
  /** The id the edit must land on — the task itself, or its fork. */
  targetId: string;
  /** Whether a fork was planned (the caller stamps its caches after editing). */
  forked: boolean;
}

/** Every live `compound_children` row (reachability + subtree walks). */
async function liveLinks(): Promise<CompoundChild[]> {
  return (await db.compoundChildren.toArray()).filter((l) => !l.isDeleted);
}

/** The placement-side inputs of the fork test for one task. */
interface PlacementContext {
  placements: BoardTask[];
  boards: Board[];
  compoundChildren: CompoundChild[];
}

/**
 * Read the rows the §2 test needs for `taskId`: every `compound_children`
 * row, the placements of the task and of its (transitive) parent compounds,
 * and those placements' boards.
 *
 * @param taskId - The task under test.
 * @returns The placement context.
 */
async function readPlacementContext(taskId: string): Promise<PlacementContext> {
  const compoundChildren = await db.compoundChildren.toArray();
  const reach = findTransitiveParentCompounds(taskId, compoundChildren);
  reach.add(taskId);
  const placements = await db.boardTasks.where('taskId').anyOf([...reach]).toArray();
  const boardIds = [...new Set(placements.map((p) => p.boardId))];
  const boards = boardIds.length > 0 ? await db.boards.where('id').anyOf(boardIds).toArray() : [];
  return { placements, boards, compoundChildren };
}

/**
 * Whether a Board Edit of `taskId` from `boardId` would land on a fork —
 * drives the square sheet's "Save for this board" label and first-fork
 * confirm from the same `wouldForkOnBoard` test the Save's planner runs.
 * Read-only. A task not stored yet (a staged new task) never forks.
 *
 * @param taskId - The task the sheet edits.
 * @param boardId - The board being edited.
 * @returns `true` when the Save would fork the task.
 */
export async function fetchWouldForkOnBoard(taskId: string, boardId: string): Promise<boolean> {
  return db.transaction('r', [db.tasks, db.boards, db.boardTasks, db.compoundChildren], async () => {
    const task = await db.tasks.get(taskId);
    if (!task || task.isDeleted) return false;
    return wouldForkOnBoard({ task, boardId, ...(await readPlacementContext(taskId)) });
  });
}

/**
 * Make `taskId` private to `boardId` ahead of a board-scoped edit, forking it
 * when it is placed on any other board (see the module doc for every write).
 *
 * @param taskId - The task the board edit targets (pre-edit).
 * @param boardId - The board the edit is made from.
 * @param editedType - The task's type AFTER the edit (selects migrated events).
 * @param now - ISO8601 stamp for every minted row.
 * @returns The id to edit, and whether it is a fork.
 */
export async function ensureBoardScopedTask(
  taskId: string,
  boardId: string,
  editedType: TaskType,
  now: string,
): Promise<BoardScopedTarget> {
  const task = await db.tasks.get(taskId);
  const board = await db.boards.get(boardId);
  if (!task || task.isDeleted || !board) return { targetId: taskId, forked: false };

  const { placements, boards, compoundChildren } = await readPlacementContext(taskId);
  const events = await db.taskEvents.where('taskId').equals(taskId).toArray();

  const plan = planBoardScopedFork({
    task, board, editedType, placements, boards, compoundChildren, events, now,
  });
  if (plan.mode === 'inPlace') return { targetId: taskId, forked: false };

  const forkId = plan.fork.id;
  if (!(await db.tasks.get(forkId))) {
    await db.tasks.add(plan.fork);
    await addToSyncQueue('tasks', forkId, SyncOperationType.CREATE, plan.fork);
  }
  for (const copy of plan.eventCopies) {
    if (await db.taskEvents.get(copy.id)) continue;
    await db.taskEvents.add(copy);
    await addToSyncQueue('taskEvents', copy.id, SyncOperationType.CREATE, copy);
  }
  for (const copy of plan.childLinksToCopy) {
    if (await db.compoundChildren.get(copy.id)) continue;
    await db.compoundChildren.add(copy);
    await addToSyncQueue('compoundChildren', copy.id, SyncOperationType.CREATE, copy);
  }

  if (plan.repoint) await updateBoardTaskAndCascade(plan.repoint.boardTaskId, forkId);
  for (const holderId of plan.onBoardHolderCompoundIds) {
    await replaceInHolderSubtree(holderId, taskId, forkId, boardId, now);
  }
  await runBoardCascadeForTasks([forkId, taskId]);
  return { targetId: forkId, forked: true };
}

/**
 * Replace `oldId` with `newId` inside the subtree of compound `holderId` (a
 * compound placed on `boardId`): the holder — and every compound on the path
 * down to `oldId` — is made board-private first via
 * {@link ensureBoardScopedTask}, then the link to `oldId` is rewritten.
 *
 * @param holderId - A compound containing `oldId` (directly or transitively).
 * @param oldId - The original task.
 * @param newId - Its fork.
 * @param boardId - The board the edit is made from.
 * @param now - ISO8601 stamp.
 */
async function replaceInHolderSubtree(
  holderId: string,
  oldId: string,
  newId: string,
  boardId: string,
  now: string,
): Promise<void> {
  const holder = await db.tasks.get(holderId);
  if (!holder || holder.isDeleted) return;
  const { targetId: privateHolderId } = await ensureBoardScopedTask(holderId, boardId, holder.type, now);

  const links = (await liveLinks())
    .filter((l) => l.compoundTaskId === privateHolderId)
    .sort((a, b) => a.childIndex - b.childIndex || (a.id < b.id ? -1 : 1));
  for (const l of links) {
    if (l.childTaskId === oldId) {
      await repointCompoundLink(privateHolderId, oldId, newId, now);
      continue;
    }
    // An intermediate compound on the path to `oldId`.
    if (findTransitiveParentCompounds(oldId, await liveLinks()).has(l.childTaskId)) {
      await replaceInHolderSubtree(l.childTaskId, oldId, newId, boardId, now);
    }
  }
}

/**
 * Rewrite the live link `compoundId → oldChildId` to point at `newChildId`
 * (version bump + UPDATE enqueue). No-op when no such live link exists — e.g.
 * the holder walk already rewrote it.
 *
 * @param compoundId - The parent compound.
 * @param oldChildId - The child the link points at today.
 * @param newChildId - The child it must point at.
 * @param now - ISO8601 stamp.
 */
export async function repointCompoundLink(
  compoundId: string,
  oldChildId: string,
  newChildId: string,
  now: string,
): Promise<void> {
  const links = (await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()).filter(
    (l) => !l.isDeleted && l.childTaskId === oldChildId,
  );
  for (const l of links) {
    const updated: CompoundChild = { ...l, childTaskId: newChildId, version: l.version + 1, updatedAt: now };
    await db.compoundChildren.put(updated);
    await addToSyncQueue('compoundChildren', l.id, SyncOperationType.UPDATE, updated);
  }
}

/**
 * Stamp a fork's lifetime caches from its own (migrated) events, AFTER the
 * caller applied the edit — an authored write (version bump + enqueue), the
 * `stampTaskCachesAuthored` path. No-op for a non-event-owning fork.
 *
 * @param target - {@link ensureBoardScopedTask}'s result.
 * @param now - ISO8601 stamp.
 */
export async function stampForkCaches(target: BoardScopedTarget, now: string): Promise<void> {
  if (target.forked) await stampTaskCachesAuthored(target.targetId, now);
}
