import { useLiveQuery } from 'dexie-react-hooks';
import { resolveRecurringDraftMixTaskIds } from '../db/operations/recurringDraftMix';

/**
 * Resolves a recurring draft board's `recurringDraftMix` JSON into its
 * CURRENT resolved task-id set, reactively.
 *
 * Returns `undefined` while loading so `useDrafts`'s drafts-list task count
 * can distinguish "still loading" from "resolved empty". Pass `undefined`
 * for a board with no mix to short-circuit to an empty Set without a DB
 * round-trip.
 */
export function useRecurringDraftMix(mixJson: string | undefined): Set<string> | undefined {
  return useLiveQuery(async (): Promise<Set<string>> => {
    if (mixJson === undefined) return new Set();
    return new Set(await resolveRecurringDraftMixTaskIds(mixJson));
  }, [mixJson]);
}
