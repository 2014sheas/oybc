import { deriveDisplayedCount, propagateIncrement } from '../../src/algorithms/sharedCounter';
import type { PropagateIncrementLinkedTask } from '../../src/algorithms/sharedCounter';

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

// ─── propagateIncrement (Phase 3) ────────────────────────────────────────────

describe('propagateIncrement', () => {
  // ── Two linked tasks with different baselines ───────────────────────────────

  it('source increments by 5: two linked tasks derive independently', () => {
    // Source: currentCount = 105 (incremented from 100 by 5)
    const source = { currentCount: 105 };
    const linked: PropagateIncrementLinkedTask[] = [
      // linked-A: baseline 0, maxCount 200 — not yet complete
      { id: 'a', baseline: 0, maxCount: 200, isCompleted: false },
      // linked-B: baseline 100, maxCount 10 — 105 - 100 = 5 → not complete
      { id: 'b', baseline: 100, maxCount: 10, isCompleted: false },
    ];
    const results = propagateIncrement(source, linked);

    expect(results).toHaveLength(2);

    const a = results.find((r) => r.taskId === 'a')!;
    expect(a.displayed).toBe(105); // 105 - 0
    expect(a.newIsCompleted).toBe(false); // 105 < 200
    expect(a.newCurrentCount).toBe(105);

    const b = results.find((r) => r.taskId === 'b')!;
    expect(b.displayed).toBe(5); // 105 - 100
    expect(b.newIsCompleted).toBe(false); // 5 < 10
    expect(b.newCurrentCount).toBe(105);
  });

  // ── Source goes past maxCount (overshoot invariant) ─────────────────────────

  it('source overshoots its own maxCount: no clamp on source currentCount', () => {
    // Source has maxCount 50 but we've incremented to 75.
    // This function receives the ALREADY-incremented value — no clamping happens here.
    const source = { currentCount: 75 };
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'x', baseline: 0, maxCount: 50, isCompleted: true }, // already latched
    ];
    const results = propagateIncrement(source, linked);
    const x = results[0];
    // newCurrentCount must be 75 — the raw source value, never clamped to 50.
    expect(x.newCurrentCount).toBe(75);
    // displayed is 75 - 0 = 75 (no high-end clamp).
    expect(x.displayed).toBe(75);
    // latch preserves true.
    expect(x.newIsCompleted).toBe(true);
  });

  // ── Linked task maxCount < source maxCount: completes before source ─────────

  it('linked task with low maxCount completes before source does', () => {
    // Source count is 30 (not yet at its own maxCount of 100).
    // Linked task has baseline 0, maxCount 20 → completes at source count 20.
    const source = { currentCount: 30 };
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'early', baseline: 0, maxCount: 20, isCompleted: false },
    ];
    const results = propagateIncrement(source, linked);
    const early = results[0];
    expect(early.displayed).toBe(30);
    // 30 >= 20 → completes.
    expect(early.newIsCompleted).toBe(true);
  });

  // ── Linked task maxCount > source maxCount: stays incomplete after source ───

  it('linked task with high maxCount stays incomplete after source threshold', () => {
    // Source is at 100 (its own maxCount). Linked task maxCount = 200.
    const source = { currentCount: 100 };
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'late', baseline: 0, maxCount: 200, isCompleted: false },
    ];
    const results = propagateIncrement(source, linked);
    const late = results[0];
    expect(late.displayed).toBe(100);
    expect(late.newIsCompleted).toBe(false); // 100 < 200
  });

  // ── One-way latch: isCompleted never flips from true to false ──────────────

  it('isCompleted one-way latch: once true, stays true even if derived value would be false', () => {
    // Defensive edge: source count dropped below baseline (shouldn't happen in
    // production, but the latch must hold regardless of derived value).
    // baseline = 50, source = 30 → displayed = max(0, 30-50) = 0 → isCompleted = false.
    // But the task was already latched (isCompleted = true) → stays true.
    const source = { currentCount: 30 };
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'latched', baseline: 50, maxCount: 10, isCompleted: true },
    ];
    const results = propagateIncrement(source, linked);
    expect(results[0].newIsCompleted).toBe(true); // latch holds
  });

  // ── Source with no linked tasks: empty result ──────────────────────────────

  it('source with no linked tasks returns empty array', () => {
    const source = { currentCount: 42 };
    const results = propagateIncrement(source, []);
    expect(results).toHaveLength(0);
  });

  // ── Multiple increments accumulate correctly ───────────────────────────────

  it('multiple sequential increments accumulate correctly', () => {
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'acc', baseline: 0, maxCount: 5, isCompleted: false },
    ];

    // Simulate 3 increments: source goes 0 → 1 → 2 → 3.
    let state = linked[0];
    for (let i = 1; i <= 3; i++) {
      const [result] = propagateIncrement({ currentCount: i }, [state]);
      state = { ...state, isCompleted: result.newIsCompleted };
    }
    // After 3 increments: displayed = 3, not complete yet (threshold = 5).
    expect(state.isCompleted).toBe(false);

    // Two more increments: source = 4, 5.
    for (let i = 4; i <= 5; i++) {
      const [result] = propagateIncrement({ currentCount: i }, [state]);
      state = { ...state, isCompleted: result.newIsCompleted };
    }
    // At source = 5 (= maxCount = 5) → complete.
    expect(state.isCompleted).toBe(true);

    // One more overshoot increment: source = 6.
    const [overshoot] = propagateIncrement({ currentCount: 6 }, [state]);
    expect(overshoot.newCurrentCount).toBe(6); // no clamp
    expect(overshoot.newIsCompleted).toBe(true); // latch holds
    expect(overshoot.displayed).toBe(6); // raw overshoot
  });

  // ── 1:N fan-out: source incremented, N linked tasks all update ─────────────

  it('1:N fan-out: source links to three tasks that all update', () => {
    const source = { currentCount: 10 };
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'n1', baseline: 0, maxCount: 5, isCompleted: false },   // completes
      { id: 'n2', baseline: 0, maxCount: 10, isCompleted: false },  // completes exactly
      { id: 'n3', baseline: 0, maxCount: 20, isCompleted: false },  // not yet
    ];
    const results = propagateIncrement(source, linked);
    expect(results).toHaveLength(3);

    const n1 = results.find((r) => r.taskId === 'n1')!;
    expect(n1.newIsCompleted).toBe(true);  // 10 >= 5
    expect(n1.displayed).toBe(10);         // no clamp

    const n2 = results.find((r) => r.taskId === 'n2')!;
    expect(n2.newIsCompleted).toBe(true);  // 10 >= 10
    expect(n2.displayed).toBe(10);

    const n3 = results.find((r) => r.taskId === 'n3')!;
    expect(n3.newIsCompleted).toBe(false); // 10 < 20
    expect(n3.displayed).toBe(10);
  });
});
