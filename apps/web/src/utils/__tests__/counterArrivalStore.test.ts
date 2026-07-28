import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { readLastSeen, writeLastSeen } from '../counterArrivalStore';

/**
 * Round-trip + resilience tests for the P3 last-seen store. The vitest harness
 * runs in `node` (no DOM), so we install a tiny in-memory `localStorage` stub
 * before each test and tear it down after.
 */
describe('counterArrivalStore', () => {
  let store: Record<string, string>;

  beforeEach(() => {
    store = {};
    (globalThis as { localStorage?: unknown }).localStorage = {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
      removeItem: (k: string) => {
        delete store[k];
      },
      clear: () => {
        store = {};
      },
    };
  });

  afterEach(() => {
    delete (globalThis as { localStorage?: unknown }).localStorage;
  });

  it('round-trips a snapshot per board', () => {
    writeLastSeen('board-a', { t1: 3, t2: 7 });
    writeLastSeen('board-b', { t3: 1 });
    expect(readLastSeen('board-a')).toEqual({ t1: 3, t2: 7 });
    expect(readLastSeen('board-b')).toEqual({ t3: 1 });
  });

  it('returns {} for an absent board (first view — never an arrival)', () => {
    expect(readLastSeen('never-written')).toEqual({});
  });

  it('overwrites the prior snapshot for the same board', () => {
    writeLastSeen('board-a', { t1: 3 });
    writeLastSeen('board-a', { t1: 9, t2: 2 });
    expect(readLastSeen('board-a')).toEqual({ t1: 9, t2: 2 });
  });

  it('drops non-numeric / malformed values rather than crashing', () => {
    store['oybc.counterArrivals.lastSeen.board-x'] = JSON.stringify({
      good: 4,
      bad: 'nope',
      alsoBad: null,
      nan: Number.NaN,
    });
    expect(readLastSeen('board-x')).toEqual({ good: 4 });
  });

  it('returns {} for unparseable JSON', () => {
    store['oybc.counterArrivals.lastSeen.board-y'] = '{not json';
    expect(readLastSeen('board-y')).toEqual({});
  });

  it('degrades to {} when localStorage is unavailable', () => {
    delete (globalThis as { localStorage?: unknown }).localStorage;
    expect(readLastSeen('board-a')).toEqual({});
    expect(() => writeLastSeen('board-a', { t1: 1 })).not.toThrow();
  });
});
