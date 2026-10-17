import { isWindowStampedDerived, resolveFamilyCountKind, type Board, type BoardTask, type CountKind, type Task } from '@oybc/shared';
import type { BoardPlayData } from '../../../hooks';
import { resolveClosedBoardCounterDisplay, taskToSquareData, taskToSquareState } from '../../../db/adapters';
import type { SquareState, TaskSquareData } from '../../interactiveTaskSquareUtils';

export type SquareViewData = Pick<
  BoardPlayData,
  | 'boardTasks' | 'taskMap' | 'compoundChildrenByCompound' | 'allBoards' | 'achievementBadgesByBoardTaskId'
  | 'cellStateByBoardTaskId' | 'sharedCounterSourceIds' | 'squareWindowContext' | 'gridSize'
>;

/** One placement as the sheet and the hold menu both read it. */
export interface SquareView {
  sq: TaskSquareData;
  state: SquareState;
  sealed: boolean;
  /** Done on this board (a sealed board reads its frozen snapshot). */
  done: boolean;
  /** The windowed count (a sealed board: the sealed-bounded one); 0 for non-counting. */
  count: number;
  kind: CountKind;
  /** A hub-linked derived counter: nothing to late-log. */
  hubLinked: boolean;
}

/**
 * Resolves a placement's display facts against the board's read-model.
 *
 * @returns The view.
 */
export function resolveSquareView(board: Board, data: SquareViewData, bt: BoardTask, task: Task): SquareView {
  const { taskMap, squareWindowContext } = data;
  const sealed = board.sealedAt != null;
  const children = data.compoundChildrenByCompound[task.id] ?? [];
  const sq = taskToSquareData(task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, bt.childTargets);
  const state = taskToSquareState(
    task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, data.cellStateByBoardTaskId[bt.id], bt.childTargets,
  );
  const cellIndex = bt.row * data.gridSize + bt.col;
  return {
    sq, state, sealed,
    done: sealed ? (board.sealedCompletedCells ?? []).includes(cellIndex) : state.isCompleted,
    count: sealed
      ? (sq.type === 'counting' ? resolveClosedBoardCounterDisplay(task, squareWindowContext.eventsByTaskId, board).displayed : 0)
      : state.currentCount,
    kind: sq.countKind ?? resolveFamilyCountKind(task, (id) => taskMap[id]),
    hubLinked: sq.type === 'counting' && task.sharedCounterId != null && !isWindowStampedDerived(task),
  };
}
