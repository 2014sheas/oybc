import { deriveDisplayedCount } from '../../src/algorithms/sharedCounter';

/**
 * Tests for deriveDisplayedCount — the Phase 1 shared-counter math helper.
 *
 * Key invariants under test:
 *   1. LOW-END CLAMP: `displayed` is always >= 0 (Math.max(0, ...)).
 *   2. NO HIGH-END CLAMP: if source exceeds the derived task's maxCount,
 *      `displayed` must reflect the raw overshoot. No Math.min(...) is
 *      permitted inside deriveDisplayedCount (enforced by the "no clamp"
 *      test cases below).
 *   3. `isCompleted` flips once `displayed >= maxCount` — it is a snapshot,
 *      not a latch. The latch is Phase 3's responsibility.
 *
 * Swift mirror: `apps/ios/OYBC/Helpers/SharedCounter.swift` (same 6+ cases).
 */

describe('deriveDisplayedCount', () => {
  // ── Inherit baseline (baseline = 0) ─────────────────────────────────────────

  it('baseline=0, source < maxCount → displayed=source, isCompleted=false', () => {
    const result = deriveDisplayedCount(
      { baseline: 0, maxCount: 100 },
      { currentCount: 42 },
    );
    expect(result.displayed).toBe(42);
    expect(result.isCompleted).toBe(false);
  });

  it('baseline=0, source == maxCount → displayed=source, isCompleted=true', () => {
    const result = deriveDisplayedCount(
      { baseline: 0, maxCount: 100 },
      { currentCount: 100 },
    );
    expect(result.displayed).toBe(100);
    expect(result.isCompleted).toBe(true);
  });

  /**
   * NO HIGH-END CLAMP: this is the critical Phase 0 invariant.
   * If source.currentCount overshoots the derived task's maxCount, the
   * displayed value must be the raw overshoot, NOT clamped to maxCount.
   * isCompleted stays true — the task is already done and staying done.
   */
  it('baseline=0, source > maxCount → displayed=source (NO HIGH CLAMP), isCompleted=true', () => {
    const result = deriveDisplayedCount(
      { baseline: 0, maxCount: 5000 },
      { currentCount: 5500 },
    );
    // Must NOT be clamped to 5000.
    expect(result.displayed).toBe(5500);
    expect(result.isCompleted).toBe(true);
  });

  // ── Start-from-zero baseline (baseline = source count at link time) ──────────

  it('baseline>0, source > baseline → displayed = source - baseline', () => {
    // e.g. user had read 200 pages at link time; derived task targets 50 more pages.
    const result = deriveDisplayedCount(
      { baseline: 200, maxCount: 50 },
      { currentCount: 230 },
    );
    expect(result.displayed).toBe(30); // 230 - 200
    expect(result.isCompleted).toBe(false);
  });

  it('baseline>0, source = baseline + maxCount → displayed=maxCount, isCompleted=true', () => {
    const result = deriveDisplayedCount(
      { baseline: 200, maxCount: 50 },
      { currentCount: 250 },
    );
    expect(result.displayed).toBe(50);
    expect(result.isCompleted).toBe(true);
  });

  // ── Low-end clamp (defensive edge — shouldn't happen in production) ─────────

  it('baseline > source.currentCount (edge case) → displayed=0 (low-end clamp only)', () => {
    // This shouldn't happen in practice (a baseline is set from the source
    // count at link time, so the source can't go below it unless the user
    // manually decrements it). The math must defensively return 0, not a
    // negative number.
    const result = deriveDisplayedCount(
      { baseline: 100, maxCount: 50 },
      { currentCount: 80 }, // source dropped below baseline
    );
    expect(result.displayed).toBe(0); // Math.max(0, 80 - 100) === 0
    expect(result.isCompleted).toBe(false);
  });

  // ── Zero maxCount edge case ─────────────────────────────────────────────────

  it('maxCount=0 → isCompleted=true immediately (cannot be below zero progress)', () => {
    // A threshold of 0 means the task is instantly satisfied by any
    // non-negative displayed value, including 0. "Read 0 pages" is always done.
    const result = deriveDisplayedCount(
      { baseline: 0, maxCount: 0 },
      { currentCount: 0 },
    );
    expect(result.displayed).toBe(0);
    expect(result.isCompleted).toBe(true); // 0 >= 0
  });

  // ── Missing / undefined fields (defensive defaults) ─────────────────────────

  it('undefined baseline defaults to 0', () => {
    const result = deriveDisplayedCount(
      { maxCount: 10 },
      { currentCount: 5 },
    );
    expect(result.displayed).toBe(5);
  });

  it('undefined maxCount defaults to 0 — isCompleted=true immediately', () => {
    const result = deriveDisplayedCount(
      { baseline: 0 },
      { currentCount: 5 },
    );
    // maxCount defaults to 0; displayed (5) >= 0 → isCompleted
    expect(result.isCompleted).toBe(true);
  });

  it('undefined currentCount defaults to 0', () => {
    const result = deriveDisplayedCount(
      { baseline: 0, maxCount: 10 },
      {},
    );
    expect(result.displayed).toBe(0);
    expect(result.isCompleted).toBe(false);
  });
});
