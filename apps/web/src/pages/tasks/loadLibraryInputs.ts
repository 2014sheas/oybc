import {
  TaskType,
  computeBrowsableTasks,
  type BoardStatus,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import {
  fetchAllBoards,
  fetchAllBoardTasks,
  fetchAllCompoundChildren,
  fetchTasksForUser,
} from '../../db/operations';

/**
 * Loads the sub-task quick-add row's inputs for `userId`: the browsable
 * library (`computeBrowsableTasks` — hides wizard drafts, goal-less hub
 * counters and deleted rows, exactly like the Tasks tab) and every live
 * compound link under one of the user's compounds (the loop check's graph;
 * scoped like `useTaskLibrary` so another account's rows on this device
 * never leak in).
 *
 * @param userId - The signed-in user.
 * @returns The library tasks and live links.
 */
export async function loadLibraryInputs(
  userId: string,
): Promise<{ libraryTasks: Task[]; allLinks: CompoundChild[] }> {
  const [tasks, links, boards, boardTasks] = await Promise.all([
    fetchTasksForUser(userId),
    fetchAllCompoundChildren(),
    fetchAllBoards(),
    fetchAllBoardTasks(),
  ]);
  const compoundIds = new Set(tasks.filter((t) => t.type === TaskType.COMPOUND).map((t) => t.id));
  const allLinks = links.filter((l) => compoundIds.has(l.compoundTaskId));
  const boardStatusById: Record<string, BoardStatus> = {};
  for (const b of boards) boardStatusById[b.id] = b.status;
  const childToParents: Record<string, string[]> = {};
  for (const l of allLinks) (childToParents[l.childTaskId] ??= []).push(l.compoundTaskId);
  return {
    libraryTasks: computeBrowsableTasks(tasks, boardTasks, boardStatusById, childToParents),
    allLinks,
  };
}
