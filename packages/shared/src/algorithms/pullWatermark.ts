/**
 * Per-collection pull checkpoint (2026-10-07, the iOS launch-watchdog fix).
 *
 * A pull checkpoints each collection at the highest server `_syncedAt` it has
 * applied, so a pull that is interrupted part-way resumes where it stopped
 * instead of re-applying everything from the old watermark. The value is the
 * server instant, never the local clock, so there is no clock-skew window on
 * the pull path. Resume queries use `>=` the stored value: same-instant
 * siblings of the last applied doc are re-read and the echo guard skips them.
 *
 * Swift twin: `apps/ios/OYBC/Services/PullWatermark.swift`, pinned by
 * `tests/fixtures/pullWatermarkVectors.json` on both platforms.
 */

/** A Firestore `Timestamp` instant, kept exact (no float rounding). */
export interface PullWatermark {
  seconds: number;
  nanoseconds: number;
}

/**
 * Orders two watermarks.
 *
 * @param a - First watermark.
 * @param b - Second watermark.
 * @returns Negative when `a < b`, positive when `a > b`, 0 when equal.
 */
export function comparePullWatermarks(a: PullWatermark, b: PullWatermark): number {
  if (a.seconds !== b.seconds) return a.seconds - b.seconds;
  return a.nanoseconds - b.nanoseconds;
}

/**
 * The checkpoint after applying one batch: the max of `prev` and every
 * non-null `_syncedAt` in the batch. Never moves backwards.
 *
 * @param prev - The stored checkpoint, or null/undefined when none.
 * @param syncedAts - The batch's `_syncedAt` instants (null/undefined for a
 *   doc without one, e.g. a pending server timestamp).
 * @returns The new checkpoint, or null when neither side has a value.
 */
export function nextPullWatermark(
  prev: PullWatermark | null | undefined,
  syncedAts: ReadonlyArray<PullWatermark | null | undefined>,
): PullWatermark | null {
  let best: PullWatermark | null = prev ?? null;
  for (const at of syncedAts) {
    if (!at) continue;
    if (!best || comparePullWatermarks(at, best) > 0) best = at;
  }
  return best ? { seconds: best.seconds, nanoseconds: best.nanoseconds } : null;
}
