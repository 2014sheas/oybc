import { CenterSquareType } from './constants';

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
 * FREE is auto-completed and locked (cannot toggle off). CHOSEN and NONE are
 * not auto-completed.
 *
 * @param type - The center square type
 * @returns True if the center square should be auto-completed
 */
export function isCenterAutoCompleted(type: CenterSquareType): boolean {
  return type === CenterSquareType.FREE;
}

/**
 * Get display text for center square.
 *
 * Returns the appropriate label text based on the center square type:
 * - FREE: "FREE SPACE"
 * - CHOSEN: empty string (uses task name from board data)
 * - NONE: empty string (ordinary square)
 *
 * @param type - The center square type
 * @returns Display text for the center square
 */
export function getCenterDisplayText(type: CenterSquareType): string {
  switch (type) {
    case CenterSquareType.FREE:
      return 'FREE SPACE';
    case CenterSquareType.CHOSEN:
    case CenterSquareType.NONE:
      return '';
    // Defensive: a raw runtime value outside the enum (e.g. a retired
    // 'custom_free' string that bypassed validation) returns no label rather
    // than undefined.
    default:
      return '';
  }
}
