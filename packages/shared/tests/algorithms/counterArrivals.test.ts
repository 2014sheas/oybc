/**
 * counterArrivals.test.ts — passive-completion arrival detection (P3).
 *
 * A shared-counting square "arrives" when its displayed count increased since
 * the board's last-seen snapshot. First views seed a baseline (never arrive);
 * decrements never arrive. The iOS `CounterArrivals.swift` port mirrors these.
 */

import {
  detectCounterArrivals,
  snapshotCounterSquares,
  type ArrivalSquare,
} from '../../src/algorithms/counterArrivals';

function sq(taskId: string, counterId: string, counterName: string, displayed: number): ArrivalSquare {
  return { taskId, counterId, counterName, displayed };
}

describe('detectCounterArrivals', () => {
  it('reports no arrivals on a first view (no last-seen baseline)', () => {
    const r = detectCounterArrivals({
      lastSeen: {},
      squares: [sq('t1', 'c1', 'Push-ups', 20)],
    });
    expect(r.arrivedTaskIds).toEqual([]);
    expect(r.arrivedCounters).toEqual([]);
    expect(r.totalArrivedSquares).toBe(0);
  });

  it('detects a square whose displayed increased since last view', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 20 },
      squares: [sq('t1', 'c1', 'Push-ups', 25)],
    });
    expect(r.arrivedTaskIds).toEqual(['t1']);
    expect(r.arrivedCounters).toEqual([{ counterId: 'c1', counterName: 'Push-ups', squareCount: 1 }]);
    expect(r.totalArrivedSquares).toBe(1);
  });

  it('does not arrive when displayed is unchanged', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 20 },
      squares: [sq('t1', 'c1', 'Push-ups', 20)],
    });
    expect(r.totalArrivedSquares).toBe(0);
  });

  it('does not arrive on a decrement (increase-only)', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 20 },
      squares: [sq('t1', 'c1', 'Push-ups', 12)],
    });
    expect(r.totalArrivedSquares).toBe(0);
  });

  it('aggregates multiple arrived squares of the same counter', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 5, t2: 5 },
      squares: [sq('t1', 'c1', 'Push-ups', 8), sq('t2', 'c1', 'Push-ups', 9)],
    });
    expect(r.arrivedTaskIds.sort()).toEqual(['t1', 't2']);
    expect(r.arrivedCounters).toEqual([{ counterId: 'c1', counterName: 'Push-ups', squareCount: 2 }]);
    expect(r.totalArrivedSquares).toBe(2);
  });

  it('lists multiple arrived counters sorted by name', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 1, t2: 1 },
      squares: [sq('t1', 'cz', 'Water', 3), sq('t2', 'ca', 'Push-ups', 3)],
    });
    expect(r.arrivedCounters.map((c) => c.counterName)).toEqual(['Push-ups', 'Water']);
  });

  it('mixes arrived and unchanged squares correctly', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 10, t2: 10, t3: 10 },
      squares: [
        sq('t1', 'c1', 'Push-ups', 15), // arrived
        sq('t2', 'c1', 'Push-ups', 10), // unchanged
        sq('t3', 'c2', 'Steps', 4), // decreased
      ],
    });
    expect(r.arrivedTaskIds).toEqual(['t1']);
    expect(r.arrivedCounters).toEqual([{ counterId: 'c1', counterName: 'Push-ups', squareCount: 1 }]);
  });

  it('ignores a square with no last-seen entry even when others arrived', () => {
    const r = detectCounterArrivals({
      lastSeen: { t1: 5 },
      squares: [sq('t1', 'c1', 'Push-ups', 9), sq('t2', 'c2', 'Steps', 100)],
    });
    // t2 has no baseline → not an arrival; t1 arrived.
    expect(r.arrivedTaskIds).toEqual(['t1']);
    expect(r.totalArrivedSquares).toBe(1);
  });
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
    const squares = [sq('t1', 'c1', 'Push-ups', 20), sq('t2', 'c1', 'Push-ups', 8)];
    const snap = snapshotCounterSquares(squares);
    const r = detectCounterArrivals({ lastSeen: snap, squares });
    expect(r.totalArrivedSquares).toBe(0);
  });
});
