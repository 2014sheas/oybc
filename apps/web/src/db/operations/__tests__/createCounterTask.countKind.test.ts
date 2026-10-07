import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../internal';
import { createCounterTask } from '../tasks.counter';

afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.syncQueue.clear()]);
});

describe('createCounterTask — counter kinds', () => {
  it('creates a continuous counter seeded with a fractional starting count', async () => {
    const t = await createCounterTask('u1', { action: 'Run', unit: 'miles', startingCount: 148.6, countKind: 'continuous' });
    expect(t.countKind).toBe('continuous');
    expect((await db.tasks.get(t.id))?.currentCount).toBe(148.6);
    expect((await db.taskEvents.where('taskId').equals(t.id).first())?.delta).toBe(148.6);
  });
  it('a discrete (default) counter refuses a fractional seed', async () => {
    await expect(createCounterTask('u1', { action: 'Do', unit: 'push-ups', startingCount: 2.5 })).rejects.toThrow();
  });
  it('writes countKind explicitly, even for the discrete default', async () => {
    const t = await createCounterTask('u1', { action: 'Do', unit: 'push-ups' });
    expect((await db.tasks.get(t.id))?.countKind).toBe('discrete');
  });
  it('a duration counter keeps its noun and seeds minutes', async () => {
    const t = await createCounterTask('u1', { action: 'Practice', unit: 'guitar', startingCount: 90, countKind: 'duration' });
    expect(t).toMatchObject({ countKind: 'duration', unit: 'guitar', currentCount: 90 });
  });
});
