import { useEffect, useRef } from 'react';
import { runBackstopAutoSeal } from '../db/operations/sealing';

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
 * so this hook returns nothing. An in-flight guard blocks re-entry across
 * fast route re-mounts; `sealBoard` is itself idempotent so a double-run is a
 * no-op regardless.
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
