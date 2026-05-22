import { useLiveQuery } from 'dexie-react-hooks';
import { Timeframe, type Board } from '@oybc/shared';
import { db } from '../../db/database';

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
      const boards = await db.boards
        .where('[userId+timeframe+status]')
        .between(
          [userId, timeframe, ''] as readonly unknown[],
          [userId, timeframe, '￿'] as readonly unknown[],
        )
        .and((b) => !b.isDeleted && b.isCore === true && b.startDate === windowStart)
        .toArray();
      return boards[0] ?? null;
    },
    [userId, timeframe, windowStart],
  );
}
