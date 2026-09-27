import { resolvePlacements, type BoardSize, type BoardTask } from '@oybc/shared';

// Frozen stable fallback (React Compiler memoization — see useBoardPlayData).
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];

/** A board's placements plus whether the live query has resolved. */
export interface BoardPlacementsQueryResult {
  /** The resolved (winner-rule, in-bounds, non-tombstoned) placements. */
  boardTasks: BoardTask[];
  /**
   * True once the placements query has resolved — INCLUDING to zero rows.
   * A board with no squares is a loaded board, not a loading one; callers
   * must gate "Loading…" on this, never on `boardTasks.length === 0`.
   */
  loaded: boolean;
}

/**
 * Resolve a board's raw live-query placements into the render-ready list,
 * keeping "still loading" (`undefined`) distinct from "loaded, empty" (`[]`).
 *
 * @param query - The raw live-query result: `undefined` while unresolved.
 * @param gridSize - The board's size, for `resolvePlacements`' bounds drop.
 * @returns The resolved placements and the loaded flag.
 */
export function resolveBoardPlacementsQuery(
  query: BoardTask[] | undefined,
  gridSize: BoardSize,
): BoardPlacementsQueryResult {
  if (query === undefined) return { boardTasks: EMPTY_BOARD_TASKS, loaded: false };
  const boardTasks = query.length === 0 ? query : resolvePlacements(query, gridSize);
  return { boardTasks, loaded: true };
}
