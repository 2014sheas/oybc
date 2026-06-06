import { additiveMergeCount, needsAdditiveMerge } from '../../src/algorithms/sharedCounterMerge';
import type { MergeCountResult } from '../../src/algorithms/sharedCounterMerge';

/**
 * Tests for `additiveMergeCount` and `needsAdditiveMerge` — Phase 4 conflict
 * resolution for shared-counter source tasks.
 *
 * Key invariants under test:
 *   1. Two devices increment the same source from the same starting point:
 *      merged = local + remote - common (additive, not LWW).
 *   2. Only one device increments: merged = the incremented value (delta
 *      from common preserved; the other device's zero-delta contributes 0).
 *   3. Three-way multi-device sequence: A +5, B +3 offline; merge = 18.
 *   4. Negative deltas (decrements): respected, merged reflects net change.
 *   5. Counter overshoot preserved through merge — NO Math.min(merged, maxCount).
 *   6. `lastSyncedCount = null` → falls back to LWW (no common ancestor known).
 *   7. `mergeApplied` flag accurately reflects whether merge or LWW was used.
 *
 * Swift mirror: `apps/ios/OYBC/Helpers/SharedCounterMerge.swift` (same cases).
 */

describe('additiveMergeCount', () => {
  // ── Core additive-merge cases ─────────────────────────────────────────────

  /**
   * Invariant 1 — both devices increment concurrently.
   * Starting count: 10. Device A: +5 → 15. Device B: +3 → 13.
   * Expected: 10 + 5 + 3 = 18 (not 15 or 13).
   */
  it('both devices increment from same base: merged = local + remote - lastSynced', () => {
    const result = additiveMergeCount(15, 13, 10);
    expect(result.merged).toBe(18); // remoteCount(13) + localDelta(15-10=5) = 18
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 2a — only the local device incremented.
   * lastSyncedCount=10, local=15, remote=10 (remote unchanged).
   * Remote delta = 0, local delta = +5. Merged = 10 + 5 = 15.
   */
  it('only local device incremented: merged = local value (remote delta is 0)', () => {
    const result = additiveMergeCount(15, 10, 10);
    expect(result.merged).toBe(15); // remote(10) + localDelta(5) = 15
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 2b — only the remote device incremented.
   * lastSyncedCount=10, local=10, remote=13 (local unchanged).
   * Local delta = 0. Merged = 13 + 0 = 13.
   */
  it('only remote device incremented: merged = remote value (local delta is 0)', () => {
    const result = additiveMergeCount(10, 13, 10);
    expect(result.merged).toBe(13); // remote(13) + localDelta(0) = 13
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 3 — Three-way multi-device scenario.
   *
   * Both start at 10. Device A increments to 15 and pushes first.
   * Device B was offline at 10 (lastSyncedCount=10) and incremented to 13.
   * Device B pulls remote (now 15) and runs additive merge before pushing.
   *
   * merge(local=13, remote=15, lastSynced=10):
   *   localDelta = 13 - 10 = 3
   *   merged = 15 + 3 = 18
   *
   * Device B pushes 18. Final counter on all devices = 18 = 10 + 5 + 3.
   */
  it('three-way sequence: A +5, B +3 offline; B merges against A push; result = 18', () => {
    // Device B merging after pulling Device A's push of 15.
    const result = additiveMergeCount(13, 15, 10);
    expect(result.merged).toBe(18);
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 4 — Negative delta (decrement to fix an over-count).
   * lastSyncedCount=20, local=17 (user decremented by 3 to correct a typo).
   * Remote incremented to 25 while offline.
   * Expected: remote(25) + localDelta(-3) = 22.
   * The local correction is honoured; the net effect is: remote gained 5, local lost 3.
   */
  it('negative local delta (decrement): merged = remote + local correction', () => {
    const result = additiveMergeCount(17, 25, 20);
    expect(result.merged).toBe(22); // 25 + (17-20) = 25 - 3 = 22
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 4b — Remote decrements while local increments.
   */
  it('remote decrements while local increments: both changes reflected', () => {
    // lastSynced=30, local=35 (+5), remote=27 (-3). merged = 27 + 5 = 32.
    const result = additiveMergeCount(35, 27, 30);
    expect(result.merged).toBe(32);
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 5 — Overshoot preserved through merge.
   *
   * Both devices increment past maxCount (e.g. maxCount=100). The merged
   * count must NOT be clamped to maxCount. This is the counter-overshoot
   * invariant (feedback_counter_overshoot_is_valid). No Math.min() anywhere
   * in this function — rejection of that clamp is a REQUIRED test assertion.
   *
   * lastSyncedCount=90, local=115 (+25), remote=108 (+18).
   * merged = 108 + 25 = 133. Must NOT be clamped to 100.
   */
  it('overshoot preserved through merge — NO high-end clamp, merged may exceed any threshold', () => {
    const result = additiveMergeCount(115, 108, 90);
    // merged = 108 + (115 - 90) = 108 + 25 = 133.
    expect(result.merged).toBe(133);
    // Explicitly assert it's NOT clamped to 100 (hypothetical maxCount).
    expect(result.merged).toBeGreaterThan(100);
    expect(result.mergeApplied).toBe(true);
  });

  /**
   * Invariant 6 — null lastSyncedCount → LWW fallback.
   * No common ancestor known (first sync). Additive merge is not safe.
   * LWW picks the higher value; local wins on tie.
   */
  it('lastSyncedCount=null: falls back to LWW — no additive merge', () => {
    const result = additiveMergeCount(15, 13, null);
    expect(result.merged).toBe(15); // local wins (higher)
    expect(result.mergeApplied).toBe(false);
  });

  it('lastSyncedCount=undefined: falls back to LWW — no additive merge', () => {
    const result = additiveMergeCount(13, 15, undefined);
    expect(result.merged).toBe(15); // remote wins (higher)
    expect(result.mergeApplied).toBe(false);
  });

  it('lastSyncedCount=null, tie: local wins on tie in LWW fallback', () => {
    const result = additiveMergeCount(10, 10, null);
    expect(result.merged).toBe(10);
    expect(result.mergeApplied).toBe(false);
  });

  /**
   * Invariant 7 — mergeApplied flag
   */
  it('mergeApplied is true when lastSyncedCount is a non-null number', () => {
    const result = additiveMergeCount(15, 13, 10);
    expect(result.mergeApplied).toBe(true);
  });

  it('mergeApplied is false when lastSyncedCount is null', () => {
    const result = additiveMergeCount(15, 13, null);
    expect(result.mergeApplied).toBe(false);
  });

  // ── Low-end clamp (defensive edge) ───────────────────────────────────────

  /**
   * If both devices decrement so aggressively that the merged result goes
   * negative, clamp to 0. This is the only allowed floor clamp.
   */
  it('merged result clamped to 0 when raw calculation goes negative', () => {
    // lastSynced=5, local=0 (-5), remote=0 (-5). merged = 0 + (0-5) = -5 → 0.
    const result = additiveMergeCount(0, 0, 5);
    expect(result.merged).toBe(0);
    expect(result.mergeApplied).toBe(true);
  });

  it('LWW fallback result also clamped to 0 (defensive)', () => {
    // Impossible in practice (counts are non-negative) but defensive.
    const result = additiveMergeCount(0, 0, null);
    expect(result.merged).toBe(0);
    expect(result.mergeApplied).toBe(false);
  });

  // ── Identity cases ────────────────────────────────────────────────────────

  it('neither device changed: merged = lastSyncedCount = remote = local', () => {
    const result = additiveMergeCount(10, 10, 10);
    expect(result.merged).toBe(10); // 10 + (10 - 10) = 10
    expect(result.mergeApplied).toBe(true);
  });

  it('both devices made the same increment: merged = 2x delta + base', () => {
    // Both from 10, both incremented by 5 to reach 15.
    // merged = 15 + (15 - 10) = 20. Both +5 contributions are counted.
    const result = additiveMergeCount(15, 15, 10);
    expect(result.merged).toBe(20);
    expect(result.mergeApplied).toBe(true);
  });

  // ── Large numbers ─────────────────────────────────────────────────────────

  it('large page-reading example: 5000-page yearly goal', () => {
    // Both devices start at 2000 pages (lastSyncedCount=2000).
    // Device A reads 200 more → 2200. Device B reads 150 more → 2150.
    // Merged = 2150 + (2200 - 2000) = 2150 + 200 = 2350.
    const result = additiveMergeCount(2200, 2150, 2000);
    expect(result.merged).toBe(2350);
    expect(result.mergeApplied).toBe(true);
  });

  // ── Return type shape ─────────────────────────────────────────────────────

  it('result has merged (number) and mergeApplied (boolean)', () => {
    const result: MergeCountResult = additiveMergeCount(15, 13, 10);
    expect(typeof result.merged).toBe('number');
    expect(typeof result.mergeApplied).toBe('boolean');
  });
});

// ─── needsAdditiveMerge ───────────────────────────────────────────────────────

describe('needsAdditiveMerge', () => {
  it('both changed from base → true', () => {
    expect(needsAdditiveMerge(15, 13, 10)).toBe(true);
  });

  it('only local changed → false (LWW sufficient)', () => {
    // Remote equals lastSynced → only one side changed.
    expect(needsAdditiveMerge(15, 10, 10)).toBe(false);
  });

  it('only remote changed → false (LWW sufficient)', () => {
    // Local equals lastSynced → only one side changed.
    expect(needsAdditiveMerge(10, 13, 10)).toBe(false);
  });

  it('neither changed → false', () => {
    expect(needsAdditiveMerge(10, 10, 10)).toBe(false);
  });

  it('lastSyncedCount=null → false (no common ancestor)', () => {
    expect(needsAdditiveMerge(15, 13, null)).toBe(false);
  });

  it('lastSyncedCount=undefined → false (no common ancestor)', () => {
    expect(needsAdditiveMerge(15, 13, undefined)).toBe(false);
  });
});
