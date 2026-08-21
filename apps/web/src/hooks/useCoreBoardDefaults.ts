import { useLiveQuery } from 'dexie-react-hooks';
import type { CoreBoardDefault, Timeframe } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Live snapshot of a single `CoreBoardDefault` by `(userId, timeframe)`
 * (Task Pools + Recurring Boards Rework, P5). Mirrors `useDefaultPool`'s
 * tri-state contract exactly — it replaces that hook at the core-board-
 * setup prefill call site:
 *   - `undefined` → `useLiveQuery` hasn't resolved yet (first render and
 *     any re-key on `[userId, timeframe]`).
 *   - `null` → resolved, no `CoreBoardDefault` row for this
 *     `(userId, timeframe)`.
 *   - `CoreBoardDefault` → resolved, row exists.
 *
 * Without this distinction, the wizard's one-shot core-board-default
 * prefill effect (`useBoardWizard`) would stall forever for users who
 * haven't configured a default, and a row that arrives later via sync
 * could stomp in-progress user selections.
 *
 * Because this is a live query, a write via `upsertCoreBoardDefault`
 * (e.g. the "Start every &lt;Timeframe&gt; board with 'X'" checkbox)
 * refreshes this hook's result automatically — no manual refetch needed.
 */
export function useCoreBoardDefault(
  userId: string | undefined,
  timeframe: Timeframe | undefined,
): CoreBoardDefault | null | undefined {
  return useLiveQuery(
    async (): Promise<CoreBoardDefault | null> => {
      if (!userId || !timeframe) return null;
      const row = await db.coreBoardDefaults
        .filter((d) => d.userId === userId && d.timeframe === timeframe && !d.isDeleted)
        .first();
      return row ?? null;
    },
    [userId, timeframe],
  );
}
