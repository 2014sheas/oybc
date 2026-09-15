import { useLiveQuery } from 'dexie-react-hooks';
import { type Board, type Timeframe } from '@oybc/shared';
import { fetchCoreBoardsForTimeframe } from '../../db/operations';

/**
 * useCoreBoardsByStart — reactive map of the user's core boards for one
 * timeframe, keyed by `Board.startDate` (local ISO). Feeds the window
 * chip's position dots, the picker popover's tile states, AND (jank fix
 * 2026-09-15) the pager page's own board lookup — one always-loaded
 * source, so a step/jump renders the landed window's final state in the
 * same frame. Returns `undefined` only until the FIRST resolve (the
 * tri-state convention): callers must not treat loading as "no boards".
 *
 * `[userId+timeframe+status]` compound index, then `!isDeleted && isCore`
 * in memory — IndexedDB boolean keys are unreliable.
 */
export function useCoreBoardsByStart(
  userId: string | undefined,
  timeframe: Timeframe,
): Map<string, Board> | undefined {
  return useLiveQuery(
    async (): Promise<Map<string, Board>> => {
      if (!userId) return new Map();
      const boards = await fetchCoreBoardsForTimeframe(userId, timeframe);
      const map = new Map<string, Board>();
      for (const b of boards) map.set(b.startDate, b);
      return map;
    },
    [userId, timeframe],
  );
}
