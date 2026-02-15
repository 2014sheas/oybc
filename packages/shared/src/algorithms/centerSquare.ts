import { CenterSquareType } from '../constants/enums';

/**
 * Get center square index for a board size.
 *
 * Returns the 0-based flat index of the center square for odd-sized boards.
 * Returns -1 for even-sized boards (no center square).
 *
 * @param gridSize - Board size (3, 4, or 5)
 * @returns Center square index, or -1 for even-sized boards
 */
export function getCenterSquareIndex(gridSize: number): number {
  if (gridSize % 2 === 0) return -1;
  return Math.floor((gridSize * gridSize) / 2);
}

/**
 * Check if center square should be auto-completed.
 *
 * FREE and CUSTOM_FREE types are auto-completed and locked (cannot toggle off).
 * CHOSEN and NONE types are not auto-completed.
 *
 * @param type - The center square type
 * @returns True if the center square should be auto-completed
 */
export function isCenterAutoCompleted(type: CenterSquareType): boolean {
  return type === CenterSquareType.FREE || type === CenterSquareType.CUSTOM_FREE;
}

/**
 * Get display text for center square.
 *
 * Returns the appropriate label text based on the center square type:
 * - FREE: "FREE SPACE"
 * - CUSTOM_FREE: custom name or "FREE SPACE" fallback
 * - CHOSEN: empty string (uses task name from board data)
 * - NONE: empty string (ordinary square)
 *
 * @param type - The center square type
 * @param customName - Optional custom name for CUSTOM_FREE type
 * @returns Display text for the center square
 */
export function getCenterDisplayText(
  type: CenterSquareType,
  customName?: string
): string {
  switch (type) {
    case CenterSquareType.FREE:
      return 'FREE SPACE';
    case CenterSquareType.CUSTOM_FREE:
      return customName ?? 'FREE SPACE';
    case CenterSquareType.CHOSEN:
    case CenterSquareType.NONE:
      return '';
  }
}
