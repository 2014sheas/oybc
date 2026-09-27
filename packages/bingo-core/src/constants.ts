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
  /**
   * @deprecated Legacy (Board Edit slice 3): superseded by per-square locks.
   * Still decodable — old peers, sealed rows and wizard drafts carry it — but
   * live boards read it via `effectiveCenter` (→ NONE + a locked center), and
   * slice-3+ clients never write it except on wizard drafts.
   */
  CHOSEN = 'chosen',              // Legacy user-chosen center task, NOT auto-completed
  NONE = 'none'                   // No center square (even-sized boards or no special treatment)
}
