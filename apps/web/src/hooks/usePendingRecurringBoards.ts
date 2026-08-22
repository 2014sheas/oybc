import { useLiveQuery } from 'dexie-react-hooks';
import {
  getCoreBoardSlots,
  mergeUserPreferences,
  type CoreBoardSlot,
} from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Reactive hook returning one slot per *enabled* recurring timeframe
 * (daily/weekly/monthly/yearly), with `currentBoard` populated when an
 * `isCore=true` board exists for the current window. Backs the Boards-tab
 * `CoreStrip` — the single core-board setup surface (the separate
 * "new windows" prompt banner was removed as a duplicate).
 *
 * Loads the user row (for prefs) + their non-deleted boards; rebuilds
 * whenever boards / preferences change in Dexie. Returns `[]` while
 * loading, when signed out, or when no recurring timeframes are enabled.
 */
export function useCoreBoardSlots(
  userId: string | undefined,
): CoreBoardSlot[] {
  return (
    useLiveQuery(
      async (): Promise<CoreBoardSlot[]> => {
        if (!userId) return [];

        const [user, userBoards] = await Promise.all([
          db.users.get(userId),
          db.boards
            .filter((b) => b.userId === userId && !b.isDeleted)
            .toArray(),
        ]);

        const prefs = mergeUserPreferences(user?.preferences);
        return getCoreBoardSlots(userBoards, prefs, new Date());
      },
      [userId],
      [],
    ) ?? []
  );
}
