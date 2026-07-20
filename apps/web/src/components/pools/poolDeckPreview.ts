import { CenterSquareType, fillableCellCount } from '@oybc/shared';
import type { RecurringBoardTemplate } from '@oybc/shared';

/** The floor a deck-preview line measures a pool's live task count against. */
export interface DeckFloor {
  /** Board edge length the floor corresponds to (for the "S×S" copy). */
  boardSize: number;
  /** `fillableCellCount(boardSize, centerType)` for the owning consumer. */
  floor: number;
}

/**
 * Default floor for a pool with no active consumers (including every
 * brand-new pool): a 3×3 board with a FREE center — `fillableCellCount(3,
 * FREE) === 8`. Matches the prototype's "fills a 3×3" copy on a fresh
 * "New pool" sheet.
 */
const DEFAULT_DECK_FLOOR: DeckFloor = {
  boardSize: 3,
  floor: fillableCellCount(3, CenterSquareType.FREE),
};

/**
 * The floor the pool-edit sheet's deck-preview line measures against: the
 * SMALLEST fillable floor among the pool's active, non-deleted consumers
 * (repeating-board spawn records whose `poolIds` include this pool), or
 * the 3×3-FREE default when there are none. Mirrors the "smallest
 * consuming floor" rule in docs/POOLS_RECURRING.md §Surfaces item 2.
 */
export function computeDeckFloor(
  templates: readonly RecurringBoardTemplate[],
  poolId: string,
): DeckFloor {
  let best: DeckFloor | null = null;
  for (const template of templates) {
    if (template.isDeleted || !template.isActive) continue;
    if (!(template.poolIds ?? []).includes(poolId)) continue;

    const floor = fillableCellCount(template.boardSize, template.centerSquareType);
    if (!best || floor < best.floor) {
      best = { boardSize: template.boardSize, floor };
    }
  }
  return best ?? DEFAULT_DECK_FLOOR;
}

/**
 * Formats the pool-edit sheet's dashed deck-preview line:
 * `"{N} tasks in the deck · fills a {S}×{S}"` when the live task count
 * meets the floor, or `"{N} tasks in the deck · {shortBy} short of a
 * {S}×{S}"` when it doesn't. Web-local copy (not the cross-platform
 * `formatPoolShortWarning`, which names the consuming template/timeframe
 * for the pool-card warning line instead).
 */
export function formatDeckPreview(taskCount: number, deckFloor: DeckFloor): string {
  const base = `${taskCount} task${taskCount === 1 ? '' : 's'} in the deck`;
  const { boardSize, floor } = deckFloor;
  if (taskCount >= floor) {
    return `${base} · fills a ${boardSize}×${boardSize}`;
  }
  const shortBy = floor - taskCount;
  return `${base} · ${shortBy} short of a ${boardSize}×${boardSize}`;
}
