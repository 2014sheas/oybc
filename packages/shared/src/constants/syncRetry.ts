/**
 * Exponential backoff schedule (milliseconds) for retrying FAILED sync
 * queue items. Indexed by `retryCount`: an item with `retryCount === 1`
 * (one prior failure) becomes eligible for re-promotion to PENDING
 * `SYNC_RETRY_BACKOFF_MS[0]` ms after its `lastAttemptAt`.
 *
 * After `MAX_SYNC_RETRIES` failures, the item stays FAILED until
 * either a fresh enqueue replaces it or a manual retry from the
 * playground SyncDashboard.
 *
 * Schedule choice: aggressive enough that a transient network blip
 * (~30 s) clears quickly, slow enough that a server outage doesn't
 * thrash. The cap of 1 hr means the worst-case wait between retries
 * once steady-state is hit.
 */
export const SYNC_RETRY_BACKOFF_MS: readonly number[] = [
  30 * 1000,         // first retry: 30s after failure
  2 * 60 * 1000,     // second:      2 min
  10 * 60 * 1000,    // third:       10 min
  30 * 60 * 1000,    // fourth:      30 min
  60 * 60 * 1000,    // fifth:       1 hour (cap)
];

/**
 * Returns true when a FAILED sync queue item has waited long enough
 * since its last attempt to be re-promoted to PENDING.
 *
 * @param retryCount - the item's current `retryCount` (1 after first failure)
 * @param lastAttemptAtMs - the item's `lastAttemptAt` as epoch ms; `null`
 *   for items that somehow have no attempt timestamp (treat as eligible)
 * @param nowMs - current time as epoch ms (injectable for testability)
 * @returns true if the elapsed wait meets or exceeds the backoff for
 *   this retryCount, false otherwise
 */
export function isFailedItemEligibleForRetry(
  retryCount: number,
  lastAttemptAtMs: number | null,
  nowMs: number
): boolean {
  // Index by retryCount - 1 (item has failed retryCount times so far).
  // Clamp to schedule length so a misbehaving item with retryCount above
  // the schedule length still uses the cap interval.
  const idx = Math.min(Math.max(0, retryCount - 1), SYNC_RETRY_BACKOFF_MS.length - 1);
  const backoff = SYNC_RETRY_BACKOFF_MS[idx];
  if (lastAttemptAtMs == null) return true;
  return nowMs - lastAttemptAtMs >= backoff;
}
