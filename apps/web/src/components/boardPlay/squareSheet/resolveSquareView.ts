import { resolveFamilyCountKind, type Board, type BoardTask, type CountKind, type Task } from '@oybc/shared';
import type { BoardPlayData } from '../../../hooks';
import { resolveClosedBoardCounterDisplay, taskToSquareData, taskToSquareState } from '../../../db/adapters';
import type { SquareState, TaskSquareData } from '../../interactiveTaskSquareUtils';
import { NO_PENDING, countKeyFor, resolvePendingCount, type PendingCounts } from '../../../hooks/pendingCounts';

export type SquareViewData = Pick<
  BoardPlayData,
  | 'boardTasks' | 'taskMap' | 'compoundChildrenByCompound' | 'allBoards' | 'achievementBadgesByBoardTaskId'
  | 'cellStateByBoardTaskId' | 'sharedCounterSourceIds' | 'squareWindowContext' | 'gridSize'
>;

/** A compound's counting children show their pending counts too (the stepper rows). */
function withPendingChildCounts(sq: TaskSquareData, taskMap: Record<string, Task>, pending: PendingCounts): TaskSquareData {
  if (!sq.children?.some((c) => c.count)) return sq;
  return {
    ...sq,
    children: sq.children.map((c) => {
      const child = taskMap[c.taskId];
      if (!c.count || !child) return c;
      const current = resolvePendingCount(pending, countKeyFor(child), c.count.current);
      return current === c.count.current ? c : { ...c, count: { ...c.count, current } };
    }),
  };
}

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
}

/**
 * Resolves a placement's display facts against the board's read-model.
 *
 * @param pending - Pending (optimistic) counts: a count in flight shows its expected value at once.
 * @returns The view.
 */
export function resolveSquareView(
  board: Board, data: SquareViewData, bt: BoardTask, task: Task, pending: PendingCounts = NO_PENDING,
): SquareView {
  const { taskMap, squareWindowContext } = data;
  const sealed = board.sealedAt != null;
  const children = data.compoundChildrenByCompound[task.id] ?? [];
  const base = taskToSquareData(task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, bt.childTargets);
  const sq = sealed ? base : withPendingChildCounts(base, taskMap, pending);
  const state = taskToSquareState(
    task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, data.cellStateByBoardTaskId[bt.id], bt.childTargets,
  );
  const cellIndex = bt.row * data.gridSize + bt.col;
  return {
    sq, state, sealed,
    done: sealed ? (board.sealedCompletedCells ?? []).includes(cellIndex) : state.isCompleted,
    count: sealed
      ? (sq.type === 'counting' ? resolveClosedBoardCounterDisplay(task, squareWindowContext.eventsByTaskId, board).displayed : 0)
      : resolvePendingCount(pending, countKeyFor(task), state.currentCount),
    kind: sq.countKind ?? resolveFamilyCountKind(task, (id) => taskMap[id]),
  };
}
