import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType, boardDisplayName, boardWindowEnd, buildTaskActivity, compareBoardsForList, pickHeroAnchorBoard, resolveFamilyCountKind,
  type Board, type BoardTask, type CompoundChild, type RecurringBoardTemplate, type Task, type TaskActivity,
} from '@oybc/shared';
import { fetchBoard, fetchCompoundChildren, fetchTask, fetchTasksByIds } from '../db/operations';
import { loadTaskDetailPlacements } from '../db/operations/taskDetailPlacements';
import { fetchLiveEventsForTaskIds } from '../db/operations/lateLog';
import { fetchCompoundParentsForTask } from '../db/operations/tasks';
import { fetchRecurringBoardTemplate, fetchTemplatesReferencingTask } from '../db/operations/recurringBoardTemplates';
import { buildSquareWindowContext, resolveCompoundChildCompleted } from '../db/adapters';
import { buildBoardRows, type BoardRow } from '../pages/tasks/taskDetail/taskDetailModel';

/** One compound sub-task, link + task. */
export interface DetailChild {
  link: CompoundChild;
  task: Task;
}

export interface TaskDetailData {
  /** Placements + boards resolved (false while the first read is in flight). */
  placementsLoaded: boolean;
  /** The task's OWN live placements (hero anchor, "Placed on" Activity rows). */
  placements: BoardTask[];
  /** Every board the task reaches (own, a linked row's, a parent compound's), in the Boards tab's own order. */
  boards: Board[];
  /**
   * The soonest-ending in-play board and the square on it the hero drives —
   * `childTaskId` set when that square is a compound the task is a direct child
   * of. Undefined = no anchor (a counting task then gets the board-less control).
   */
  anchor: { board: Board; placement: BoardTask; childTaskId: string | null } | undefined;
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
  // Placement resolution (PR 5): the placement REACH, each board scored by the shared kernel.
  const reached = useLiveQuery(() => loadTaskDetailPlacements(taskId), [taskId]);
  const placements = reached?.ownPlacements;
  const rawBoards = reached?.boards;

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
    // The hero anchors on a square that IS the task — its own, a counter root's
    // linked row's, or a direct-parent compound's (binding decision 3, amended
    // 2026-10-18); on the chosen board, the best-ranked square.
    // The best rank with a square in play wins; within it, the soonest-ending board.
    const anchorCandidates = reached?.anchorCandidates ?? [];
    let anchorBoard: Board | undefined;
    let anchorCandidate: (typeof anchorCandidates)[number] | undefined;
    for (const rank of [0, 1, 2] as const) {
      const ofRank = anchorCandidates.filter((c) => c.rank === rank);
      const ids = new Set(ofRank.map((c) => c.placement.boardId));
      anchorBoard = pickHeroAnchorBoard(boards.filter((b) => ids.has(b.id)), now);
      if (anchorBoard) {
        const boardId = anchorBoard.id;
        anchorCandidate = ofRank.find((c) => c.placement.boardId === boardId);
        break;
      }
    }
    const children: DetailChild[] = sortedLinks.flatMap((link) => {
      const t = (childTasks ?? []).find((c) => c.id === link.childTaskId);
      return t ? [{ link, task: t }] : [];
    });
    const taskMap: Record<string, Task> = { [task.id]: task };
    for (const t of [...(roots ?? []), ...(childTasks ?? [])]) taskMap[t.id] = t;
    // The anchor's sub-task ticks read the WORKSPACE maps, so a nested sub-compound evaluates its own children.
    const fullTaskMap = reached ? { ...reached.taskById, ...taskMap } : taskMap;
    const childrenByCompound: Record<string, CompoundChild[]> = { ...(reached?.childrenByCompound ?? {}), [task.id]: sortedLinks };
    const anchorCtx = anchorBoard
      ? { ...buildSquareWindowContext(reached?.events ?? events ?? [], anchorBoard.startDate, boardWindowEnd(anchorBoard)), sealedAt: anchorBoard.sealedAt ?? null }
      : undefined;
    const childDone: Record<string, boolean> = {};
    if (anchorCtx) for (const c of children) childDone[c.task.id] = resolveCompoundChildCompleted(c.task, fullTaskMap, childrenByCompound, anchorCtx);
    const rows = buildBoardRows({ rows: reached?.rows ?? [], boards, taskById: reached?.taskById ?? taskMap, now });
    const names: Record<string, string> = {};
    for (const b of boards) names[b.id] = boardDisplayName(b);
    // "Placed on" rows name the task's own placements only.
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
      anchor: anchorBoard && anchorCandidate
        ? { board: anchorBoard, placement: anchorCandidate.placement, childTaskId: anchorCandidate.childTaskId }
        : undefined,
      childDone, rows, parentCompounds: parentCompounds ?? EMPTY, children, counterRoot,
      templates: templates ?? EMPTY,
      watchedBoard: task.referencedBoardId ? (watchedBoardRaw === undefined ? undefined : watchedBoardRaw && !watchedBoardRaw.isDeleted ? watchedBoardRaw : null) : null,
      watchedTemplate: task.referencedTemplateId ? (watchedTemplateRaw === undefined ? undefined : watchedTemplateRaw && !watchedTemplateRaw.isDeleted ? watchedTemplateRaw : null) : null,
      activity,
    };
  }, [task, reached, rawBoards, placements, sortedLinks, childTasks, roots, events, parentCompounds, counterRoot, templates, watchedBoardRaw, watchedTemplateRaw]);
}
