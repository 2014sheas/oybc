import type { Board } from '@oybc/shared';
import { buildBoardPreviewCells, type BoardPreviewCellsResult } from '../components/home/boardPreviewCells';
import { useBoardTasks } from './useBoardTasks';
import { useSquareWindowContext } from './useSquareWindowContext';
import { useTaskLibrary } from '../pages/createPage/useTaskLibrary';

/**
 * Reactive read-model for a board's TRUE mini-preview grid — the same
 * placement + completion data `useBoardPlayData` assembles for the full play
 * surface, narrowed to what `buildBoardPreviewCells` needs. One `useLiveQuery`
 * subscription set per board card; Dexie-idiomatic (see `useBoardPlayData`,
 * which does the same per-board-surface pattern).
 *
 * Every underlying hook (`useBoardTasks`, `useTaskLibrary`,
 * `useSquareWindowContext`) defaults to an empty read-model before its first
 * live-query tick resolves, so this never returns `undefined` — during that
 * gap (milliseconds, local-only) it naturally renders an all-empty preview
 * grid rather than a stale count-approximation, and re-renders true once the
 * query settles.
 *
 * @param board - The board to preview.
 */
export function useBoardPreviewCells(board: Board): BoardPreviewCellsResult {
  const boardTasks = useBoardTasks(board.id);
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(board.userId);
  const squareWindowContext = useSquareWindowContext(board);

  return buildBoardPreviewCells(
    board,
    boardTasks ?? [],
    taskMap,
    compoundChildrenByCompound,
    squareWindowContext.eventsByTaskId,
  );
}
