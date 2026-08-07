/**
 * Cross-Board Progress Rollup
 *
 * Pure functions that calculate how parent task progress should update
 * when a subtask is completed on any board. These functions compute
 * the new state — platform-specific code handles the DB writes.
 *
 * No database code, no platform-specific code.
 */

/**
 * Result of a counting rollup calculation.
 *
 * @property newCount - The updated currentCount for the parent BoardTask
 * @property isCompleted - Whether the parent is now complete (newCount >= maxCount)
 */
export interface CountingRollupResult {
  newCount: number;
  isCompleted: boolean;
}

/**
 * Calculates updated parent counting progress after a subtask is completed.
 *
 * When a counting subtask (e.g., "Read 25 pages") is completed, its maxCount
 * is added to the parent's currentCount on each board where the parent exists.
 *
 * @param parentCurrentCount - The parent BoardTask's current count on this board
 * @param parentMaxCount - The parent Task's maxCount (total target)
 * @param subtaskMaxCount - The completed subtask's maxCount (amount to add)
 * @returns The new count and completion state for the parent BoardTask
 */
export function calculateCountingRollup(
  parentCurrentCount: number,
  parentMaxCount: number,
  subtaskMaxCount: number
): CountingRollupResult {
  const newCount = Math.min(parentCurrentCount + subtaskMaxCount, parentMaxCount);
  return {
    newCount,
    isCompleted: newCount >= parentMaxCount,
  };
}
