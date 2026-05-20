import { useLiveQuery } from 'dexie-react-hooks';
import type { DefaultPool, Timeframe } from '@oybc/shared';
import { db } from '../db/database';

/**
 * Live snapshot of the user's non-deleted DefaultPools. Used by the
 * Profile section to render the per-timeframe summary list.
 */
export function useDefaultPools(userId: string | undefined): DefaultPool[] {
  return (
    useLiveQuery(
      async (): Promise<DefaultPool[]> => {
        if (!userId) return [];
        // JS filter mirrors the codebase pattern (see `useBoards`,
        // `useRecurringBoardTemplates`) — Dexie's boolean-index match
        // doesn't roundtrip cleanly across older `false` vs `0` rows.
        return db.defaultPools
          .filter((p) => p.userId === userId && !p.isDeleted)
          .toArray();
      },
      [userId],
      [],
    ) ?? []
  );
}

/**
 * Live snapshot of a single DefaultPool by `(userId, timeframe)`.
 * Returns undefined when none exists for this pair. Drives the editor
 * page's hydration and the wizard's prefill lookup.
 */
export function useDefaultPool(
  userId: string | undefined,
  timeframe: Timeframe | undefined,
): DefaultPool | undefined {
  return useLiveQuery(
    async (): Promise<DefaultPool | undefined> => {
      if (!userId || !timeframe) return undefined;
      return db.defaultPools
        .filter(
          (p) => p.userId === userId && p.timeframe === timeframe && !p.isDeleted,
        )
        .first();
    },
    [userId, timeframe],
  );
}
