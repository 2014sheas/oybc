import { afterEach, describe, expect, it, vi } from 'vitest';

// `./config` initializes Firebase at import time (throws without `.env.local`,
// e.g. on CI) — stub it with a signed-in user instead.
vi.mock('../config', () => ({ auth: { currentUser: { uid: 'user-1' } }, firestore: {} }));

/**
 * A fake Firestore serving `docsByCollection` for queries (`_syncedAt >=`) and
 * for single-document reads by path (`users/<uid>/<collection>/<id>`, the
 * quarantine retry), recording every single-document read.
 */
const docReads: string[] = [];
let docsByCollection: Record<string, Array<Record<string, unknown>>> = {};
let failDocReads = false;
vi.mock('firebase/firestore', async (importOriginal) => {
  const real = await importOriginal<typeof import('firebase/firestore')>();
  type Col = { name: string };
  type Q = { col: Col; since?: InstanceType<typeof real.Timestamp> };
  return {
    ...real,
    doc: vi.fn((_fs: unknown, ...path: string[]) => ({ path: path.join('/') })),
    collection: vi.fn((_fs: unknown, ...path: string[]) => ({ name: path[path.length - 1] })),
    where: vi.fn((_field: string, _op: string, value: unknown) => ({ value })),
    query: vi.fn((col: Col, ...constraints: Array<{ value: InstanceType<typeof real.Timestamp> }>) => ({
      col,
      since: constraints[0]?.value,
    })),
    getDoc: vi.fn(async (ref: { path: string }): Promise<{ exists: () => boolean; data?: () => unknown }> => {
      const parts = ref.path.split('/'); // users/<uid>[/<collection>/<id>]
      if (parts.length < 4) return { exists: () => false };
      if (failDocReads) throw new Error('offline');
      docReads.push(`${parts[2]}/${parts[3]}`);
      const found = (docsByCollection[parts[2]] ?? []).find((d) => d.id === parts[3]);
      return { exists: () => Boolean(found), data: () => found };
    }),
    getDocs: vi.fn(async (q: Q) => {
      const all = docsByCollection[q.col.name] ?? [];
      const docs = all
        .filter((d) => !q.since || (d._syncedAt as InstanceType<typeof real.Timestamp>).toMillis() >= q.since.toMillis())
        .map((d) => ({ data: () => d }));
      return { empty: docs.length === 0, docs };
    }),
    onSnapshot: vi.fn(() => () => undefined),
  };
});

const { pullSync, pushSync } = await import('../syncService');
const { db } = await import('../../db/internal');
const { Timestamp } = await import('firebase/firestore');
const { SyncOperationType } = await import('@oybc/shared');
const { addToSyncQueue } = await import('../../db/operations/syncQueue');
const { currentAppBuild, listQuarantinedDocs } = await import('../../db/operations/syncQuarantine');

const USER = 'user-1';
const NOW = '2026-07-19T00:00:00.000Z';
const uuid = (n: number) => `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

/** A Task doc stamped with `_syncedAt` = `seconds`; `type` is the future-value knob. */
function taskDoc(n: number, seconds: number, type = 'normal'): Record<string, unknown> {
  return {
    id: uuid(n), userId: USER, title: `T${n}`, type, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    _syncedAt: new Timestamp(seconds, 0),
  };
}

afterEach(async () => {
  docReads.length = 0;
  docsByCollection = {};
  failDocReads = false;
  await Promise.all([
    db.tasks.clear(), db.syncWatermarks.clear(), db.users.clear(), db.syncQueue.clear(), db.syncQuarantine.clear(),
  ]);
});

describe('pullSync — forward-compatible pull (issue #300)', () => {
  it('skips a future-typed doc, applies the rest, moves the checkpoint past it — and never re-reads it under the same build', async () => {
    docsByCollection = { tasks: [taskDoc(1, 100), taskDoc(2, 200, 'habit'), taskDoc(3, 300)] };

    const first = await pullSync(USER);

    expect(first.pulled).toBe(2);
    expect(first.details.some((d) => d.startsWith(`Skipped malformed tasks/${uuid(2)}`))).toBe(true);
    expect(first.details.some((d) => d.startsWith('Pull failed'))).toBe(false);
    expect((await db.tasks.toArray()).map((t) => t.id).sort()).toEqual([uuid(1), uuid(3)]);
    expect((await db.syncWatermarks.get([USER, 'tasks']))?.seconds).toBe(300);
    expect((await listQuarantinedDocs(USER)).map((r) => r.docId)).toEqual([uuid(2)]);

    await pullSync(USER);
    expect(docReads).toEqual([]);
  });

  it('after a build change re-fetches the skipped doc by id and ingests it, though the checkpoint is past it', async () => {
    docsByCollection = { tasks: [taskDoc(1, 100), taskDoc(2, 200, 'habit'), taskDoc(3, 300)] };
    await pullSync(USER);
    expect(await db.tasks.count()).toBe(2);

    // The app updates: the build changes, and the new build understands the type.
    await db.syncQuarantine.toCollection().modify({ appBuild: 'previous-build' });
    docsByCollection = { tasks: [taskDoc(1, 100), taskDoc(2, 200), taskDoc(3, 300)] };
    const second = await pullSync(USER);

    expect(docReads).toEqual([`tasks/${uuid(2)}`]);
    expect((await db.tasks.get(uuid(2)))?.type).toBe('normal');
    expect(await listQuarantinedDocs(USER)).toEqual([]);
    expect(second.pulled).toBeGreaterThanOrEqual(1);
    expect(second.details.some((d) => d.startsWith(`Retry Pulled tasks/${uuid(2)}`))).toBe(true);
  });

  it('a failed retry read never fails the pull, and the ledger survives for the next one', async () => {
    docsByCollection = { tasks: [taskDoc(1, 100, 'habit'), taskDoc(3, 300)] };
    await pullSync(USER);
    await db.syncQuarantine.toCollection().modify({ appBuild: 'previous-build' });
    docsByCollection = { tasks: [taskDoc(1, 100, 'habit'), taskDoc(3, 300), taskDoc(4, 400)] };
    failDocReads = true;

    const result = await pullSync(USER);

    expect(result.details.some((d) => d.startsWith('Quarantine retry skipped'))).toBe(true);
    expect(result.details.some((d) => d.startsWith('Pull failed'))).toBe(false);
    expect(await db.tasks.get(uuid(4))).toBeDefined();
    expect((await listQuarantinedDocs(USER)).map((r) => r.appBuild)).toEqual(['previous-build']);
  });

  it('uses this build\'s identity for new ledger rows', async () => {
    docsByCollection = { tasks: [taskDoc(1, 100, 'habit')] };
    await pullSync(USER);
    expect((await listQuarantinedDocs(USER)).map((r) => r.appBuild)).toEqual([currentAppBuild()]);
  });
});

describe('pushSync — a remote winner this build cannot decode (issue #300)', () => {
  it('is quarantined instead of overwriting the local row; the queue item still completes', async () => {
    const local = { ...taskDoc(1, 0), title: 'local', version: 2 } as unknown as Record<string, unknown>;
    delete local._syncedAt;
    await db.table('tasks').put(local);
    await addToSyncQueue('tasks', uuid(1), SyncOperationType.UPDATE, local as never);
    const remote = { ...taskDoc(1, 0, 'habit'), title: 'from the future', version: 9 } as unknown as Record<string, unknown>;
    const writes: Array<{ path: string; data: Record<string, unknown> }> = [];

    const result = await pushSync(USER, {
      store: {
        getDoc: async () => remote as never,
        setDoc: async (path, data) => { writes.push({ path, data }); },
      },
    });

    expect(result.conflicts).toBe(1);
    expect(writes).toEqual([]);
    expect((await db.tasks.get(uuid(1)))?.title).toBe('local');
    expect((await listQuarantinedDocs(USER)).map((r) => r.docId)).toEqual([uuid(1)]);
  });

  it('a decodable push stays a merge write: it never sends keys the local model does not carry', async () => {
    const local = { ...taskDoc(1, 0), version: 2 } as unknown as Record<string, unknown>;
    delete local._syncedAt;
    await db.table('tasks').put(local);
    await addToSyncQueue('tasks', uuid(1), SyncOperationType.UPDATE, local as never);
    const writes: Array<{ path: string; data: Record<string, unknown> }> = [];

    await pushSync(USER, {
      store: {
        getDoc: async () => ({ ...taskDoc(1, 0), version: 1, futureField: 'kept' }) as never,
        setDoc: async (path, data) => { writes.push({ path, data }); },
      },
    });

    // `SyncDocStore.setDoc` is `setDoc(..., { merge: true })` — a key absent
    // from the payload (the newer client's `futureField`) is left untouched.
    expect(writes).toHaveLength(1);
    expect(writes[0].data).not.toHaveProperty('futureField');
    expect(writes[0].data.version).toBe(2);
  });
});
