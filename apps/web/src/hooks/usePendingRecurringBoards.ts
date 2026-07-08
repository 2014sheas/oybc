import { useLiveQuery } from 'dexie-react-hooks';
import {
  findPendingRecurringBoards,
  getCoreBoardSlots,
  mergeUserPreferences,
  type CoreBoardSlot,
  type PendingRecurringBoard,
} from '@oybc/shared';
import { db } from '../db/internal';

/**
 * React hook returning the set of recurring board windows the user should
 * be prompted to create. Reactive: rebuilds whenever the user's boards or
 * preferences change in Dexie. Order is longest-window-first.
 *
 * Shared logic lives in `findPendingRecurringBoards` (`@oybc/shared`); this
 * hook is a thin Dexie wrapper that:
 *   1. Loads the authenticated user's row to read their preferences.
 *   2. Loads the user's non-deleted boards (subset is enough — soft-deleted
 *      rows are skipped inside the algorithm too, but pre-filtering keeps
 *      the iteration tight).
 *   3. Snapshots `now` per recompute so the same render returns a stable
 *      list of pending windows.
 *
 * Returns `[]` while the queries are loading, when the user is signed out,
 * or when no windows are pending. Callers can render the banner only when
 * the array is non-empty.
 */
export function usePendingRecurringBoards(
  userId: string | undefined
): PendingRecurringBoard[] {
  return (
    useLiveQuery(
      async (): Promise<PendingRecurringBoard[]> => {
        if (!userId) return [];

        const [user, userBoards] = await Promise.all([
          db.users.get(userId),
          db.boards
            .filter((b) => b.userId === userId && !b.isDeleted)
            .toArray(),
        ]);

        const prefs = mergeUserPreferences(user?.preferences);
        return findPendingRecurringBoards(userBoards, prefs, new Date());
      },
      [userId],
      []
    ) ?? []
  );
}

/**
 * Reactive variant that returns one slot per *enabled* recurring
 * timeframe (daily/weekly/monthly/yearly), with `currentBoard`
 * populated when an `isCore=true` board exists for the current window.
 * Used by the persistent home-screen Core Boards section — distinct
 * from `usePendingRecurringBoards` which only surfaces timeframes
 * needing creation.
 *
 * Same Dexie deps as the pending hook, so a board create / delete
 * / preference change reactively updates both. Returns `[]` while
 * loading, when the user is signed out, or when no recurring
 * timeframes are enabled at all.
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
