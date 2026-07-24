import { useEffect, useRef } from 'react';
import { runBackstopAutoSeal, reDeriveActiveBoards } from '../db/operations/sealing';

/**
 * Windowed Completion — lazy auto-seal backstop hook
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle step 4).
 *
 * Mounted by `BoardsPage`; runs once per user on mount. Mirrors the
 * recurring-spawn lazy-detection posture (`useRecurringBoardSpawn`): boards
 * past their timeframe-scaled backstop deadline are sealed when the user opens
 * the Boards tab — never background-scheduled, never a DB write without a user
 * having opened the app (the house lazy-detection invariant).
 *
 * Fire-and-forget: sealed boards re-render via the reactive `useBoards` query,
 * so this hook returns nothing. The in-flight guard is PER-INSTANCE (a ref):
 * it blocks re-entry within one mounted instance, but two mounted instances
 * (e.g. the AppShell mount + a page-level mount) each run their own pass —
 * harmless, since IndexedDB serializes the writes and both passes
 * compare-before-write (the second no-ops); `sealBoard` is itself idempotent
 * so a double-run is a no-op regardless.
 *
 * @param userId The authenticated user's uid, or undefined when signed out.
 */
export function useBackstopAutoSeal(userId: string | undefined): void {
  const inFlightRef = useRef(false);

  useEffect(() => {
    if (!userId) return;
    let cancelled = false;

    void (async () => {
      if (inFlightRef.current) return;
      inFlightRef.current = true;
      try {
        if (cancelled) return;
        await runBackstopAutoSeal(userId);
        if (cancelled) return;
        // Windowed Completion self-heal — correct any board carrying stale
        // lifetime-derived stats from the pre-fix edit/structure cascades
        // (phantom bingo lines). Idempotent; runs after the backstop so newly
        // sealed boards drop out of the active set here.
        await reDeriveActiveBoards(userId);
      } catch (err) {
        console.error('[backstop-auto-seal] failed', err);
      } finally {
        inFlightRef.current = false;
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [userId]);
}
