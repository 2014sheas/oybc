import {
  SYNC_RETRY_BACKOFF_MS,
  isFailedItemEligibleForRetry,
  MAX_SYNC_RETRIES,
} from '../../src/constants';

describe('SYNC_RETRY_BACKOFF_MS', () => {
  it('matches MAX_SYNC_RETRIES in length', () => {
    expect(SYNC_RETRY_BACKOFF_MS).toHaveLength(MAX_SYNC_RETRIES);
  });

  it('is monotonically non-decreasing', () => {
    for (let i = 1; i < SYNC_RETRY_BACKOFF_MS.length; i++) {
      expect(SYNC_RETRY_BACKOFF_MS[i]).toBeGreaterThanOrEqual(SYNC_RETRY_BACKOFF_MS[i - 1]);
    }
  });
});

describe('isFailedItemEligibleForRetry', () => {
  const NOW = 1_000_000_000_000; // arbitrary fixed reference

  it('treats a missing lastAttemptAt as immediately eligible', () => {
    expect(isFailedItemEligibleForRetry(1, null, NOW)).toBe(true);
  });

  it('returns false before the backoff window has elapsed', () => {
    const justAttempted = NOW - 1_000; // 1s ago — well under the 30s first-retry window
    expect(isFailedItemEligibleForRetry(1, justAttempted, NOW)).toBe(false);
  });

  it('returns true after the backoff window elapses', () => {
    const longAgo = NOW - (31 * 1000); // 31s ago — past the 30s first-retry window
    expect(isFailedItemEligibleForRetry(1, longAgo, NOW)).toBe(true);
  });

  it('uses progressively longer backoffs for higher retryCounts', () => {
    // 31s elapsed is enough for retryCount=1 (30s window) but not for
    // retryCount=2 (2 minute window).
    const elapsed31s = NOW - 31_000;
    expect(isFailedItemEligibleForRetry(1, elapsed31s, NOW)).toBe(true);
    expect(isFailedItemEligibleForRetry(2, elapsed31s, NOW)).toBe(false);
  });

  it('clamps retryCount above the schedule length to the cap interval', () => {
    // retryCount 99 should use the same backoff as retryCount 5 (the cap).
    const cap = SYNC_RETRY_BACKOFF_MS.at(-1)!;
    const justBeforeCap = NOW - (cap - 1);
    const justAfterCap = NOW - (cap + 1);
    expect(isFailedItemEligibleForRetry(99, justBeforeCap, NOW)).toBe(false);
    expect(isFailedItemEligibleForRetry(99, justAfterCap, NOW)).toBe(true);
  });

  it('treats retryCount of 0 as if it were the first retry', () => {
    // Defensive — items that somehow have retryCount 0 shouldn't crash.
    const elapsed31s = NOW - 31_000;
    expect(isFailedItemEligibleForRetry(0, elapsed31s, NOW)).toBe(true);
  });
});
