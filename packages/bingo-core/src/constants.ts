/**
 * Board size options
 */
export const BOARD_SIZES = [3, 4, 5] as const;
export type BoardSize = typeof BOARD_SIZES[number];

/**
 * Center square behavior
 */
export enum CenterSquareType {
  FREE = 'free',                  // Auto-completed (traditional bingo), shows "FREE SPACE"
  CHOSEN = 'chosen',              // User-chosen center task, NOT auto-completed, toggleable
  NONE = 'none'                   // No center square (even-sized boards or no special treatment)
}
