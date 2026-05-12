import type { Task, CompoundChild, BoardTask, Board } from '../types';
import { BoardSize } from '../constants';
import { AchievementTrigger, BoardStatus, CenterSquareType, TaskType } from '../constants/enums';
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
 * @param allBoards          All non-deleted boards in the workspace. Required
 *                           for Phase 6.3 ACHIEVEMENT-typed Tasks — they
 *                           read another board's (or template-spawn set's)
 *                           state directly. Pass `[]` when the caller has
 *                           no cross-board context (will degrade those
 *                           branches to "incomplete", matching the
 *                           missing-reference semantic).
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
  allBoards: Board[] = [],
): BoardStatsUpdate {
  const size = board.boardSize as BoardSize;
  const totalSquares = size * size;
  const grid: boolean[] = new Array(totalSquares).fill(false);
  let completedTasks = 0;

  // Phase 6.3: index all non-deleted boards by id (specific-board mode)
  // and by spawnedFromTemplateId (recurring-template mode). Built lazily —
  // only allocated if at least one boardTask uses one of the new modes —
  // so non-recurring boards pay no cost. `allBoards.length === 0` paths
  // (no cross-board context supplied) skip both maps entirely.
  let boardById: Map<string, Board> | null = null;
  let boardsByTemplateId: Map<string, Board[]> | null = null;
  const buildBoardIndexes = (): void => {
    if (boardById !== null) return;
    boardById = new Map();
    boardsByTemplateId = new Map();
    for (const b of allBoards) {
      if (b.isDeleted) continue;
      boardById.set(b.id, b);
      if (b.spawnedFromTemplateId) {
        const list = boardsByTemplateId.get(b.spawnedFromTemplateId) ?? [];
        list.push(b);
        boardsByTemplateId.set(b.spawnedFromTemplateId, list);
      }
    }
  };

  for (const bt of boardTasksOnBoard) {
    const t = taskById[bt.taskId];
    if (!t || t.isDeleted) continue;

    const idx = bt.row * size + bt.col;
    if (idx < 0 || idx >= totalSquares) continue;

    // Phase 6.3 — ACHIEVEMENT-typed Tasks are cross-board watchers. The
    // backing Task carries the reference fields (board XOR template); the
    // BoardTask is a pure placement record. Dispatching on `t.type` here
    // is the only point where derivation cares about the task type vs the
    // simple-completion branch below.
    if (t.type === TaskType.ACHIEVEMENT) {
      // Trigger selects what "done" means for the watched target.
      // Default GREENLOG matches the pre-trigger shipped behavior so
      // older payloads decode safely (the Zod schema also defaults).
      const trigger = t.achievementTrigger ?? AchievementTrigger.GREENLOG;
      const meets = (b: Board): boolean =>
        trigger === AchievementTrigger.BINGO
          ? (b.linesCompleted ?? 0) > 0
          : b.status === BoardStatus.COMPLETED;

      // Precedence: `referencedBoardId` wins when both fields are set.
      // The Zod refinement rejects rows that set both, but a malicious
      // remote payload or older client could still produce one — pick
      // the more specific reference deterministically so derivation is
      // predictable.
      if (t.referencedBoardId) {
        // Specific-board mode: square completes when the referenced
        // board meets the trigger AND is non-deleted. Soft-deleted ⇒
        // incomplete (not crash; not silently ignore — UI can surface
        // a "needs attention" badge separately). `requiredCount` is
        // ignored in this mode (the named board is either done or not).
        buildBoardIndexes();
        const ref = boardById!.get(t.referencedBoardId);
        if (ref && meets(ref)) {
          grid[idx] = true;
          completedTasks += 1;
        }
        continue;
      }

      if (t.referencedTemplateId) {
        // Recurring-template mode: count how many in-window spawns
        // meet the trigger, then compare against `requiredCount`.
        // The cell completes when:
        //   - the in-window non-deleted spawn set is non-empty
        //     (matches the locked "empty window = incomplete, NOT
        //     vacuously true" rule), AND
        //   - the number of in-window spawns meeting the trigger is
        //     >= `requiredCount`.
        // When fewer in-window spawns exist than `requiredCount`
        // requires, the cell stays incomplete and waits for future
        // spawns. Window membership is inclusive on both ends.
        buildBoardIndexes();
        const spawns = boardsByTemplateId!.get(t.referencedTemplateId) ?? [];
        const inWindow = spawns.filter(
          (b) => b.startDate >= board.startDate && b.startDate <= board.endDate,
        );
        if (inWindow.length === 0) continue;
        const metCount = inWindow.filter(meets).length;
        const required = t.requiredCount ?? 0;
        if (required > 0 && metCount >= required) {
          grid[idx] = true;
          completedTasks += 1;
        }
        continue;
      }

      // No reference set → incomplete (achievement Task lacking the XOR
      // value should have been rejected at write time; degrade safely).
      continue;
    }

    const isDone =
      t.type === TaskType.COMPOUND
        ? evaluateCompound(t, childrenByCompound, taskById)
        : t.isCompleted;
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
