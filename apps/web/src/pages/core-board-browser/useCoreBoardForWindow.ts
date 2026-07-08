import { useLiveQuery } from 'dexie-react-hooks';
import { Timeframe, type Board } from '@oybc/shared';
import { fetchCoreBoardsForTimeframe } from '../../db/operations';

/**
 * useCoreBoardForWindow — reactive lookup of the user's core board for a
 * single `(timeframe, windowStart)`. Returns `undefined` while the query
 * is resolving, then `Board | null`. Same index + JS-filter strategy as
 * `useCoreBoardBrowser` (the `[userId+timeframe+status]` compound, then
 * `!isDeleted && isCore` in memory — IndexedDB boolean keys are unreliable).
 */
export function useCoreBoardForWindow(
  userId: string | undefined,
  timeframe: Timeframe,
  windowStart: string,
): Board | null | undefined {
  return useLiveQuery(
    async (): Promise<Board | null> => {
      if (!userId) return null;
      const boards = await fetchCoreBoardsForTimeframe(userId, timeframe);
      return boards.find((b) => b.startDate === windowStart) ?? null;
    },
    [userId, timeframe, windowStart],
  );
}
