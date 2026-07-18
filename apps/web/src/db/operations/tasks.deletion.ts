import { db } from '../internal';
import type {
  Board,
  CompoundChild,
  Task,
} from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Soft delete a task.
 *
 * Increments `version` so LWW conflict resolution treats the deletion as
 * a later-wins operation against any concurrent update on another device.
 * A soft delete without a version bump could be overwritten by a stale
 * edit that happens to have a newer `updatedAt` timestamp.
 */
export async function deleteTask(id: string): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;
  await db.tasks.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const task = await db.tasks.get(id);
  if (task) await addToSyncQueue('tasks', id, SyncOperationType.DELETE, task);
}
/**
 * Summary of what `deleteTaskWithCascade` (or a dry-run) would remove.
 * Lets the UI surface affected counts in a confirm dialog before the
 * user commits.
 */
export interface TaskDeletionImpact {
  /** Count of `BoardTask` rows that reference this task as a placement. */
  boardTaskCount: number;
  /** Count of distinct boards the placements span (cells on the same
   *  board count once). */
  affectedBoardIds: string[];
  /** The live (non-deleted) board records the placements live on. Same
   *  set as `affectedBoardIds` — the rows are included so the confirm
   *  dialog can surface board name + status without a second fetch. */
  affectedBoards: Board[];
  /** Count of `CompoundChild` rows where the task is the CHILD. The
   *  parent compound loses this child; sibling children remain. */
  childLinkCount: number;
  /** Count of `CompoundChild` rows where the task IS the parent
   *  compound. Each parent link is severed; the child Tasks remain. */
  parentLinkCount: number;
  /** P5 — count of live tasks whose `sharedCounterId` points at this task
   *  (i.e. this task is a counter source). 0 for any non-source task. */
  counterMemberCount: number;
  /** P5 — the live counter-member Task rows themselves, so the confirm
   *  dialog can name them without a second fetch. `[]` for non-sources. */
  counterMembers: Task[];
}
/**
 * Compute the cascade impact for a candidate deletion. Pure read; does
 * not mutate anything. Designed to feed the confirm dialog so the user
 * sees what's about to happen.
 */
export async function computeTaskDeletionImpact(
  id: string,
): Promise<TaskDeletionImpact> {
  const allPlacements = await db.boardTasks.where('taskId').equals(id).toArray();
  // Filter to placements on non-deleted boards. `BoardTask` has no
  // `isDeleted` column (deletes are hard) so an orphan placement on a
  // soft-deleted board persists in the table forever — those rows
  // shouldn't inflate the user-facing impact count. The actual cascade
  // still hard-deletes ALL matching `BoardTask` rows (storage cleanup),
  // but the dialog only reports on cells the user can still see.
  const boardIdsAll = Array.from(new Set(allPlacements.map((bt) => bt.boardId)));
  const liveBoards =
    boardIdsAll.length === 0
      ? []
      : await db.boards
          .where('id')
          .anyOf(boardIdsAll)
          .filter((b) => !b.isDeleted)
          .toArray();
  const liveBoardIdSet = new Set(liveBoards.map((b) => b.id));
  const visiblePlacements = allPlacements.filter((bt) =>
    liveBoardIdSet.has(bt.boardId),
  );
  const childLinks = await db.compoundChildren
    .filter((c: CompoundChild) => !c.isDeleted && c.childTaskId === id)
    .toArray();
  const parentLinks = await db.compoundChildren
    .filter((c: CompoundChild) => !c.isDeleted && c.compoundTaskId === id)
    .toArray();
  // P5 — live tasks whose sharedCounterId points at this task (i.e. this
  // task is a counter source). 0/[] for any non-source task.
  const counterMembers = await db.tasks
    .where('sharedCounterId').equals(id)
    .filter((t) => !t.isDeleted).toArray();
  return {
    boardTaskCount: visiblePlacements.length,
    affectedBoardIds: Array.from(liveBoardIdSet),
    affectedBoards: liveBoards,
    childLinkCount: childLinks.length,
    parentLinkCount: parentLinks.length,
    counterMemberCount: counterMembers.length,
    counterMembers,
  };
}
/**
 * Cascade-delete a task. Performs three operations atomically in one
 * Dexie transaction so a partial cascade can't leave the database in a
 * half-deleted state:
 *
 * 1. **BoardTask placements** referencing this task — *hard-deleted*.
 *    `BoardTask` has no `isDeleted` field (`deleteBoardTasksForBoard`
 *    uses the same hard-delete pattern when a draft is re-saved). Each
 *    removal also gets a sync-queue DELETE so other devices drop the
 *    placement on their next pull.
 * 2. **`CompoundChild` rows where the task IS the parent compound** —
 *    soft-deleted (version bump + isDeleted=true + deletedAt). The
 *    child Tasks themselves stay alive — they may still be useful as
 *    standalone library entries.
 * 3. **`CompoundChild` rows where the task IS a child** — soft-
 *    deleted. The parent compound loses this child; sibling links and
 *    the parent Task itself are untouched.
 * 4. **The Task itself** — soft-deleted (version bump + isDeleted=true
 *    + deletedAt), matching `deleteTask`'s LWW semantics.
 *
 * All sync-queue entries are enqueued inside the same transaction so a
 * crash mid-cascade leaves the queue consistent with the local-DB
 * state.
 *
 * **Achievement tasks** that reference a *board* or *template* are NOT
 * affected by this cascade — those refs are board/template IDs, not
 * task IDs. The reverse cascade (deleting a referenced board) is a
 * separate concern handled elsewhere.
 */
export async function deleteTaskWithCascade(id: string): Promise<void> {
  await db.transaction(
    'rw',
    [db.tasks, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      await deleteTaskWithCascadeInTxn(id, currentTimestamp());
    },
  );
}

/**
 * In-transaction body of `deleteTaskWithCascade` (code-motion extraction,
 * P5 PR-2 — `deleteCounterWithUnlink` needs to run the cascade inside its
 * own wider transaction, which also covers `taskEvents`). Identical
 * behavior to the original inline body; the only difference is the caller
 * supplies the ambient transaction and the shared `now` timestamp instead
 * of this function opening its own.
 *
 * Callers MUST already be inside a `db.transaction('rw', [...])` that
 * covers at least `[tasks, boardTasks, compoundChildren, syncQueue]` (a
 * superset of that list is fine — `deleteCounterWithUnlink`'s transaction
 * also covers `taskEvents`).
 *
 * @param id - The task to cascade-delete.
 * @param now - The write timestamp shared with the caller's other writes
 *   in the same transaction (so all rows agree on one instant).
 */
export async function deleteTaskWithCascadeInTxn(id: string, now: string): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;

  // 1. Hard-delete BoardTask placements.
  const placements = await db.boardTasks.where('taskId').equals(id).toArray();
  for (const bt of placements) {
    await db.boardTasks.delete(bt.id);
    await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, bt);
  }

  // 2 + 3. Soft-delete compound-child links — both as-parent and
  //        as-child. Same loop, different filter.
  const linkPredicate = (c: CompoundChild) =>
    !c.isDeleted && (c.compoundTaskId === id || c.childTaskId === id);
  const linksToDelete = await db.compoundChildren.filter(linkPredicate).toArray();
  for (const link of linksToDelete) {
    const patch: Partial<CompoundChild> = {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (link.version ?? 0) + 1,
    };
    await db.compoundChildren.update(link.id, patch);
    const updated = await db.compoundChildren.get(link.id);
    if (updated) {
      await addToSyncQueue(
        'compoundChildren',
        link.id,
        SyncOperationType.DELETE,
        updated,
      );
    }
  }

  // 4. Soft-delete the Task itself.
  await db.tasks.update(id, {
    isDeleted: true,
    deletedAt: now,
    updatedAt: now,
    version: (existing.version ?? 0) + 1,
  });
  const updatedTask = await db.tasks.get(id);
  if (updatedTask) {
    await addToSyncQueue('tasks', id, SyncOperationType.DELETE, updatedTask);
  }
}
