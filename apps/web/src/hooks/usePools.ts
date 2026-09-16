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

/**
 * Tri-state variant of {@link usePools}: `undefined` until the first
 * resolve, so callers can tell "no pools" from "not read yet".
 *
 * Late-mutation audit (2026-09-16, shape B): collapsing the loading
 * state to `[]` made the wizard render a pulled pool as "Deleted pool ·
 * 0 squares" and briefly disable Next. Callers that render COPY about a
 * pool (rather than just listing pools) should use this.
 * See `reference_late_mutation_bug_class`.
 */
export function usePoolsQuery(userId: string | undefined): Pool[] | undefined {
  return useLiveQuery(
    async (): Promise<Pool[]> => {
      if (!userId) return [];
      return db.pools.filter((p) => p.userId === userId && !p.isDeleted).toArray();
    },
    [userId],
  );
}
