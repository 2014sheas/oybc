import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType, boardDisplayName, boardWindowEnd, buildTaskActivity, compareBoardsForList, pickHeroAnchorBoard, resolveFamilyCountKind,
  type Board, type BoardTask, type CompoundChild, type RecurringBoardTemplate, type Task, type TaskActivity,
} from '@oybc/shared';
import { fetchBoardTasksForTask, fetchBoard, fetchBoardsByIds, fetchCompoundChildren, fetchTask, fetchTasksByIds } from '../db/operations';
import { fetchLiveEventsForTaskIds } from '../db/operations/lateLog';
import { fetchCompoundParentsForTask } from '../db/operations/tasks';
import { fetchRecurringBoardTemplate, fetchTemplatesReferencingTask } from '../db/operations/recurringBoardTemplates';
import { buildSquareWindowContext, resolveCompoundChildCompleted } from '../db/adapters';
import { buildBoardRows, type BoardRow } from '../pages/tasks/taskDetail/taskDetailModel';

/**
 * The boards a task is placed on — THE seam PR 5 (placement resolution) swaps:
 * today only placements of the library task's own id; PR 5 resolves linked
 * counters and sub-tasks placed through a parent. Everything below reads
 * placements only through this function.
 *
 * @param taskId - The task.
 * @returns Its live placements.
 */
export async function resolveTaskPlacements(taskId: string): Promise<BoardTask[]> {
  return fetchBoardTasksForTask(taskId);
}

/** One compound sub-task, link + task. */
export interface DetailChild {
  link: CompoundChild;
  task: Task;
}

export interface TaskDetailData {
  /** Placements + boards resolved (false while the first read is in flight). */
  placementsLoaded: boolean;
  placements: BoardTask[];
  /** Placement boards in the Boards tab's own order. */
  boards: Board[];
  /** The soonest-ending in-play board and the placement on it; undefined = no anchor ("Not on a board"). */
  anchor: { board: Board; placement: BoardTask } | undefined;
  /** Sub-task id → done in the ANCHOR's window (empty without an anchor: no tick). */
  childDone: Record<string, boolean>;
  rows: BoardRow[];
  parentCompounds: Task[];
  children: DetailChild[];
  /** The counter the task is linked to / counts toward: undefined while loading, null when absent or gone. */
  counterRoot: Task | null | undefined;
  templates: RecurringBoardTemplate[];
  /** Achievement: the watched board / template (undefined loading, null gone). */
  watchedBoard: Board | null | undefined;
  watchedTemplate: RecurringBoardTemplate | null | undefined;
  activity: TaskActivity | undefined;
}

const EMPTY: never[] = [];

/**
 * The ONE data seam behind Task Detail, shared by the route and the "Open in
 * library" sheet: placements and boards, the hero anchor, per-board rows read
 * through the board-play resolvers, compound parents / sub-tasks, the counter
 * root, repeating-board back-refs, the watched board and the derived Activity
 * feed. iOS twin: `TaskDetailViewModel`.
 *
 * @param task - The task being shown.
 * @returns The live data.
 */
export function useTaskDetail(task: Task): TaskDetailData {
  const taskId = task.id;
  const placements = useLiveQuery(() => resolveTaskPlacements(taskId), [taskId]);
  const boardIds = useMemo(() => [...new Set((placements ?? []).map((p) => p.boardId))], [placements]);
  const boardIdsKey = boardIds.join(',');
  const rawBoards = useLiveQuery(async () => (boardIds.length === 0 ? [] : fetchBoardsByIds(boardIds)), [boardIdsKey]);

  const parentCompounds = useLiveQuery(() => fetchCompoundParentsForTask(taskId), [taskId]);
  const links = useLiveQuery(
    async () => (task.type === TaskType.COMPOUND ? fetchCompoundChildren(taskId) : []),
    [taskId, task.type],
  );
  const sortedLinks = useMemo(() => [...(links ?? [])].filter((l) => !l.isDeleted).sort((a, b) => a.childIndex - b.childIndex), [links]);
  const childIdsKey = sortedLinks.map((l) => l.childTaskId).join(',');
  const childTasks = useLiveQuery(async () => (sortedLinks.length === 0 ? [] : fetchTasksByIds(sortedLinks.map((l) => l.childTaskId))), [childIdsKey]);
  // Each sub-task's own counter root joins the task map (a linked child reads its root's events).
  const rootIds = useMemo(
    () => [...new Set([task.sharedCounterId, task.countsTowardCounterId, ...(childTasks ?? []).flatMap((c) => [c.sharedCounterId, c.countsTowardCounterId])]
      .filter((id): id is string => typeof id === 'string'))],
    [task.sharedCounterId, task.countsTowardCounterId, childTasks],
  );
  const rootIdsKey = rootIds.join(',');
  const roots = useLiveQuery(async () => (rootIds.length === 0 ? [] : fetchTasksByIds(rootIds)), [rootIdsKey]);

  const eventTaskIds = useMemo(() => [taskId, ...rootIds, ...(childTasks ?? []).map((c) => c.id)], [taskId, rootIds, childTasks]);
  const eventKey = eventTaskIds.join(',');
  const events = useLiveQuery(() => fetchLiveEventsForTaskIds(eventTaskIds), [eventKey]);

  // A counter ROOT points at itself (its counter row shows too).
  const counterId = task.sharedCounterId ?? task.countsTowardCounterId ?? (task.isCounter ? task.id : null);
  const counterRaw = useLiveQuery(async () => (counterId ? (await fetchTask(counterId)) ?? null : null), [counterId]);
  const counterRoot = counterId ? (counterRaw === undefined ? undefined : counterRaw && !counterRaw.isDeleted ? counterRaw : null) : null;

  const templates = useLiveQuery(() => fetchTemplatesReferencingTask(taskId), [taskId]);
  const watchedBoardRaw = useLiveQuery(async () => (task.referencedBoardId ? (await fetchBoard(task.referencedBoardId)) ?? null : null), [task.referencedBoardId]);
  const watchedTemplateRaw = useLiveQuery(
    async () => (task.referencedTemplateId ? (await fetchRecurringBoardTemplate(task.referencedTemplateId)) ?? null : null),
    [task.referencedTemplateId],
  );

  return useMemo<TaskDetailData>(() => {
    const now = new Date();
    const boards = [...(rawBoards ?? [])].filter((b) => !b.isDeleted).sort((a, b) => compareBoardsForList(a, b, now) || (a.id < b.id ? -1 : 1));
    const anchorBoard = pickHeroAnchorBoard(boards, now);
    const anchorPlacement = anchorBoard ? (placements ?? []).find((p) => p.boardId === anchorBoard.id) : undefined;
    const children: DetailChild[] = sortedLinks.flatMap((link) => {
      const t = (childTasks ?? []).find((c) => c.id === link.childTaskId);
      return t ? [{ link, task: t }] : [];
    });
    const taskMap: Record<string, Task> = { [task.id]: task };
    for (const t of [...(roots ?? []), ...(childTasks ?? [])]) taskMap[t.id] = t;
    const childrenByCompound: Record<string, CompoundChild[]> = { [task.id]: sortedLinks };
    const anchorCtx = anchorBoard
      ? { ...buildSquareWindowContext(events ?? [], anchorBoard.startDate, boardWindowEnd(anchorBoard)), sealedAt: anchorBoard.sealedAt ?? null }
      : undefined;
    const childDone: Record<string, boolean> = {};
    if (anchorCtx) for (const c of children) childDone[c.task.id] = resolveCompoundChildCompleted(c.task, taskMap, childrenByCompound, anchorCtx);
    const rows = buildBoardRows({ task, boards, events: events ?? [], taskMap, childrenByCompound, placements: placements ?? [], now });
    const names: Record<string, string> = {};
    for (const b of boards) names[b.id] = boardDisplayName(b);
    const own = new Set([task.id, ...(task.sharedCounterId ? [task.sharedCounterId] : [])]);
    const activity = events && placements
      ? buildTaskActivity({
        task, kind: resolveFamilyCountKind(task, (id) => taskMap[id]),
        events: events.filter((e) => own.has(e.taskId)), placements,
        missed: rows.filter((r) => r.missed && r.endDate).map((r) => ({ boardId: r.boardId, endDate: r.endDate as string })),
        boardNames: names,
      })
      : undefined;
    return {
      placementsLoaded: placements !== undefined && rawBoards !== undefined,
      placements: placements ?? EMPTY, boards,
      anchor: anchorBoard && anchorPlacement ? { board: anchorBoard, placement: anchorPlacement } : undefined,
      childDone, rows, parentCompounds: parentCompounds ?? EMPTY, children, counterRoot,
      templates: templates ?? EMPTY,
      watchedBoard: task.referencedBoardId ? (watchedBoardRaw === undefined ? undefined : watchedBoardRaw && !watchedBoardRaw.isDeleted ? watchedBoardRaw : null) : null,
      watchedTemplate: task.referencedTemplateId ? (watchedTemplateRaw === undefined ? undefined : watchedTemplateRaw && !watchedTemplateRaw.isDeleted ? watchedTemplateRaw : null) : null,
      activity,
    };
  }, [task, rawBoards, placements, sortedLinks, childTasks, roots, events, parentCompounds, counterRoot, templates, watchedBoardRaw, watchedTemplateRaw]);
}
