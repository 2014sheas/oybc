import {
  SyncOperationType,
  TaskType,
  planRootFieldPropagation,
  type RootFieldEditPatch,
  type RootPropagationCopy,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTasks } from './orchestration';

/**
 * rootFieldPropagation.ts — web half of "a counter ROOT's Task Detail edit
 * reaches its live per-board copies" (docs/BOARD_SCOPED_TASK_EDITS.md §6,
 * PR 3). Swift twin: `AppDatabase+RootFieldPropagation.swift`. The rule is the
 * pure shared `planRootFieldPropagation`; this module reads its inputs and
 * writes its output inside the caller's Task Detail save transaction.
 */

/** The root + its candidate copies, read BEFORE the root edit is written. */
export interface RootPropagationSnapshot {
  root: Task;
  /** Every row with `sharedCounterId == root.id`, annotated with sealed-board placement. */
  copies: Array<Task & RootPropagationCopy>;
}

/**
 * Read what {@link propagateRootFieldsInTransaction} needs. Must run inside the
 * caller's `rw` transaction, before any write of the save.
 *
 * @param taskId - The task being edited.
 * @returns The snapshot, or null when the task is not a live counting root
 *   with copies (nothing to propagate).
 */
export async function readRootPropagationSnapshot(taskId: string): Promise<RootPropagationSnapshot | null> {
  const root = await db.tasks.get(taskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING || root.sharedCounterId != null) return null;
  const rows = await db.tasks.where('sharedCounterId').equals(root.id).toArray();
  if (rows.length === 0) return null;
  const copies = await Promise.all(
    rows.map(async (row) => ({ ...row, onSealedBoard: await isPlacedOnSealedBoard(row.id) })),
  );
  return { root, copies };
}

/**
 * Apply the planned copy writes for a root edit, then cascade the copies'
 * boards. Each changed copy gets ONE authored write: a version bump + UPDATE
 * enqueue — unless the kind switch already bumped that row in this same
 * transaction, in which case the fields join that write (no second bump; the
 * enqueue coalesces onto the switch's pending item).
 *
 * REQUIRES an active `rw` transaction over `boards`, `boardTasks`, `tasks`,
 * `compoundChildren`, `taskEvents` and `syncQueue`.
 *
 * @param snapshot - From {@link readRootPropagationSnapshot}, read before the save's writes.
 * @param patch - The root's edit.
 * @param nowIso - ISO8601 write time / freeze clock.
 * @returns The copy ids written.
 */
export async function propagateRootFieldsInTransaction(
  snapshot: RootPropagationSnapshot,
  patch: RootFieldEditPatch,
  nowIso: string,
): Promise<string[]> {
  const plan = planRootFieldPropagation(snapshot.root, patch, snapshot.copies, nowIso);
  const versionBefore = new Map(snapshot.copies.map((c) => [c.id, c.version ?? 0]));
  const written: string[] = [];
  for (const { copyId, patch: fields } of plan) {
    const current = await db.tasks.get(copyId);
    if (!current) continue;
    const alreadyAuthored = (current.version ?? 0) !== versionBefore.get(copyId);
    await db.tasks.update(copyId, {
      ...fields,
      updatedAt: nowIso,
      version: (current.version ?? 0) + (alreadyAuthored ? 0 : 1),
    });
    const saved = await db.tasks.get(copyId);
    if (!saved) throw new Error(`propagateRootFields: ${copyId} vanished mid-transaction`);
    await addToSyncQueue('tasks', copyId, SyncOperationType.UPDATE, saved, 0);
    written.push(copyId);
  }
  if (written.length > 0) await runBoardCascadeForTasks(written);
  return written;
}

/**
 * Whether `taskId` has a live placement on a live sealed board.
 *
 * @param taskId - The copy.
 * @returns True when any such placement exists.
 */
async function isPlacedOnSealedBoard(taskId: string): Promise<boolean> {
  const placements = await db.boardTasks.where('taskId').equals(taskId).filter((bt) => !bt.isDeleted).toArray();
  if (placements.length === 0) return false;
  const boards = await db.boards.bulkGet(placements.map((bt) => bt.boardId));
  return boards.some((b) => b != null && !b.isDeleted && b.sealedAt != null);
}
