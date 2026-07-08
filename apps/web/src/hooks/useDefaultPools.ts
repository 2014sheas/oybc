import { useLiveQuery } from 'dexie-react-hooks';
import type { DefaultPool, Timeframe } from '@oybc/shared';
import { db } from '../db/internal';

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
 *
 * Returns a tri-state so callers can distinguish "still loading" from
 * "loaded but no pool exists":
 *   - `undefined` → `useLiveQuery` hasn't resolved yet (first render
 *     and any re-key on `[userId, timeframe]`).
 *   - `null` → resolved, no DefaultPool row for this `(userId, timeframe)`.
 *   - `DefaultPool` → resolved, row exists.
 *
 * Without this distinction, both the wizard's one-shot prefill effect
 * (`useBoardWizard`) and the editor page's hydration (`DefaultPoolEditorPage`)
 * stall forever for users who haven't configured a pool, and a pool
 * that arrives later via sync can stomp in-progress user selections.
 */
export function useDefaultPool(
  userId: string | undefined,
  timeframe: Timeframe | undefined,
): DefaultPool | null | undefined {
  return useLiveQuery(
    async (): Promise<DefaultPool | null> => {
      if (!userId || !timeframe) return null;
      const pool = await db.defaultPools
        .filter(
          (p) => p.userId === userId && p.timeframe === timeframe && !p.isDeleted,
        )
        .first();
      return pool ?? null;
    },
    [userId, timeframe],
  );
}
