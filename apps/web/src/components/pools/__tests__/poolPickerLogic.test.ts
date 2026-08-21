import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../../db/internal';
import { createPool } from '../../../db/operations/pools';
import { shouldSelectAfterPoolCreated } from '../poolPickerLogic';

afterEach(async () => {
  await db.pools.clear();
  await db.syncQueue.clear();
});

describe('shouldSelectAfterPoolCreated', () => {
  it('selects a freshly-created pool that is not yet in the selection', () => {
    expect(shouldSelectAfterPoolCreated('new-pool', [])).toBe(true);
    expect(shouldSelectAfterPoolCreated('new-pool', ['other-pool'])).toBe(true);
  });

  it('does not re-select (would double-toggle OFF) a pool already selected', () => {
    expect(shouldSelectAfterPoolCreated('new-pool', ['new-pool'])).toBe(false);
  });
});

/**
 * "+ Build a new pool…" round trip (docs/POOLS_RECURRING.md §Surfaces
 * item 10): creating a pool via `PoolPickerSheet` must result in it being
 * selected in the launching context (the defaults sheet's `corePoolIds`
 * or the roster edit sheet's `poolIds`). `PoolPickerSheet.handlePoolCreated`
 * is exactly `createPool(...)` → `shouldSelectAfterPoolCreated(...)` →
 * (conditionally) the caller's own toggle — this exercises the full chain
 * end to end using the real `createPool` DB operation, standing in for
 * the component's own untestable (no DOM harness) call site.
 */
describe('PoolPickerSheet "+ Build a new pool…" round trip', () => {
  it('a newly-created pool is selected into an initially-empty selection', async () => {
    const selectedPoolIds: string[] = [];
    const pool = await createPool('user-1', { name: 'Evening wind-down', taskIds: ['t1'] });

    const shouldSelect = shouldSelectAfterPoolCreated(pool.id, selectedPoolIds);
    expect(shouldSelect).toBe(true);

    const nextSelection = shouldSelect ? [...selectedPoolIds, pool.id] : selectedPoolIds;
    expect(nextSelection).toContain(pool.id);
  });

  it('a newly-created pool is appended alongside an existing selection, not replacing it', async () => {
    const selectedPoolIds: string[] = ['existing-pool'];
    const pool = await createPool('user-1', { name: 'Weekend chores', taskIds: [] });

    const shouldSelect = shouldSelectAfterPoolCreated(pool.id, selectedPoolIds);
    const nextSelection = shouldSelect ? [...selectedPoolIds, pool.id] : selectedPoolIds;

    expect(nextSelection).toEqual(['existing-pool', pool.id]);
  });
});
