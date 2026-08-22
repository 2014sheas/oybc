import { useLiveQuery } from 'dexie-react-hooks';
import { resolveRecurringDraftMixTaskIds } from '../db/operations/recurringDraftMix';

/**
 * Resolves a recurring draft board's `recurringDraftMix` JSON into its
 * CURRENT resolved task-id set, reactively.
 *
 * Board Creation Split (web PR D) — mirrors `useTemplateMix`'s tri-state
 * convention (`undefined` while loading / when there's nothing to resolve)
 * so `useBoardWizard`'s one-shot hydration effect and `useDrafts`'s
 * drafts-list task count can distinguish "still loading" from "resolved
 * empty". Pass `undefined` for a one-off draft (or any board with no mix)
 * to short-circuit to an empty resolved Set without a DB round-trip.
 */
export function useRecurringDraftMix(mixJson: string | undefined): Set<string> | undefined {
  return useLiveQuery(async (): Promise<Set<string>> => {
    if (mixJson === undefined) return new Set();
    return new Set(await resolveRecurringDraftMixTaskIds(mixJson));
  }, [mixJson]);
}
