import type { Board } from '../types/board';
import type { Task } from '../types/task';
import { TaskType } from '../constants/enums';

/**
 * achievementWatchers.ts — which ACHIEVEMENT tasks watch a set of boards whose
 * persisted stats just changed (Board Edit redesign slice 4, D8 / owner ruling
 * R3). Pure: the platform `refreshWatchersForBoards` helpers call this, then
 * re-derive the boards that place the returned watcher tasks, iterating to a
 * fixpoint over newly changed boards (the DB layer owns the iteration; this
 * function is one hop, no transitivity).
 *
 * An achievement watches either one specific board (`referencedBoardId`) or
 * every spawn of a recurring template (`referencedTemplateId`, matched through
 * the changed boards' `spawnedFromTemplateId`). The kernel reads the watched
 * board's persisted `status` / `linesCompleted`, so a Close, Reopen or late log
 * that changes those must refresh every watcher.
 */

/** The Task fields {@link findWatcherTaskIds} reads. */
export type WatcherTaskFields = Pick<
  Task,
  'id' | 'type' | 'isDeleted' | 'referencedBoardId' | 'referencedTemplateId'
>;

/** The Board fields {@link findWatcherTaskIds} reads. */
export type WatchedBoardFields = Pick<Board, 'id' | 'spawnedFromTemplateId'>;

/**
 * The ids of the non-deleted ACHIEVEMENT tasks that watch any of
 * `changedBoards` — `referencedBoardId` is one of their ids, or
 * `referencedTemplateId` is one of their `spawnedFromTemplateId`s.
 *
 * @param tasks         Candidate tasks (may be unfiltered).
 * @param changedBoards Boards whose persisted stats changed.
 * @returns Watcher task ids in `tasks` order, de-duplicated.
 */
export function findWatcherTaskIds(
  tasks: ReadonlyArray<WatcherTaskFields>,
  changedBoards: ReadonlyArray<WatchedBoardFields>,
): string[] {
  if (changedBoards.length === 0) return [];
  const boardIds = new Set(changedBoards.map((b) => b.id));
  const templateIds = new Set(
    changedBoards
      .map((b) => b.spawnedFromTemplateId)
      .filter((t): t is string => t != null),
  );

  const seen = new Set<string>();
  const out: string[] = [];
  for (const task of tasks) {
    if (task.type !== TaskType.ACHIEVEMENT || task.isDeleted) continue;
    const watchesBoard = task.referencedBoardId != null && boardIds.has(task.referencedBoardId);
    const watchesTemplate =
      task.referencedTemplateId != null && templateIds.has(task.referencedTemplateId);
    if (!watchesBoard && !watchesTemplate) continue;
    if (seen.has(task.id)) continue;
    seen.add(task.id);
    out.push(task.id);
  }
  return out;
}
