import { useMemo } from 'react';
import {
  CenterSquareType,
  effectiveCenter,
  getHighlightedSquares,
  isLegacyChosenCenterLocked,
  resolveFamilyCountKind,
  type Board,
  type BoardSize,
  type BoardTask,
  type CellState,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import {
  placedTaskFor,
  resolveClosedBoardCounterDisplay,
  taskToSquareData,
  taskToSquareState,
  type SquareWindowContext,
} from '../../db/adapters';
import { countKeyFor, resolvePendingCount, type PendingCounts } from '../../hooks/pendingCounts';
import type { BoardCellModel } from './RisoBoardCell';
import { freeCellModel, toBoardCellModel } from './cellModel';

/** What a Normal square's tap needs, beyond its placement id. */
export interface NormalTapInfo {
  taskId: string;
  title: string;
  wasDone: boolean;
}

/** One grid position of the play board, resolved to what it renders. */
export type PlayCellEntry =
  | { kind: 'free'; key: string; cell: BoardCellModel }
  | { kind: 'empty'; key: string }
  | { kind: 'missing'; key: string }
  | {
      kind: 'task';
      key: string;
      boardTaskId: string;
      cell: BoardCellModel;
      /** The achievement-watch corner badge. */
      hasBadge: boolean;
      /** Set for a Normal square on an open board (tap toggles); null = tap opens the sheet. */
      normalTap: NormalTapInfo | null;
    };

/** The task-holding entry a play cell draws. */
export type PlayTaskEntry = Extract<PlayCellEntry, { kind: 'task' }>;

/** Whether two cell models draw identically. */
function sameModel(a: BoardCellModel, b: BoardCellModel): boolean {
  return a.key === b.key && a.label === b.label && a.type === b.type && a.done === b.done && a.isFree === b.isFree
    && a.isLine === b.isLine && a.lineGreen === b.lineGreen && a.isShared === b.isShared && a.isArrived === b.isArrived
    && a.locked === b.locked && a.dirty === b.dirty
    && a.count?.cur === b.count?.cur && a.count?.max === b.count?.max && a.count?.kind === b.count?.kind;
}

/**
 * Whether two task entries draw AND behave identically — the memo test that
 * lets an unchanged square skip a render.
 *
 * @returns True when nothing the cell shows or does has changed.
 */
export function samePlayTaskEntry(a: PlayTaskEntry, b: PlayTaskEntry): boolean {
  return a.boardTaskId === b.boardTaskId && a.hasBadge === b.hasBadge
    && a.normalTap?.taskId === b.normalTap?.taskId && a.normalTap?.title === b.normalTap?.title
    && a.normalTap?.wasDone === b.normalTap?.wasDone
    && sameModel(a.cell, b.cell);
}

/** Everything the grid's cell models are derived from. */
export interface PlayCellInputs {
  board: Board;
  gridSize: BoardSize;
  /** The board's resolved placements, by `row-col`. */
  btByPosition: Record<string, BoardTask>;
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  cellStateByBoardTaskId: Record<string, CellState>;
  squareWindowContext: SquareWindowContext;
  sharedCounterSourceIds: Set<string>;
  /** Placement ids that carry the achievement badge. */
  achievementBoardTaskIds: ReadonlySet<string>;
  liveCompletedLineIds: ReadonlyArray<string>;
  arrivedTaskIds: ReadonlySet<string>;
  /** Pending (optimistic) counts: an in-flight log shows its expected count. */
  pendingCounts: PendingCounts;
}

/**
 * Resolves every grid position of the play board to its cell entry — the
 * per-cell `taskToSquareData` / `taskToSquareState` work that used to run inline
 * on every render of `BoardPlaySurface`. Pure; {@link usePlayCellEntries} memoises
 * it on exactly these inputs.
 *
 * @param inputs - The read-model the cells derive from.
 * @returns The entries in row-major order.
 */
export function buildPlayCellEntries(inputs: PlayCellInputs): PlayCellEntry[] {
  const {
    board, gridSize, btByPosition, taskMap, compoundChildrenByCompound, cellStateByBoardTaskId, squareWindowContext,
    sharedCounterSourceIds, achievementBoardTaskIds, liveCompletedLineIds, arrivedTaskIds, pendingCounts,
  } = inputs;
  const isSealed = board.sealedAt != null;
  const sealedCellSet = new Set(isSealed ? (board.sealedCompletedCells ?? []) : []);
  // Gold-ring the cells in completed bingo lines. A LIVE board rings from the
  // kernel grid this render was built from; a SEALED board keeps its frozen snapshot.
  const highlighted = getHighlightedSquares(isSealed ? (board.completedLineIds ?? []) : [...liveCompletedLineIds], gridSize);
  const centerType = board.centerSquareType as CenterSquareType;
  const entries: PlayCellEntry[] = [];

  for (let row = 0; row < gridSize; row++) {
    for (let col = 0; col < gridSize; col++) {
      const isCenter = gridSize % 2 === 1 && row === Math.floor(gridSize / 2) && col === Math.floor(gridSize / 2);
      // A live board reads its center through `effectiveCenter` (CHOSEN → NONE).
      const isFreeCenter = isCenter && effectiveCenter(centerType) === CenterSquareType.FREE;
      const bt = btByPosition[`${row}-${col}`];

      if (!bt) {
        entries.push(isFreeCenter
          ? { kind: 'free', key: `center-${row}-${col}`, cell: freeCellModel(`center-${row}-${col}`) }
          : { kind: 'empty', key: `empty-${row}-${col}` });
        continue;
      }

      const task = placedTaskFor(bt, taskMap);
      if (!task) {
        entries.push({ kind: 'missing', key: `missing-${bt.id}` });
        continue;
      }

      const children = compoundChildrenByCompound[task.id] ?? [];
      const squareData = taskToSquareData(task, children, taskMap, compoundChildrenByCompound, squareWindowContext, bt.childTargets);
      const squareState = taskToSquareState(
        task, children, taskMap, compoundChildrenByCompound, squareWindowContext, cellStateByBoardTaskId[bt.id], bt.childTargets,
      );
      const counting = squareData.type === 'counting';
      // A SEALED board reads the frozen snapshot, never live events; a CLOSED
      // counting square shows the sealed-bounded windowed count.
      let done = isSealed ? sealedCellSet.has(row * gridSize + col) : squareState.isCompleted;
      let count = isSealed
        ? counting ? resolveClosedBoardCounterDisplay(task, squareWindowContext.eventsByTaskId, board).displayed : 0
        : squareState.currentCount;
      if (counting && !isSealed) {
        const shown = resolvePendingCount(pendingCounts, countKeyFor(task), count);
        if (shown !== count) {
          const goal = squareData.maxCount ?? task.maxCount ?? 0;
          count = shown;
          done = goal > 0 && shown >= goal;
        }
      }

      // A shared-counter square (source or linked) and a "counts toward" contributor carry the two-dot mark while not done.
      const isShared = !done
        && ((counting && (task.sharedCounterId != null || sharedCounterSourceIds.has(task.id))) || task.countsTowardCounterId != null);
      // The lock chip reflects the EFFECTIVE lock: stored, or a legacy-CHOSEN positional center.
      const locked = bt.isLocked === true || isLegacyChosenCenterLocked(centerType, row, col, gridSize);

      entries.push({
        kind: 'task',
        key: bt.id,
        boardTaskId: bt.id,
        cell: toBoardCellModel({
          key: bt.id,
          task,
          done,
          currentCount: counting ? count : undefined,
          isLine: highlighted.has(row * gridSize + col),
          isShared,
          isArrived: arrivedTaskIds.has(bt.taskId),
          locked,
          countKind: resolveFamilyCountKind(task, (id) => taskMap[id]),
        }),
        hasBadge: achievementBoardTaskIds.has(bt.id),
        // Tap contract: a Normal square toggles at once (+ an Undo toast); every other type, and every square on a closed board, opens the sheet.
        normalTap: !isSealed && squareData.type === 'normal' ? { taskId: task.id, title: task.title, wasDone: done } : null,
      });
    }
  }
  return entries;
}

/**
 * The play board's cell entries, recomputed only when one of their real inputs
 * changes — a toast, a busy flip or a flash re-renders the surface without
 * touching a cell.
 *
 * @param inputs - See {@link PlayCellInputs}.
 * @returns The entries in row-major order.
 */
export function usePlayCellEntries(inputs: PlayCellInputs): PlayCellEntry[] {
  const {
    board, gridSize, btByPosition, taskMap, compoundChildrenByCompound, cellStateByBoardTaskId, squareWindowContext,
    sharedCounterSourceIds, achievementBoardTaskIds, liveCompletedLineIds, arrivedTaskIds, pendingCounts,
  } = inputs;
  return useMemo(
    () => buildPlayCellEntries({
      board, gridSize, btByPosition, taskMap, compoundChildrenByCompound, cellStateByBoardTaskId, squareWindowContext,
      sharedCounterSourceIds, achievementBoardTaskIds, liveCompletedLineIds, arrivedTaskIds, pendingCounts,
    }),
    [
      board, gridSize, btByPosition, taskMap, compoundChildrenByCompound, cellStateByBoardTaskId, squareWindowContext,
      sharedCounterSourceIds, achievementBoardTaskIds, liveCompletedLineIds, arrivedTaskIds, pendingCounts,
    ],
  );
}
