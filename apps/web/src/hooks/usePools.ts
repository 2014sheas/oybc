import { useLiveQuery } from 'dexie-react-hooks';
import type { Pool } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Live snapshot of the user's non-deleted Pools (Task Pools + Recurring
 * Boards Rework, P2). Powers the Tasks-tab Pools segment (`Pools · N` count
 * + pool cards) and the pool edit sheet's "already in this pool" checks.
 *
 * Mirrors `useDefaultPools`/`useRecurringBoardTemplates`'s JS-filter
 * pattern rather than a compound IndexedDB index — a boolean index doesn't
 * roundtrip `false` vs `0` reliably across browsers.
 *
 * Returns `[]` while loading or when the user is signed out.
 */
export function usePools(userId: string | undefined): Pool[] {
  return (
    useLiveQuery(
      async (): Promise<Pool[]> => {
        if (!userId) return [];
        return db.pools.filter((p) => p.userId === userId && !p.isDeleted).toArray();
      },
      [userId],
      [],
    ) ?? []
  );
}
