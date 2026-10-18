import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  NO_PENDING,
  PENDING_SETTLE_FALLBACK_MS,
  countKeyFor,
  expectedCount,
  hasPendingCount,
  holdPending,
  pendingReducer,
  prunePending,
  resolvePendingCount,
  type HoldPendingEnv,
  type PendingAction,
  type PendingCounts,
} from '../pendingCounts';

const op = (id: number, expected: number, extra: Partial<{ settled: boolean; settledAt: unknown }> = {}) => ({
  id, expected, settled: false, ...extra,
});

describe('countKeyFor', () => {
  it('keys a linked row on its counter root, anything else on itself', () => {
    expect(countKeyFor({ id: 'row', sharedCounterId: 'root' })).toBe('root');
    expect(countKeyFor({ id: 'solo' })).toBe('solo');
  });
});

describe('resolvePendingCount', () => {
  it('is the live count when nothing is pending', () => {
    expect(resolvePendingCount(NO_PENDING, 'k', 7)).toBe(7);
  });

  it('shows the expected count until the live data reaches it, then the live count', () => {
    const pending: PendingCounts = { k: [op(1, 17)] };
    expect(resolvePendingCount(pending, 'k', 12)).toBe(17);
    expect(resolvePendingCount(pending, 'k', 17)).toBe(17);
    expect(hasPendingCount(pending, 'k', 12)).toBe(true);
    expect(hasPendingCount(pending, 'k', 17)).toBe(false);
  });

  it('never goes old -> new -> old -> new across the write (no flicker, no double count)', () => {
    // live 12 -> tap +5 -> (write resolves, live still 12) -> live emits 17 while the op still lingers.
    const shown = [
      resolvePendingCount(NO_PENDING, 'k', 12),
      resolvePendingCount({ k: [op(1, 17)] }, 'k', 12),
      resolvePendingCount({ k: [op(1, 17, { settled: true })] }, 'k', 12),
      resolvePendingCount({ k: [op(1, 17, { settled: true })] }, 'k', 17),
      resolvePendingCount(NO_PENDING, 'k', 17),
    ];
    expect(shown).toEqual([12, 17, 17, 17, 17]);
  });

  it('stacked writes show the newest expectation; the live data reaching the first leaves the second showing', () => {
    const pending: PendingCounts = { k: [op(1, 17), op(2, 22)] };
    expect(resolvePendingCount(pending, 'k', 12)).toBe(22);
    expect(resolvePendingCount(pending, 'k', 17)).toBe(22);
    expect(resolvePendingCount(pending, 'k', 22)).toBe(22);
  });

  it('only counts on the key it was held for', () => {
    expect(resolvePendingCount({ other: [op(1, 99)] }, 'k', 3)).toBe(3);
  });
});

describe('expectedCount', () => {
  it('adds, quantises and clamps at zero', () => {
    expect(expectedCount(12, 5)).toBe(17);
    expect(expectedCount(3, -5)).toBe(0);
    expect(expectedCount(0.1, 0.2)).toBe(0.3);
  });
});

describe('pendingReducer', () => {
  it('adds, settles and drops an op', () => {
    let s = pendingReducer(NO_PENDING, { type: 'add', key: 'k', op: op(1, 17) });
    expect(s.k).toHaveLength(1);
    s = pendingReducer(s, { type: 'settle', key: 'k', id: 1, token: 'T1' });
    expect(s.k[0]).toMatchObject({ settled: true, settledAt: 'T1' });
    s = pendingReducer(s, { type: 'drop', key: 'k', id: 1 });
    expect(s).toBe(NO_PENDING);
  });

  it('settling or dropping an op that is already gone changes nothing', () => {
    const s: PendingCounts = { k: [op(2, 5)] };
    expect(pendingReducer(s, { type: 'settle', key: 'k', id: 1, token: 'T' })).toBe(s);
    expect(pendingReducer(s, { type: 'drop', key: 'k', id: 1 })).toBe(s);
    expect(pendingReducer(NO_PENDING, { type: 'drop', key: 'k', id: 1 })).toBe(NO_PENDING);
  });
});

describe('prunePending', () => {
  it('releases every op up to the newest one the live count reached', () => {
    const s: PendingCounts = { k: [op(1, 17), op(2, 22)] };
    expect(prunePending(s, () => 17, 'T')).toEqual({ k: [op(2, 22)] });
    expect(prunePending(s, () => 22, 'T')).toBe(NO_PENDING);
  });

  it('keeps an in-flight op the live data has not reached', () => {
    const s: PendingCounts = { k: [op(1, 17)] };
    expect(prunePending(s, () => 12, 'T')).toBe(s);
  });

  it('releases a settled op once the live data has emitted since it settled, even without a match', () => {
    const s: PendingCounts = { k: [op(1, 17, { settled: true, settledAt: 'T1' })] };
    expect(prunePending(s, () => 12, 'T1')).toBe(s);
    expect(prunePending(s, () => 12, 'T2')).toBe(NO_PENDING);
  });

  it('never drops an unsettled op on a token change', () => {
    const s: PendingCounts = { k: [op(1, 17)] };
    expect(prunePending(s, () => 12, 'T2')).toBe(s);
  });
});

describe('holdPending', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  /** A host over the real reducer; `shown` follows the store the way the hook does. */
  function host(live: number): { env: HoldPendingEnv; store: () => PendingCounts; actions: PendingAction[] } {
    let state: PendingCounts = NO_PENDING;
    let id = 0;
    const actions: PendingAction[] = [];
    return {
      env: {
        dispatch: (a) => { actions.push(a); state = pendingReducer(state, a); },
        newId: () => ++id,
        shownNow: () => resolvePendingCount(state, 'k', live),
        tokenNow: () => 'T0',
      },
      store: () => state,
      actions,
    };
  }

  it('shows the new count BEFORE the write resolves', async () => {
    const h = host(12);
    let release: (n: number) => void = () => {};
    const write = new Promise<number>((r) => { release = r; });
    const held = holdPending(h.env, 'k', 5, () => write, (n) => n > 0);
    expect(resolvePendingCount(h.store(), 'k', 12)).toBe(17);
    release(5);
    await held;
    expect(h.store().k[0]).toMatchObject({ settled: true, settledAt: 'T0' });
    expect(resolvePendingCount(h.store(), 'k', 12)).toBe(17);
  });

  it('rolls back when the write throws, and rethrows', async () => {
    const h = host(12);
    await expect(holdPending(h.env, 'k', 5, () => Promise.reject(new Error('boom')), () => true)).rejects.toThrow('boom');
    expect(h.store()).toBe(NO_PENDING);
    expect(resolvePendingCount(h.store(), 'k', 12)).toBe(12);
  });

  it('rolls back when the write reports it did not commit (the existing error path)', async () => {
    const h = host(12);
    const result = await holdPending(h.env, 'k', 5, async () => 0, (n) => n > 0);
    expect(result).toBe(0);
    expect(h.store()).toBe(NO_PENDING);
  });

  it('holds nothing for a write that cannot move the count', async () => {
    const h = host(0);
    await holdPending(h.env, 'k', -3, async () => 0, () => true);
    expect(h.actions).toEqual([]);
  });

  it('removal clamps at zero', async () => {
    const h = host(3);
    const held = holdPending(h.env, 'k', -5, async () => 3, () => true);
    expect(resolvePendingCount(h.store(), 'k', 3)).toBe(0);
    await held;
  });

  it('a committed op nobody matched is dropped after the fallback', async () => {
    const h = host(12);
    await holdPending(h.env, 'k', 5, async () => 5, () => true);
    expect(h.store().k).toHaveLength(1);
    vi.advanceTimersByTime(PENDING_SETTLE_FALLBACK_MS);
    expect(h.store()).toBe(NO_PENDING);
  });

  it('a second tap builds on the count already shown, not on the stale live count', async () => {
    const h = host(12);
    await holdPending(h.env, 'k', 5, async () => 5, () => true);
    const second = holdPending(h.env, 'k', 5, async () => 5, () => true);
    expect(resolvePendingCount(h.store(), 'k', 12)).toBe(22);
    await second;
  });
});
