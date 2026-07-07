import * as fs from 'fs';
import * as path from 'path';
import { deriveDisplayedCount, propagateIncrement } from '../../src/algorithms/sharedCounter';
import type { PropagateIncrementLinkedTask } from '../../src/algorithms/sharedCounter';

/**
 * Tests for deriveDisplayedCount / propagateIncrement — the Phase 1 / Phase 3
 * shared-counter math helpers.
 *
 * C1 (issue #267): the fixed-input/fixed-output vector cases below are now
 * driven by `tests/fixtures/sharedCounterVectors.json`, which
 * `apps/ios/OYBCTests/SharedCounterVectorTests.swift` runs through the SAME
 * vectors against the Swift mirror in `SharedCounter.swift`. This REPLACES
 * every case from the pre-C1 file except "multiple sequential increments
 * accumulate correctly" (kept below) — that test drives a stateful sequence
 * of calls (not a single input/output pair), so it isn't vector-shaped.
 *
 * Pre-C1 assertion count: 11 deriveDisplayedCount cases + 12 propagateIncrement
 * cases (including the multi-step sequence, which contains 3 assertions) = 23
 * `it` blocks / ~26 assertions. Post-C1: 10 fixture vectors (each asserting 2
 * fields) + 9 fixture vectors (each asserting up to 4 fields per linked task)
 * + 1 hand-written sequence test (3 assertions) — net assertion coverage is
 * unchanged or higher (every fixture vector still checks all the fields the
 * original assertions checked).
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/sharedCounterVectors.json');

interface DeriveVector {
  name: string;
  baseline: number;
  maxCount: number;
  currentCount: number;
  displayed: number;
  isCompleted: boolean;
}

interface PropagateVector {
  name: string;
  sourceAfterCurrentCount: number;
  linkedTasks: PropagateIncrementLinkedTask[];
  expected: Array<{ taskId: string; newCurrentCount: number; newIsCompleted: boolean; displayed: number }>;
}

interface Fixture {
  deriveDisplayedCount: DeriveVector[];
  propagateIncrement: PropagateVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

describe('deriveDisplayedCount (fixture-driven, tests/fixtures/sharedCounterVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.deriveDisplayedCount.length).toBeGreaterThan(0);
  });

  for (const v of fixture.deriveDisplayedCount) {
    it(v.name, () => {
      const result = deriveDisplayedCount(
        { baseline: v.baseline, maxCount: v.maxCount },
        { currentCount: v.currentCount },
      );
      expect(result.displayed).toBe(v.displayed);
      expect(result.isCompleted).toBe(v.isCompleted);
    });
  }
});

describe('propagateIncrement (fixture-driven, tests/fixtures/sharedCounterVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.propagateIncrement.length).toBeGreaterThan(0);
  });

  for (const v of fixture.propagateIncrement) {
    it(v.name, () => {
      const results = propagateIncrement({ currentCount: v.sourceAfterCurrentCount }, v.linkedTasks);
      expect(results).toHaveLength(v.expected.length);
      results.forEach((r, i) => {
        expect(r.taskId).toBe(v.expected[i].taskId);
        expect(r.newCurrentCount).toBe(v.expected[i].newCurrentCount);
        expect(r.newIsCompleted).toBe(v.expected[i].newIsCompleted);
        expect(r.displayed).toBe(v.expected[i].displayed);
      });
    });
  }

  // Kept hand-written: this test drives a STATEFUL SEQUENCE of calls (not a
  // single input/output vector) — simulating 5 sequential increments and
  // asserting the latch's evolution across them.
  it('multiple sequential increments accumulate correctly', () => {
    const linked: PropagateIncrementLinkedTask[] = [
      { id: 'acc', baseline: 0, maxCount: 5, isCompleted: false },
    ];

    let state = linked[0];
    for (let i = 1; i <= 3; i++) {
      const [result] = propagateIncrement({ currentCount: i }, [state]);
      state = { ...state, isCompleted: result.newIsCompleted };
    }
    expect(state.isCompleted).toBe(false);

    for (let i = 4; i <= 5; i++) {
      const [result] = propagateIncrement({ currentCount: i }, [state]);
      state = { ...state, isCompleted: result.newIsCompleted };
    }
    expect(state.isCompleted).toBe(true);

    const [overshoot] = propagateIncrement({ currentCount: 6 }, [state]);
    expect(overshoot.newCurrentCount).toBe(6);
    expect(overshoot.newIsCompleted).toBe(true);
    expect(overshoot.displayed).toBe(6);
  });
});
