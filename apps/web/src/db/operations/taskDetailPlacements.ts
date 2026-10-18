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
  /** The tasks the rows read (members, their ancestors and sub-trees, counter roots) by id. */
  taskById: Record<string, Task>;
  /** Live compound links by compound id, nested compounds included. */
  childrenByCompound: Record<string, CompoundChild[]>;
  /** Live events of every task in `taskById`. */
  events: TaskEvent[];
}

/** Group `xs` by `key`. */
function group<X>(xs: ReadonlyArray<X>, key: (x: X) => string): Record<string, X[]> {
  const out: Record<string, X[]> = {};
  for (const x of xs) (out[key(x)] ??= []).push(x);
  return out;
}

/** Every id reachable from `seeds` through `edges` (the seeds included). */
function closure(seeds: Iterable<string>, edges: Readonly<Record<string, string[]>>): Set<string> {
  const out = new Set(seeds);
  const queue = [...out];
  while (queue.length > 0) {
    const id = queue.shift() as string;
    for (const next of edges[id] ?? []) if (!out.has(next)) { out.add(next); queue.push(next); }
  }
  return out;
}

/**
 * Resolve where a task lives on boards: its placement REACH (the one the
 * cascade and the hub use — own placements, a counter root's linked rows',
 * every containing compound's), each board's row scored by
 * `taskPlacementRows` over that board's window. iOS twin:
 * `AppDatabase.fetchTaskDetailPlacements`.
 *
 * Reads are KEYED to what the reach can touch (the task's linked rows by
 * index, their ancestor and descendant compounds, those tasks' placements and
 * events), so the live query re-runs on a write to those rows — not on every
 * write anywhere in the workspace. Only `compoundChildren` is read whole (the
 * link graph is needed to walk ancestors; it changes only on structure edits),
 * plus a watched board's cells when an achievement is in the reach.
 *
 * @param taskId - The task whose detail page this is.
 * @returns The placement read.
 */
export async function loadTaskDetailPlacements(taskId: string): Promise<TaskDetailPlacements> {
  return db.transaction('r', [db.tasks, db.compoundChildren, db.boardTasks, db.boards, db.taskEvents], async () => {
    const links = await db.compoundChildren.filter((c) => !c.isDeleted).toArray();
    const childrenByCompound = group(links, (l) => l.compoundTaskId);
    const parentsByChild: Record<string, string[]> = {};
    const childIdsByCompound: Record<string, string[]> = {};
    for (const l of links) {
      (parentsByChild[l.childTaskId] ??= []).push(l.compoundTaskId);
      (childIdsByCompound[l.compoundTaskId] ??= []).push(l.childTaskId);
    }

    // Members: the task and its live linked rows (a counter root is never placed itself).
    const linked = await db.tasks.where('sharedCounterId').equals(taskId).toArray();
    const members = [taskId, ...linked.filter((t) => !t.isDeleted).map((t) => t.id)];
    const ancestors = closure(members, parentsByChild);
    const subtree = closure(members, childIdsByCompound);

    const taskById: Record<string, Task> = {};
    const loadTasks = async (ids: Iterable<string>): Promise<void> => {
      const missing = [...new Set(ids)].filter((id) => !(id in taskById));
      if (missing.length === 0) return;
      for (const t of await db.tasks.bulkGet(missing)) if (t) taskById[t.id] = t;
    };
    await loadTasks([...ancestors, ...subtree]);

    const boardTasks = (await db.boardTasks.where('taskId').anyOf([...ancestors]).toArray()).filter((bt) => !bt.isDeleted);
    const reach = placementsReachedByTasks([taskId], { tasks: Object.values(taskById), compoundChildren: links, boardTasks });
    const reachedBoards = reach.boardIds.size === 0 ? [] : await db.boards.where('id').anyOf([...reach.boardIds]).toArray();
    const live = reachedBoards.filter((b) => !b.isDeleted);

    // An achievement's value is its cell in its board's grid: that board's
    // cells (and their sub-trees) and every board it may watch.
    let boardTasksByBoard: Record<string, BoardTask[]> = {};
    let allBoards: Board[] = live;
    const watcherBoards = [...new Set(reach.placements
      .filter((p) => taskById[p.memberTaskId]?.type === TaskType.ACHIEVEMENT)
      .map((p) => p.boardTask.boardId))];
    if (watcherBoards.length > 0) {
      const cells = (await db.boardTasks.where('boardId').anyOf(watcherBoards).toArray()).filter((bt) => !bt.isDeleted);
      boardTasksByBoard = group(cells, (bt) => bt.boardId);
      await loadTasks(closure(cells.map((bt) => bt.taskId), childIdsByCompound));
      allBoards = (await db.boards.toArray()).filter((b) => !b.isDeleted);
    }

    // A linked task reads its counter root's events.
    await loadTasks(Object.values(taskById).flatMap((t) => (t.sharedCounterId ? [t.sharedCounterId] : [])));
    const events = (await db.taskEvents.where('taskId').anyOf(Object.keys(taskById)).toArray()).filter((e) => !e.isDeleted);

    const rows = taskPlacementRows({
      taskId,
      reach: reach.placements,
      boardsById: Object.fromEntries(live.map((b) => [b.id, b])),
      taskById,
      childrenByCompound,
      eventsByTaskId: group(events, (e) => e.taskId),
      boardTasksByBoard,
      allBoards,
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
