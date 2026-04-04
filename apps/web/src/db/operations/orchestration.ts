import { db } from '../database';
import { BoardStatus, CenterSquareType, detectBingos, type BoardTask } from '@oybc/shared';
import { currentTimestamp } from '../utils';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Result of a task completion, including bingo detection and board status changes.
 *
 * @property newBingos - Line IDs that became complete (not previously in board.completedLineIds)
 * @property lostBingos - Line IDs that became incomplete (were in board.completedLineIds, now gone)
 * @property isGreenlog - True when every square on the board is complete
 * @property boardCompleted - True if the board status transitioned to COMPLETED
 * @property boardReactivated - True if the board reverted from COMPLETED to ACTIVE
 */
export interface TaskCompletionResult {
  newBingos: string[];
  lostBingos: string[];
  isGreenlog: boolean;
  boardCompleted: boolean;
  boardReactivated: boolean;
}

// ─── Orchestration ───────────────────────────────────────────────────────────

/**
 * Handles a task completion event on a board, orchestrating the full chain:
 * update BoardTask → rebuild completion grid → detect bingos → update board stats
 * → auto-complete board on greenlog.
 *
 * This function wraps all writes in a single Dexie transaction for atomicity.
 * The caller uses the return value to trigger celebrations immediately (rather
 * than waiting for reactive hook updates which may lag by a frame).
 *
 * @param boardId - The board containing the task
 * @param boardTaskId - The specific BoardTask to update
 * @param updates - Partial update to apply (isCompleted, currentCount, completedStepIds)
 * @returns TaskCompletionResult with new bingos, greenlog status, and board completion flag
 */
export async function handleTaskCompletion(
  boardId: string,
  boardTaskId: string,
  updates: {
    isCompleted?: boolean;
    currentCount?: number;
    completedStepIds?: string[];
  }
): Promise<TaskCompletionResult> {
  let result: TaskCompletionResult = {
    newBingos: [],
    lostBingos: [],
    isGreenlog: false,
    boardCompleted: false,
    boardReactivated: false,
  };

  await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.taskSteps], async () => {
    // 1. Fetch the board
    const board = await db.boards.get(boardId);
    if (!board) throw new Error(`Board ${boardId} not found`);

    // 2. Validate the boardTask exists and belongs to this board
    const targetBt = await db.boardTasks.get(boardTaskId);
    if (!targetBt) throw new Error(`BoardTask ${boardTaskId} not found`);
    if (targetBt.boardId !== boardId) {
      throw new Error(`BoardTask ${boardTaskId} does not belong to board ${boardId}`);
    }

    // 3. Apply the update to the target boardTask
    const now = currentTimestamp();
    const updatePayload: Partial<BoardTask> = {
      ...updates,
      updatedAt: now,
    };

    // Auto-detect completion for counting tasks
    if (updates.currentCount !== undefined) {
      const bt = targetBt;
      if (bt) {
        // Look up the task to get maxCount
        const task = await db.tasks.get(bt.taskId);
        if (task && task.maxCount !== undefined && updates.currentCount >= task.maxCount) {
          updatePayload.isCompleted = true;
          updatePayload.completedAt = now;
        } else if (updates.currentCount < (task?.maxCount ?? Infinity)) {
          updatePayload.isCompleted = false;
          updatePayload.completedAt = undefined;
        }
      }
    }

    // Auto-detect completion for progress tasks (all steps done)
    if (updates.completedStepIds !== undefined) {
      {
        const task = await db.tasks.get(targetBt.taskId);
        if (task) {
          const totalSteps = await db.taskSteps
            .where('taskId')
            .equals(task.id)
            .filter((s) => !s.isDeleted)
            .count();
          if (totalSteps > 0 && updates.completedStepIds.length >= totalSteps) {
            updatePayload.isCompleted = true;
            updatePayload.completedAt = now;
          } else {
            updatePayload.isCompleted = false;
            updatePayload.completedAt = undefined;
          }
        }
      }
    }

    // Set completedAt for explicit completion — only when auto-detection
    // didn't already determine isCompleted (counting/progress auto-detection
    // sets both isCompleted and completedAt together)
    if (updates.isCompleted !== undefined &&
        updates.currentCount === undefined &&
        updates.completedStepIds === undefined) {
      if (updates.isCompleted) {
        updatePayload.completedAt = now;
      } else {
        updatePayload.completedAt = undefined;
      }
    }

    // Increment version
    updatePayload.version = (targetBt.version ?? 1) + 1;

    await db.boardTasks.update(boardTaskId, updatePayload);

    // 3. Fetch ALL board tasks to rebuild the completion grid
    const allBoardTasks = await db.boardTasks
      .where('boardId')
      .equals(boardId)
      .toArray();

    // 4. Build the completion grid (flat boolean array, row-major order)
    const gridSize = board.boardSize;
    const totalSquares = gridSize * gridSize;
    const completionGrid: boolean[] = new Array(totalSquares).fill(false);

    for (const bt of allBoardTasks) {
      const index = bt.row * gridSize + bt.col;
      if (index >= 0 && index < totalSquares) {
        completionGrid[index] = bt.id === boardTaskId
          ? (updatePayload.isCompleted ?? bt.isCompleted)
          : bt.isCompleted;
      }
    }

    // Handle center square auto-completion for FREE/CUSTOM_FREE
    if (gridSize % 2 === 1) {
      const centerIndex = Math.floor(totalSquares / 2);
      const hasCenterTask = allBoardTasks.some(
        (bt) => bt.row === Math.floor(gridSize / 2) && bt.col === Math.floor(gridSize / 2)
      );
      if (!hasCenterTask && (board.centerSquareType === CenterSquareType.FREE || board.centerSquareType === CenterSquareType.CUSTOM_FREE)) {
        completionGrid[centerIndex] = true;
      }
    }

    // 5. Detect bingos
    const bingoResult = detectBingos(completionGrid, gridSize as 3 | 4 | 5);

    // 6. Diff against previous completedLineIds to find NEW and LOST bingos
    const previousLineIds = new Set(board.completedLineIds ?? []);
    const currentLineIds = new Set(bingoResult.completedLines);
    const newBingos = bingoResult.completedLines.filter((line) => !previousLineIds.has(line));
    const lostBingos = (board.completedLineIds ?? []).filter((line) => !currentLineIds.has(line));

    // 7. Update board stats
    const completedCount = allBoardTasks.filter((bt) =>
      bt.id === boardTaskId ? (updatePayload.isCompleted ?? bt.isCompleted) : bt.isCompleted
    ).length;

    // Add center square to count if auto-completed
    let totalCompleted = completedCount;
    if (gridSize % 2 === 1) {
      const hasCenterTask = allBoardTasks.some(
        (bt) => bt.row === Math.floor(gridSize / 2) && bt.col === Math.floor(gridSize / 2)
      );
      if (!hasCenterTask && (board.centerSquareType === CenterSquareType.FREE || board.centerSquareType === CenterSquareType.CUSTOM_FREE)) {
        totalCompleted++;
      }
    }

    // 8. Build a single board update with stats + optional status transition
    let boardCompleted = false;
    let boardReactivated = false;
    const boardUpdate: Record<string, unknown> = {
      completedTasks: totalCompleted,
      linesCompleted: bingoResult.completedLines.length,
      completedLineIds: bingoResult.completedLines,
      updatedAt: now,
      version: (board.version ?? 1) + 1,
    };

    // Auto-complete board on greenlog
    if (bingoResult.isGreenlog && board.status === BoardStatus.ACTIVE) {
      boardUpdate.status = BoardStatus.COMPLETED;
      boardUpdate.completedAt = now;
      boardCompleted = true;
    }

    // Revert COMPLETED → ACTIVE if board is no longer fully complete
    if (!bingoResult.isGreenlog && board.status === BoardStatus.COMPLETED) {
      boardUpdate.status = BoardStatus.ACTIVE;
      boardUpdate.completedAt = undefined;
      boardReactivated = true;
    }

    await db.boards.update(boardId, boardUpdate);

    result = {
      newBingos,
      lostBingos,
      isGreenlog: bingoResult.isGreenlog,
      boardCompleted,
      boardReactivated,
    };
  });

  return result;
}
