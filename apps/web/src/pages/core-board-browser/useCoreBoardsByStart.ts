import { useLiveQuery } from 'dexie-react-hooks';
import { type Board, type Timeframe } from '@oybc/shared';
import { fetchCoreBoardsForTimeframe } from '../../db/operations';

/**
 * useCoreBoardsByStart — reactive map of the user's core boards for one
 * timeframe, keyed by `Board.startDate` (local ISO). Feeds the window
 * chip's position dots and the picker popover's tile states.
 *
 * Same index + JS-filter strategy as `useCoreBoardForWindow` (the
 * `[userId+timeframe+status]` compound, then `!isDeleted && isCore` in
 * memory — IndexedDB boolean keys are unreliable).
 */
export function useCoreBoardsByStart(
  userId: string | undefined,
  timeframe: Timeframe,
): Map<string, Board> {
  return useLiveQuery(
    async (): Promise<Map<string, Board>> => {
      if (!userId) return new Map();
      const boards = await fetchCoreBoardsForTimeframe(userId, timeframe);
      const map = new Map<string, Board>();
      for (const b of boards) map.set(b.startDate, b);
      return map;
    },
    [userId, timeframe],
    new Map<string, Board>(),
  );
}
