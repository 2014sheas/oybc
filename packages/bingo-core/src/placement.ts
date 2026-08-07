import { CenterSquareType } from './constants';
import { getCenterSquareIndex, isCenterAutoCompleted } from './centerSquare';
import { fisherYatesShuffle } from './shuffle';

/**
 * Arguments for {@link placeBoard} — the single board-placement core shared
 * by the wizard-preview and template-spawn paths on both platforms.
 *
 * @typeParam T - The item type. Only an `id` is required so the core stays
 *   domain-agnostic (Play passes a lighter shape than Do's `Task`).
 */
export interface PlaceBoardArgs<T extends { id: string }> {
  /** Candidate items in the caller's preferred order (used verbatim when `randomize=false`). */
  items: readonly T[];
  /** Board edge length (3, 4, 5, …). */
  gridSize: number;
  /** Center square behaviour. Ignored for even grids (no center exists). */
  centerType: CenterSquareType;
  /**
   * CHOSEN center: id of the item pinned to the center cell. Ignored for
   * other center types / even grids. If the id doesn't resolve to an item
   * in `items`, the center is treated as ordinary (matches the web wizard's
   * `?? null` fallback).
   */
  chosenCenterId?: string;
  /** Shuffle the fill pool when true; preserve `items` order when false. */
  randomize: boolean;
  /**
   * Uniform `[0, 1)` RNG for the shuffle. Defaults to `Math.random`. Tests
   * and server-side fan-out pass a seeded RNG for deterministic placement.
   */
  rng?: () => number;
}

/**
 * Places `items` onto a `gridSize²` board, honouring the center-square rules.
 *
 * Superset of the four historical placement sites (web/iOS wizard,
 * shared/iOS spawn). Semantics:
 *
 *   1. `centerIdx = getCenterSquareIndex(gridSize)`; even grids have no
 *      center (every cell is ordinary).
 *   2. Odd grid + CHOSEN + a `chosenCenterId` that resolves → pin that item
 *      at `centerIdx` and exclude it from the fill pool. Unresolvable id →
 *      ordinary center.
 *   3. Odd grid + FREE → center stays `null` (reserved; the
 *      render layer draws the FREE label).
 *   4. NONE (or even grid) → center is filled like any other cell.
 *   5. Fill pool = `items` minus any pinned center item;
 *      `randomize ? fisherYatesShuffle(pool, rng) : pool` (order-preserving
 *      when not randomizing — callers own their deterministic ordering).
 *   6. Walk cells `0..gridSize²-1` row-major, skipping the pinned/reserved
 *      center, placing the next pool item. Extra items are ignored
 *      (loose-fit spawn pools); an exhausted pool leaves `null`s (wizard
 *      preview mid-selection).
 *
 * Never mutates `items` (the shuffle copies).
 *
 * @returns A length `gridSize²` array; `null` = empty cell (reserved
 *   FREE center, or pool underfill).
 */
export function placeBoard<T extends { id: string }>(
  args: PlaceBoardArgs<T>,
): (T | null)[] {
  const { items, gridSize, centerType, chosenCenterId, randomize, rng } = args;
  const total = gridSize * gridSize;
  const centerIdx = getCenterSquareIndex(gridSize); // -1 for even grids
  const hasCenter = centerIdx >= 0;

  const chosenCenter: T | null =
    hasCenter && centerType === CenterSquareType.CHOSEN && chosenCenterId != null
      ? items.find((t) => t.id === chosenCenterId) ?? null
      : null;

  const pool: readonly T[] =
    chosenCenter !== null ? items.filter((t) => t.id !== chosenCenter.id) : items;
  const ordered = randomize ? fisherYatesShuffle(pool, rng) : pool;

  const grid: (T | null)[] = new Array(total).fill(null);
  let next = 0;
  for (let cell = 0; cell < total; cell++) {
    if (cell === centerIdx) {
      if (chosenCenter !== null) {
        grid[cell] = chosenCenter;
        continue;
      }
      if (isCenterAutoCompleted(centerType)) {
        // Reserved FREE center — leave null.
        continue;
      }
      // NONE on an odd grid: fall through and place a regular item here.
    }
    if (next < ordered.length) {
      grid[cell] = ordered[next];
      next += 1;
    }
  }
  return grid;
}

/**
 * Number of cells a task pool must fill: total cells minus a reserved
 * center. Even grids have no center; odd grids reserve one cell only when
 * the center is auto-completed (FREE). CHOSEN / NONE centers
 * hold a regular task, so they don't reduce the count.
 *
 * Moved verbatim from `recurringBoardTemplates.ts` (which now re-exports it).
 *
 * @param gridSize - Board edge length.
 * @param centerType - Center square behaviour.
 * @returns The number of cells a pool must fill.
 */
export function fillableCellCount(
  gridSize: number,
  centerType: CenterSquareType,
): number {
  const total = gridSize * gridSize;
  const centerIdx = getCenterSquareIndex(gridSize);
  const hasCenter = centerIdx >= 0;
  const centerOmitsTask = hasCenter && isCenterAutoCompleted(centerType);
  return total - (centerOmitsTask ? 1 : 0);
}
