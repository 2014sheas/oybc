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
/** Runs at the start of every getDocs — simulates a remote write mid-pull. */
let onFetch: ((collection: string) => Promise<void>) | null = null;
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
      await onFetch?.(q.col.name);
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
  onFetch = null;
  await Promise.all([
    db.tasks.clear(), db.pools.clear(), db.syncWatermarks.clear(), db.users.clear(), db.syncQueue.clear(),
    db.boards.clear(), db.boardTasks.clear(), db.taskEvents.clear(),
  ]);
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

describe('pullSync — boards first, events before task rows (review C1)', () => {
  const BOARD = uuid(500);
  const START = '2026-07-01T00:00:00.000Z';
  const IN_WINDOW = '2026-07-02T12:00:00.000Z';

  function boardDoc(over: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      id: BOARD, userId: USER, name: 'Old name', status: 'active', boardSize: 3, timeframe: 'daily',
      startDate: START, endDate: '2099-12-31T23:59:59.999Z', centerSquareType: 'none', isRandomized: false,
      totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
      createdAt: START, updatedAt: START, version: 1, isDeleted: false, ...over,
    };
  }

  it('a peer completion + rename: the remote board wins verbatim and nothing is pushed back', async () => {
    // Local: board v1 + 9 placed tasks, nothing completed, converged.
    const { _syncedAt: _b, ...localBoard } = boardDoc();
    await db.boards.put(localBoard as never);
    for (let cell = 0; cell < 9; cell++) {
      const { _syncedAt: _t, ...task } = taskDoc(600 + cell, 1);
      await db.tasks.put({ ...task, createdAt: START, updatedAt: START } as never);
      await db.boardTasks.put({
        id: uuid(700 + cell), boardId: BOARD, taskId: uuid(600 + cell), row: Math.floor(cell / 3), col: cell % 3,
        isCenter: false, createdAt: START, updatedAt: START, version: 1, isDeleted: false,
      } as never);
    }
    await db.syncQueue.clear();

    // Remote: the peer completed cell 0 (event + authored Task row) and renamed the board.
    const later = new Timestamp(1_995_000_000, 0);
    docsByCollection = {
      boards: [{ ...boardDoc({ name: 'Renamed elsewhere', version: 2, completedTasks: 1, updatedAt: '2026-07-02T12:00:01.000Z' }), _syncedAt: later }],
      taskEvents: [{
        id: uuid(800), userId: USER, taskId: uuid(600), kind: 'completion', occurredAt: IN_WINDOW,
        createdAt: IN_WINDOW, updatedAt: IN_WINDOW, version: 1, isDeleted: false, _syncedAt: later,
      }],
      tasks: [{ ...taskDoc(600, 0), createdAt: START, isCompleted: true, version: 2, updatedAt: IN_WINDOW, _syncedAt: later }],
    };

    await pullSync(USER);

    const board = await db.boards.get(BOARD);
    expect(board?.name).toBe('Renamed elsewhere');
    expect(board?.version).toBe(2);
    expect(board?.completedTasks).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });
});

describe('pullSync — lastSyncedAt is the pull START (review I1)', () => {
  it('a doc written remotely during the pull is picked up by the next one', async () => {
    await db.users.put({ id: USER, email: '', displayName: 'U', createdAt: NOW, updatedAt: NOW, version: 1 } as never);
    onFetch = async (name) => {
      if (name !== 'coreBoardDefaults') return;
      onFetch = null;
      // Written while the pull is already past `tasks` (no checkpoint there).
      docsByCollection.tasks = [{ ...taskDoc(42, 0), _syncedAt: Timestamp.fromMillis(Date.now()) }];
      await new Promise((r) => setTimeout(r, 1100)); // end-of-pull ≥ 1 s later
    };
    await pullSync(USER);
    expect(await db.tasks.get(uuid(42))).toBeUndefined();

    const stamp = (await db.users.get(USER))?.lastSyncedAt;
    expect(stamp).toBeDefined();
    await pullSync(USER, stamp);
    expect(await db.tasks.get(uuid(42))).toBeDefined();
  });
});

describe('startSyncLoop — listeners attach even when the first pull fails (review I2)', () => {
  it('opens every listener after a failed initial pull', async () => {
    failCollection = 'tasks';
    vi.stubGlobal('window', { addEventListener: vi.fn(), removeEventListener: vi.fn() });
    vi.stubGlobal('navigator', { onLine: true });
    startSyncLoop(USER, 60_000);
    await vi.waitFor(() => expect(calls.filter((c) => c.startsWith('listen:'))).toHaveLength(PULL_APPLY_ORDER.length + 1));
    expect(calls).toContain('fetch:tasks');
  });
});
