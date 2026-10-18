import { db } from '../internal';
import {
  TaskType,
  placementsReachedByTasks,
  taskPlacementRows,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
  type TaskPlacementRow,
} from '@oybc/shared';

/** Task Detail's placement read (docs/TASK_DETAIL_REDESIGN.md PR 5). */
export interface TaskDetailPlacements {
  /** The task's OWN live placements — the hero anchor and the "Placed on" Activity rows. */
  ownPlacements: BoardTask[];
  /** Every live board the task reaches (own, a linked row's, a parent compound's). */
  boards: Board[];
  /** One row per reached board, read through the board grid's resolvers. */
  rows: TaskPlacementRow[];
  /** Workspace tasks by id (members and their counter roots, for formatting). */
  taskById: Record<string, Task>;
  /** Live compound links by compound id, nested compounds included. */
  childrenByCompound: Record<string, CompoundChild[]>;
  /** Every live event in the workspace (a nested sub-task's included). */
  events: TaskEvent[];
}

/**
 * Resolve where a task lives on boards: its placement REACH (the one the
 * cascade and the hub use — own placements, a counter root's linked rows',
 * every containing compound's), each board's row scored by
 * `taskPlacementRows` over that board's window. One read transaction, so the
 * rows, the boards and the anchor placements agree. iOS twin:
 * `AppDatabase.fetchTaskDetailPlacements`.
 *
 * @param taskId - The task whose detail page this is.
 * @returns The placement read.
 */
export async function loadTaskDetailPlacements(taskId: string): Promise<TaskDetailPlacements> {
  return db.transaction('r', [db.tasks, db.compoundChildren, db.boardTasks, db.boards, db.taskEvents], async () => {
    const [tasks, links, boardTasks] = await Promise.all([
      db.tasks.toArray(),
      db.compoundChildren.filter((c) => !c.isDeleted).toArray(),
      db.boardTasks.filter((bt) => !bt.isDeleted).toArray(),
    ]);
    const reach = placementsReachedByTasks([taskId], { tasks, compoundChildren: links, boardTasks });
    const boardIds = [...reach.boardIds];
    const reachedBoards = boardIds.length === 0 ? [] : await db.boards.where('id').anyOf(boardIds).toArray();
    const allBoards = reach.placements.some((p) => tasks.find((t) => t.id === p.memberTaskId)?.type === TaskType.ACHIEVEMENT)
      ? await db.boards.toArray()
      : reachedBoards;
    const events = (await db.taskEvents.toArray()).filter((e) => !e.isDeleted);

    const taskById: Record<string, Task> = {};
    for (const t of tasks) taskById[t.id] = t;
    const group = <X,>(xs: X[], key: (x: X) => string): Record<string, X[]> => {
      const out: Record<string, X[]> = {};
      for (const x of xs) (out[key(x)] ??= []).push(x);
      return out;
    };
    const childrenByCompound: Record<string, CompoundChild[]> = group(links, (l) => l.compoundTaskId);
    const eventsByTaskId: Record<string, TaskEvent[]> = group(events, (e) => e.taskId);
    const live = reachedBoards.filter((b) => !b.isDeleted);
    const rows = taskPlacementRows({
      taskId,
      reach: reach.placements,
      boardsById: Object.fromEntries(live.map((b) => [b.id, b])),
      taskById,
      childrenByCompound,
      eventsByTaskId,
      boardTasksByBoard: group(boardTasks.filter((bt) => reach.boardIds.has(bt.boardId)), (bt) => bt.boardId),
      allBoards: allBoards.filter((b) => !b.isDeleted),
    });
    return {
      ownPlacements: boardTasks.filter((bt) => bt.taskId === taskId),
      boards: live,
      rows,
      taskById,
      childrenByCompound,
      events,
    };
  });
}
