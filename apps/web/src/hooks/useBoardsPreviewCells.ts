import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import type { Board, BoardTask, TaskEvent } from '@oybc/shared';
import { db } from '../db/internal';
import { buildSquareWindowContext } from '../db/adapters';
import { buildBoardPreviewCells, type BoardPreviewCellsResult } from '../components/home/boardPreviewCells';
import { useTaskLibrary } from '../pages/createPage/useTaskLibrary';

// Stable empty fallbacks — see EMPTY_BOARD_TASKS in useBoardPlayData.ts for
// why: preserves React Compiler's memoization of downstream deps instead of
// re-allocating `?? []` on every render.
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
const EMPTY_TASK_EVENTS = Object.freeze([]) as unknown as TaskEvent[];

/**
 * Hoisted TRUE-preview-grid data for an entire boards LIST — mounts each
 * underlying live query ONCE (not once per card) and returns a
 * `board.id` → cells map.
 *
 * Perf follow-up to bugfix/board-preview-real-cells: the original
 * `useBoardPreviewCells` (deleted) mounted `useTaskLibrary` +
 * `useSquareWindowContext` — including an UNSCOPED `db.taskEvents.toArray()`
 * — once PER CARD, so every event/task write re-ran full-table reads × N
 * cards with no virtualization. This hook does the same three live queries
 * (task library, all board tasks, all task events) exactly once regardless
 * of list length, then derives every board's cells via the pure
 * `buildBoardPreviewCells` (which reads each board's own `startDate` for its
 * window, so one shared `eventsByTaskId` correctly serves every board).
 *
 * Use at the list-owning page (`BoardsPage`, `HomePage`) — never per-card.
 *
 * @param boards - The boards to build preview cells for.
 * @param userId - Active user id, for the task-library scope.
 */
export function useBoardsPreviewCells(
  boards: Board[],
  userId: string | undefined,
): Record<string, BoardPreviewCellsResult> {
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(userId);
  const allBoardTasks: BoardTask[] = useLiveQuery(() => db.boardTasks.toArray(), []) ?? EMPTY_BOARD_TASKS;
  const allTaskEvents: TaskEvent[] = useLiveQuery(() => db.taskEvents.toArray(), []) ?? EMPTY_TASK_EVENTS;

  // windowStart is irrelevant here — buildBoardPreviewCells reads each
  // board's OWN startDate internally; only the taskId grouping is reused.
  const eventsByTaskId = useMemo(
    () => buildSquareWindowContext(allTaskEvents, '').eventsByTaskId,
    [allTaskEvents],
  );

  return useMemo(() => {
    const out: Record<string, BoardPreviewCellsResult> = {};
    for (const board of boards) {
      out[board.id] = buildBoardPreviewCells(
        board,
        allBoardTasks,
        taskMap,
        compoundChildrenByCompound,
        eventsByTaskId,
      );
    }
    return out;
  }, [boards, allBoardTasks, taskMap, compoundChildrenByCompound, eventsByTaskId]);
}
