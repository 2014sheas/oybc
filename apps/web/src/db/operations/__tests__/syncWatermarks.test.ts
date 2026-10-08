import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../internal';
import { advancePullWatermark, fetchPullWatermarks, pullWatermarkOf } from '../syncWatermarks';

/** A Firestore-`Timestamp`-shaped value (read structurally, like the real one). */
const ts = (seconds: number, nanoseconds = 0) => ({ seconds, nanoseconds, toDate: () => new Date(seconds * 1000) });

afterEach(async () => {
  await db.syncWatermarks.clear();
});

describe('pullWatermarkOf', () => {
  it('reads a Timestamp-shaped value exactly', () => {
    expect(pullWatermarkOf(ts(12, 345))).toEqual({ seconds: 12, nanoseconds: 345 });
  });

  it('is null for a missing / pending / non-timestamp value', () => {
    expect(pullWatermarkOf(undefined)).toBeNull();
    expect(pullWatermarkOf(null)).toBeNull();
    expect(pullWatermarkOf('2026-01-01T00:00:00Z')).toBeNull();
    expect(pullWatermarkOf({ seconds: '1', nanoseconds: 0 })).toBeNull();
  });
});

describe('advancePullWatermark / fetchPullWatermarks', () => {
  it('stores the batch max per (user, collection)', async () => {
    await advancePullWatermark('u1', 'tasks', [{ _syncedAt: ts(10) }, { _syncedAt: ts(30, 1) }, { _syncedAt: ts(20) }]);
    await advancePullWatermark('u1', 'boards', [{ _syncedAt: ts(5) }]);
    await advancePullWatermark('u2', 'tasks', [{ _syncedAt: ts(99) }]);

    expect(await fetchPullWatermarks('u1')).toEqual({
      tasks: { seconds: 30, nanoseconds: 1 },
      boards: { seconds: 5, nanoseconds: 0 },
    });
    expect(await fetchPullWatermarks('u2')).toEqual({ tasks: { seconds: 99, nanoseconds: 0 } });
    expect(await fetchPullWatermarks('nobody')).toEqual({});
  });

  it('never moves a checkpoint backwards', async () => {
    await advancePullWatermark('u1', 'tasks', [{ _syncedAt: ts(50) }]);
    await advancePullWatermark('u1', 'tasks', [{ _syncedAt: ts(40) }]);
    expect((await fetchPullWatermarks('u1')).tasks).toEqual({ seconds: 50, nanoseconds: 0 });
  });

  it('ignores a batch with no stamped doc', async () => {
    await advancePullWatermark('u1', 'tasks', [{ id: 'legacy' }, { _syncedAt: null }]);
    expect(await fetchPullWatermarks('u1')).toEqual({});
  });
});
