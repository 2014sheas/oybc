import * as fs from 'fs';
import * as path from 'path';
import {
  detectCounterArrivals,
  snapshotCounterSquares,
  type ArrivalSquare,
} from '../../src/algorithms/counterArrivals';

/**
 * counterArrivals.test.ts — passive-completion arrival detection (P3).
 *
 * SHARED_COUNTERS P3 PR A (issue #303): `detectCounterArrivals` is now
 * fixture-driven from `tests/fixtures/counterArrivalsVectors.json` — the
 * SAME file `apps/ios/OYBCTests/CounterArrivalsVectorTests.swift` runs
 * through the Swift mirror `CounterArrivals.swift`. Pre-PR-A: 8
 * `detectCounterArrivals` `it` blocks. Post-PR-A: 8 fixture vectors — a 1:1
 * mapping, no case dropped.
 *
 * `snapshotCounterSquares` has a different input/output shape (not a
 * lastSeen+squares -> result match) and its 2 tests — including a round-trip
 * case that calls BOTH functions in sequence — don't fit the single-function
 * vector schema, so they stay hand-written here (kept, not converted).
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/counterArrivalsVectors.json');

interface VectorSquare {
  taskId: string;
  counterId: string;
  counterName: string;
  displayed: number;
}

interface ExpectedResult {
  arrivedTaskIds: string[];
  arrivedCounters: { counterId: string; counterName: string; squareCount: number }[];
  totalArrivedSquares: number;
}

interface Vector {
  name: string;
  lastSeen: Record<string, number>;
  squares: VectorSquare[];
  expected: ExpectedResult;
}

interface Fixture {
  vectors: Vector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

function toSquare(s: VectorSquare): ArrivalSquare {
  return { taskId: s.taskId, counterId: s.counterId, counterName: s.counterName, displayed: s.displayed };
}

describe('detectCounterArrivals (fixture-driven, tests/fixtures/counterArrivalsVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const result = detectCounterArrivals({
        lastSeen: v.lastSeen,
        squares: v.squares.map(toSquare),
      });
      expect(result.arrivedTaskIds).toEqual(v.expected.arrivedTaskIds);
      expect(result.arrivedCounters).toEqual(v.expected.arrivedCounters);
      expect(result.totalArrivedSquares).toBe(v.expected.totalArrivedSquares);
    });
  }
});

describe('snapshotCounterSquares', () => {
  it('builds a taskId → displayed map from the current squares', () => {
    const snap = snapshotCounterSquares([
      { taskId: 't1', displayed: 20 },
      { taskId: 't2', displayed: 5 },
    ]);
    expect(snap).toEqual({ t1: 20, t2: 5 });
  });

  it('round-trips: a fresh snapshot yields no arrivals on the next detect', () => {
    const squares = [
      { taskId: 't1', counterId: 'c1', counterName: 'Push-ups', displayed: 20 },
      { taskId: 't2', counterId: 'c1', counterName: 'Push-ups', displayed: 8 },
    ];
    const snap = snapshotCounterSquares(squares);
    const r = detectCounterArrivals({ lastSeen: snap, squares });
    expect(r.totalArrivedSquares).toBe(0);
  });
});
