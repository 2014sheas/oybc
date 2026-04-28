import type { Task, CompoundChild, BoardTask, Board } from '../types';
import { BoardSize } from '../constants';
import { CenterSquareType, TaskType } from '../constants/enums';
import { detectBingos } from './bingoDetection';
import { evaluateCompound } from './compoundEvaluation';

/**
 * Walk `compound_children` upward from `changedTaskId` and return the set of
 * compound Task ids that transitively contain it as a child.
 *
 * Bounded by compound-nesting depth (typically ≤ 2 in practice). Stops on
 * cycles defensively (a child that's already in the result set is not
 * re-queued).
 *
 * @param changedTaskId  The Task whose state just changed.
 * @param children       All non-deleted CompoundChild rows in the workspace
 *                       (deleted rows are filtered internally).
 * @returns Set of compound Task ids that transitively contain the changed task.
 */
export function findTransitiveParentCompounds(
  changedTaskId: string,
  children: CompoundChild[],
): Set<string> {
  const out = new Set<string>();
  const queue: string[] = [changedTaskId];
  while (queue.length > 0) {
    const id = queue.shift()!;
    for (const link of children) {
      if (link.isDeleted) continue;
      if (link.childTaskId === id && !out.has(link.compoundTaskId)) {
        out.add(link.compoundTaskId);
        queue.push(link.compoundTaskId);
      }
    }
  }
  return out;
}

/**
 * Resolve the set of board ids that need recomputing after `changedTaskId`
 * updates. A board is affected if it places either:
 *   - the changed task directly, OR
 *   - any compound that transitively contains the changed task.
 *
 * @param changedTaskId   The Task whose state just changed.
 * @param parentCompounds Set of compound Task ids that transitively contain the changed task.
 * @param boardTasks      All BoardTask rows in the workspace.
 * @returns Set of board ids that need their stats recomputed.
 */
export function findAffectedBoardIds(
  changedTaskId: string,
  parentCompounds: Set<string>,
  boardTasks: BoardTask[],
): Set<string> {
  const taskIds = new Set<string>([changedTaskId, ...parentCompounds]);
  const out = new Set<string>();
  for (const bt of boardTasks) {
    if (taskIds.has(bt.taskId)) out.add(bt.boardId);
  }
  return out;
}

/**
 * The shape returned by `computeBoardStatsUpdate` — a payload the caller
 * applies to the `boards` row, plus signals it can surface to the user.
 */
export interface BoardStatsUpdate {
  boardId: string;
  completedTasks: number;
  linesCompleted: number;
  completedLineIds: string[];
  /** Bingo lines that newly appeared since the previous boards.completedLineIds. */
  newBingos: string[];
  /** Bingo lines that disappeared since the previous boards.completedLineIds. */
  lostBingos: string[];
}

/**
 * For one board: rebuild its completion grid (reading post-write Task states +
 * recursively evaluating compounds), run bingo detection, diff against the
 * board's previous `completedLineIds`, and return the stats payload the caller
 * should write to `boards`.
 *
 * Pure — no I/O, no input mutation. Caller is responsible for actually
 * persisting the returned payload + enqueuing the sync entry.
 *
 * Center auto-fill: for odd-sized boards (3 / 5) where the centre square is
 * unoccupied AND the board's centerSquareType is FREE or CUSTOM_FREE, the
 * centre cell is treated as completed (mirrors current per-platform logic).
 *
 * @param board              The board whose stats need recomputing.
 * @param boardTasksOnBoard  All BoardTask rows for this specific board.
 * @param childrenByCompound Map of compoundTaskId → list of CompoundChild rows.
 * @param taskById           Map of taskId → Task (all tasks in the workspace).
 * @returns A payload to MERGE into the board row. The caller is responsible
 *          for ALSO setting `board.updatedAt` (current timestamp) and
 *          incrementing `board.version` before persisting — those are
 *          deliberately omitted here because shared has no clock access.
 *          Skipping them silently breaks LWW sync; both platforms' write
 *          path code must remember to apply them.
 */
export function computeBoardStatsUpdate(
  board: Board,
  boardTasksOnBoard: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
): BoardStatsUpdate {
  const size = board.boardSize as BoardSize;
  const totalSquares = size * size;
  const grid: boolean[] = new Array(totalSquares).fill(false);
  let completedTasks = 0;

  for (const bt of boardTasksOnBoard) {
    // Achievement squares: completion derives from achievementProgress reaching
    // achievementCount on THIS board. The backing Task's isCompleted state is
    // irrelevant — the square's semantic is "this cross-board goal is reached",
    // tracked by achievementProgress / achievementCount on the BoardTask row.
    if (bt.isAchievementSquare) {
      const required = bt.achievementCount ?? 0;
      const progress = bt.achievementProgress ?? 0;
      const idx = bt.row * size + bt.col;
      if (idx < 0 || idx >= totalSquares) continue;
      // required > 0 guard: prevents a 0/0 achievement square from registering
      // as complete before it has been configured.
      if (required > 0 && progress >= required) {
        grid[idx] = true;
        completedTasks += 1;
      }
      continue; // don't fall through to the Task.isCompleted branch
    }

    const t = taskById[bt.taskId];
    if (!t || t.isDeleted) continue;
    const isDone =
      t.type === TaskType.COMPOUND
        ? evaluateCompound(t, childrenByCompound, taskById)
        : t.isCompleted;
    const idx = bt.row * size + bt.col;
    if (idx < 0 || idx >= totalSquares) continue;
    if (isDone) {
      grid[idx] = true;
      completedTasks += 1;
    }
  }

  // Center auto-fill for odd-sized boards with FREE / CUSTOM_FREE center.
  if (size % 2 === 1) {
    const centerRow = Math.floor(size / 2);
    const centerCol = Math.floor(size / 2);
    const centerIdx = centerRow * size + centerCol;
    const hasCenterTask = boardTasksOnBoard.some(
      (bt) => bt.row === centerRow && bt.col === centerCol,
    );
    if (
      !hasCenterTask &&
      (board.centerSquareType === CenterSquareType.FREE ||
        board.centerSquareType === CenterSquareType.CUSTOM_FREE) &&
      !grid[centerIdx]
    ) {
      grid[centerIdx] = true;
      completedTasks += 1;
    }
  }

  const detection = detectBingos(grid, size);
  const previous = new Set(board.completedLineIds ?? []);
  const current = new Set(detection.completedLines);
  const newBingos = detection.completedLines.filter((l) => !previous.has(l));
  const lostBingos = (board.completedLineIds ?? []).filter((l) => !current.has(l));

  return {
    boardId: board.id,
    completedTasks,
    linesCompleted: detection.completedLines.length,
    completedLineIds: detection.completedLines,
    newBingos,
    lostBingos,
  };
}
