import { afterEach, describe, expect, it, vi } from 'vitest';
import { PULL_APPLY_ORDER } from '@oybc/shared';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a signed-in user instead.
vi.mock('../config', () => ({ auth: { currentUser: { uid: 'user-1' } }, firestore: {} }));

/**
 * A fake Firestore: `collection(...)` / `query(...)` / `where(...)` build plain
 * descriptors, `getDocs` serves `docsByCollection` filtered by the query's
 * `_syncedAt >=` operand, and every call is recorded in order.
 */
const calls: string[] = [];
const queriedSince: Record<string, unknown> = {};
let docsByCollection: Record<string, Array<Record<string, unknown>>> = {};
let failCollection: string | null = null;
vi.mock('firebase/firestore', async (importOriginal) => {
  const real = await importOriginal<typeof import('firebase/firestore')>();
  type Col = { name: string };
  type Q = { col: Col; since?: InstanceType<typeof real.Timestamp> };
  return {
    ...real,
    doc: vi.fn(() => ({})),
    collection: vi.fn((_fs: unknown, ...path: string[]) => ({ name: path[path.length - 1] })),
    where: vi.fn((_field: string, op: string, value: unknown) => ({ op, value })),
    query: vi.fn((col: Col, ...constraints: Array<{ op: string; value: InstanceType<typeof real.Timestamp> }>) => ({
      col,
      since: constraints[0]?.value,
    })),
    getDoc: vi.fn(async () => {
      calls.push('fetch:users');
      return { exists: () => false };
    }),
    getDocs: vi.fn(async (q: Q) => {
      calls.push(`fetch:${q.col.name}`);
      queriedSince[q.col.name] = q.since ?? null;
      if (q.col.name === failCollection) throw new Error('offline');
      const all = docsByCollection[q.col.name] ?? [];
      const docs = all
        .filter((d) => !q.since || (d._syncedAt as InstanceType<typeof real.Timestamp>).toMillis() >= q.since.toMillis())
        .map((d) => ({ data: () => d }));
      return { empty: docs.length === 0, docs };
    }),
    onSnapshot: vi.fn((target: Q | Col | object) => {
      const name = 'col' in target ? (target as Q).col.name : 'users';
      calls.push(`listen:${name}`);
      if ('col' in target) queriedSince[`listen:${name}`] = (target as Q).since ?? null;
      return () => undefined;
    }),
  };
});

const { pullSync, startSyncLoop, stopSyncLoop } = await import('../syncService');
const { db } = await import('../../db/internal');
const { Timestamp } = await import('firebase/firestore');

const USER = 'user-1';
const NOW = '2026-07-19T00:00:00.000Z';
const uuid = (n: number) => `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

/** A schema-valid remote Task doc stamped with `_syncedAt` = `seconds`. */
function taskDoc(n: number, seconds: number): Record<string, unknown> {
  return {
    id: uuid(n), userId: USER, title: `T${n}`, type: 'normal', isCompleted: false,
    totalCompletions: 0, totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1,
    isDeleted: false, _syncedAt: new Timestamp(seconds, 0),
  };
}

function poolDoc(n: number, seconds: number): Record<string, unknown> {
  return {
    id: uuid(n), userId: USER, name: `P${n}`, taskIds: [], createdAt: NOW, updatedAt: NOW,
    version: 1, isDeleted: false, _syncedAt: new Timestamp(seconds, 0),
  };
}

afterEach(async () => {
  stopSyncLoop();
  vi.unstubAllGlobals();
  calls.length = 0;
  for (const k of Object.keys(queriedSince)) delete queriedSince[k];
  docsByCollection = {};
  failCollection = null;
  await Promise.all([db.tasks.clear(), db.pools.clear(), db.syncWatermarks.clear(), db.users.clear(), db.syncQueue.clear()]);
});

describe('pullSync — dependency order + per-collection checkpoints (iOS parity)', () => {
  it('reads the collections in PULL_APPLY_ORDER', async () => {
    await pullSync(USER);
    expect(calls.filter((c) => c !== 'fetch:users')).toEqual(PULL_APPLY_ORDER.map((c) => `fetch:${c}`));
  });

  it('checkpoints a collection at its max _syncedAt; a failed collection does not; resume reads >= the checkpoint', async () => {
    docsByCollection = { tasks: [taskDoc(1, 100), taskDoc(2, 300), taskDoc(3, 200)], pools: [poolDoc(9, 50)] };
    failCollection = 'pools';

    const first = await pullSync(USER);
    expect(first.details.some((d) => d.startsWith('Pull failed for pools'))).toBe(true);
    const rows = await db.syncWatermarks.toArray();
    expect(rows).toEqual([{ userId: USER, collection: 'tasks', seconds: 300, nanoseconds: 0 }]);

    failCollection = null;
    calls.length = 0;
    const second = await pullSync(USER);
    expect((queriedSince.tasks as InstanceType<typeof Timestamp>).seconds).toBe(300);
    expect(queriedSince.pools).toBeNull(); // no checkpoint → full read
    expect(second.details.filter((d) => d.startsWith('Pulled tasks/'))).toEqual([]); // boundary doc is an echo
    expect(second.details.filter((d) => d.startsWith('Pulled pools/'))).toHaveLength(1);
    expect((await db.syncWatermarks.get([USER, 'pools']))?.seconds).toBe(50);
  });
});

describe('startSyncLoop — listeners attach only after the first pull', () => {
  it('opens every listener after the initial pull, from the fresh checkpoints', async () => {
    docsByCollection = { tasks: [taskDoc(1, 700)] };
    vi.stubGlobal('window', { addEventListener: vi.fn(), removeEventListener: vi.fn() });
    vi.stubGlobal('navigator', { onLine: true }); // Node 20 (CI) has no global navigator
    startSyncLoop(USER, 60_000);
    await vi.waitFor(() => expect(calls.filter((c) => c.startsWith('listen:'))).toHaveLength(PULL_APPLY_ORDER.length + 1));

    const lastFetch = calls.map((c) => c.startsWith('fetch:')).lastIndexOf(true);
    const firstListen = calls.findIndex((c) => c.startsWith('listen:'));
    expect(lastFetch).toBeLessThan(firstListen);
    expect((queriedSince['listen:tasks'] as InstanceType<typeof Timestamp>).seconds).toBe(700);
  });
});
