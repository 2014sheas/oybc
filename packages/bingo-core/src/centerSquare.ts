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
 * FREE is auto-completed and locked (cannot toggle off). CHOSEN (legacy —
 * see {@link effectiveCenter}) and NONE are not auto-completed.
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

/**
 * The center type a live board BEHAVES as (Board Edit slice 3, D1).
 *
 * `CHOSEN` is legacy: slice 3 retired it in favour of per-square locks. It is
 * never migrated on disk (sealed rows must not mutate, and older peers still
 * write it); instead every consumer reads it through this function, which maps
 * CHOSEN → NONE. Paired with {@link isLegacyChosenCenterLocked}, a CHOSEN board
 * reads as "task-square center + locked center placement". FREE and NONE pass
 * through unchanged.
 *
 * Swift twin: `CenterSquare.effectiveCenter(_:)`.
 *
 * @param type - The stored center square type.
 * @returns `FREE` or `NONE` — never `CHOSEN`.
 */
export function effectiveCenter(
  type: CenterSquareType,
): CenterSquareType.FREE | CenterSquareType.NONE {
  return type === CenterSquareType.FREE
    ? CenterSquareType.FREE
    : CenterSquareType.NONE;
}

/**
 * Whether a stored center type is the legacy `CHOSEN` value.
 *
 * Used by the squares-editor Save to decide whether the on-disk row still
 * needs its one-time authored conversion (D2).
 *
 * Swift twin: `CenterSquare.isLegacyChosen(_:)`.
 *
 * @param type - The stored center square type.
 * @returns True iff `type` is `CHOSEN`.
 */
export function isLegacyChosen(type: CenterSquareType): boolean {
  return type === CenterSquareType.CHOSEN;
}

/**
 * Whether a placement at `(row, col)` is implicitly locked because its board
 * is legacy `CHOSEN` and the placement sits at the positional center (D1).
 *
 * Effective lock = `boardTask.isLocked || isLegacyChosenCenterLocked(...)`.
 * Takes primitives only so `bingo-core` stays free of Board/BoardTask types.
 *
 * Swift twin: `CenterSquare.isLegacyChosenCenterLocked(centerType:row:col:gridSize:)`.
 *
 * @param type - The board's stored center square type.
 * @param row - Placement row (0-based).
 * @param col - Placement column (0-based).
 * @param gridSize - Board size (odd sizes have a positional center).
 * @returns True iff CHOSEN and `(row, col)` is the positional center.
 */
export function isLegacyChosenCenterLocked(
  type: CenterSquareType,
  row: number,
  col: number,
  gridSize: number,
): boolean {
  if (type !== CenterSquareType.CHOSEN) return false;
  const centerIndex = getCenterSquareIndex(gridSize);
  if (centerIndex < 0) return false;
  return row * gridSize + col === centerIndex;
}
