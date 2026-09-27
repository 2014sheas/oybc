import { useEffect, useRef } from 'react';
import { runBackstopAutoSeal, reDeriveActiveBoards } from '../db/operations/sealing';
import { repairPlacementIntegrity } from '../db/operations/placementIntegrity';
import { getSyncStatus, subscribeSyncStatus } from '../firebase/syncStatus';

/**
 * Board Edit redesign slice 4 (D5) — resolves once the session's first full
 * `pullSync` pass has finished (`firstPullCompleted` — every collection,
 * boards included, not merely the first applied doc), or after `timeoutMs`
 * (offline / a slow first sync), whichever comes first. Offline (per
 * `navigator.onLine`) resolves immediately — mirrors today's on-mount
 * posture when there is nothing to wait for.
 *
 * Why: with `reopenedAt`, a device that hasn't yet pulled a peer's Reopen
 * would re-seal that board under the auto-close rule with a version bump
 * that can win LWW (WC §Lifecycle step 4 already names post-first-pull as
 * preferred for exactly this reason).
 */
function waitForFirstPullOrTimeout(timeoutMs = 10_000): Promise<void> {
  return new Promise((resolve) => {
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      resolve();
      return;
    }
    if (getSyncStatus().firstPullCompleted) {
      resolve();
      return;
    }
    let settled = false;
    let timer: ReturnType<typeof setTimeout>;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      unsubscribe();
      clearTimeout(timer);
      resolve();
    };
    const unsubscribe = subscribeSyncStatus(() => {
      if (getSyncStatus().firstPullCompleted) finish();
    });
    timer = setTimeout(finish, timeoutMs);
  });
}

/**
 * Windowed Completion — lazy auto-seal backstop hook
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle step 4).
 *
 * Mounted by `BoardsPage`; runs once per user on mount. Mirrors the
 * recurring-spawn lazy-detection posture (`useRecurringBoardSpawn`): boards
 * past their auto-close deadline (the end of the NEXT window of their
 * timeframe — `computeAutoCloseDeadlineMs`; never for a reopened board) are
 * sealed when the user opens
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
        await waitForFirstPullOrTimeout();
        if (cancelled) return;
        await runBackstopAutoSeal(userId);
        if (cancelled) return;
        // Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 1) —
        // placement-integrity repair PRE-step: tombstone corrupted
        // duplicate/out-of-bounds placement rows BEFORE re-deriving stats
        // below, so the re-derive sees the already-clean placement set.
        // Idempotent; runs after the backstop (a board sealed by the pass
        // above is still in scope here — repair covers every status).
        await repairPlacementIntegrity(userId);
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
