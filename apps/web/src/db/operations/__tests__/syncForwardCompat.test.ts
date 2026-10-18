import { afterEach, describe, expect, it } from 'vitest';
import { SYNC_COLLECTIONS } from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch } from '../taskEventPull';
import { retryQuarantinedDocs } from '../quarantineRetry';
import {
  currentAppBuild,
  fetchRetryableQuarantine,
  listQuarantinedDocs,
  quarantinePulledDoc,
} from '../syncQuarantine';
import { putRemoteWinner } from '../pullApply';
import { healMissingCompletionEvents } from '../taskEventPull';
import { releaseQuarantinedDocs } from '../syncQuarantine';

/**
 * Forward-compatible pull (issue #300, ROADMAP Track L4; docs/SYNC_STRATEGY.md
 * §Forward-compatible pull). A doc written by a NEWER app version can carry an
 * enum value this build's schema rejects. The contract under test:
 *   1. never wedge — the doc is skipped and ledgered, its siblings apply;
 *   2. never lose — a later build re-fetches it by id (`syncQuarantine`);
 *   3. never clobber — an undecodable remote winner of a push is quarantined,
 *      not stored raw.
 * iOS twin: `SyncForwardCompatTests.swift`.
 */

const USER = 'user-1';
const NOW = '2026-07-19T00:00:00.000Z';
const OLD = '0.9+aaaaaaaaaaaa';
const NEW = '1.0+bbbbbbbbbbbb';
const uuid = (kind: number, n: number) => `${String(kind).padStart(8, '0')}-0000-4000-8000-${String(n).padStart(12, '0')}`;

const task = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(2, n), userId: USER, title: `T${n}`, type: 'normal', isCompleted: false,
  totalCompletions: 0, totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...over,
});
const board = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(1, n), userId: USER, name: `B${n}`, status: 'active', boardSize: 3, timeframe: 'daily',
  startDate: NOW, centerSquareType: 'none', isRandomized: false, totalTasks: 9, completedTasks: 0,
  linesCompleted: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...over,
});
const event = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(4, n), userId: USER, taskId: uuid(2, 1), kind: 'completion', occurredAt: NOW,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...over,
});
const placement = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(3, n), boardId: uuid(1, 1), taskId: uuid(2, 1), row: 0, col: 0, isCenter: false,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...over,
});
const core = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(6, n), userId: USER, timeframe: 'daily', corePoolIds: [], coreDefaultTaskIds: [],
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...over,
});
const template = (n: number, over: Record<string, unknown> = {}) => ({
  id: uuid(7, n), userId: USER, name: `R${n}`, timeframe: 'daily', boardSize: 3, centerSquareType: 'none',
  isRandomized: false, seedTaskIds: [], lastSpawnedWindowKey: null, isActive: true, createdAt: NOW,
  updatedAt: NOW, version: 1, isDeleted: false, ...over,
});

afterEach(async () => {
  await Promise.all([
    ...SYNC_COLLECTIONS.map((c) => db.table(c).clear()),
    db.syncQueue.clear(),
    db.syncQuarantine.clear(),
  ]);
});

describe('applyRemoteSubdoc — a future enum value is skipped and ledgered (never wedges)', () => {
  it('skips a future-typed task, applies its siblings, and ledgers the skipped one', async () => {
    const statuses = [
      await applyRemoteSubdoc('tasks', task(1), USER),
      await applyRemoteSubdoc('tasks', task(2, { type: 'habit' }), USER),
      await applyRemoteSubdoc('tasks', task(3), USER),
    ];

    expect(statuses[0]).toMatch(/^Pulled /);
    expect(statuses[1]).toMatch(/^Skipped malformed tasks\/.*type: .*\(quarantined\)$/);
    expect(statuses[2]).toMatch(/^Pulled /);
    expect((await db.tasks.toArray()).map((t) => t.id).sort()).toEqual([uuid(2, 1), uuid(2, 3)]);
    expect(await listQuarantinedDocs(USER)).toEqual([
      expect.objectContaining({ collection: 'tasks', docId: uuid(2, 2), appBuild: currentAppBuild() }),
    ]);
  });

  const cases: Array<{ name: string; collection: Parameters<typeof applyRemoteSubdoc>[0]; table: string; valid: unknown; future: unknown; futureId: string }> = [
    { name: 'tasks.type', collection: 'tasks', table: 'tasks', valid: task(10), future: task(11, { type: 'habit' }), futureId: uuid(2, 11) },
    { name: 'boards.status', collection: 'boards', table: 'boards', valid: board(10), future: board(11, { status: 'paused' }), futureId: uuid(1, 11) },
    { name: 'boards.timeframe', collection: 'boards', table: 'boards', valid: board(10), future: board(11, { timeframe: 'quarterly' }), futureId: uuid(1, 11) },
    { name: 'coreBoardDefaults.timeframe', collection: 'coreBoardDefaults', table: 'coreBoardDefaults', valid: core(10), future: core(11, { timeframe: 'quarterly' }), futureId: uuid(6, 11) },
    { name: 'recurringBoardTemplates.timeframe', collection: 'recurringBoardTemplates', table: 'recurringBoardTemplates', valid: template(10), future: template(11, { timeframe: 'quarterly' }), futureId: uuid(7, 11) },
  ];
  for (const c of cases) {
    it(`ledgers a future ${c.name} and still applies the valid sibling`, async () => {
      expect(await applyRemoteSubdoc(c.collection, c.valid, USER)).toMatch(/^Pulled /);
      expect(await applyRemoteSubdoc(c.collection, c.future, USER)).toMatch(/\(quarantined\)$/);

      expect(await db.table(c.table).count()).toBe(1);
      expect((await listQuarantinedDocs(USER)).map((r) => [r.collection, r.docId])).toEqual([[c.collection, c.futureId]]);
    });
  }

  it('ledgers a future task-event kind through the batched events pull; the batch still applies', async () => {
    await db.tasks.add(task(1) as never);

    const batch = await applyTaskEventsBatch(USER, [event(1), event(2, { kind: 'decrement' }), event(3)]);

    expect(batch.pulled).toBe(2);
    expect(batch.details.some((d) => d.startsWith(`Skipped malformed taskEvents/${uuid(4, 2)}`) && d.endsWith('(quarantined)'))).toBe(true);
    expect(await db.taskEvents.count()).toBe(2);
    expect((await listQuarantinedDocs(USER)).map((r) => [r.collection, r.docId])).toEqual([['taskEvents', uuid(4, 2)]]);
  });

  it('tolerates an unknown placement targetKind (applies, no ledger row)', async () => {
    const status = await applyRemoteSubdoc('boardTasks', placement(1, { targetKind: 'quantum', targetOverride: 5 }), USER);

    expect(status).toMatch(/^Pulled /);
    expect(await listQuarantinedDocs(USER)).toEqual([]);
    expect((await db.boardTasks.get(uuid(3, 1)))?.targetKind).toBeUndefined();
  });

  it('does not ledger a doc with no id or another account\'s userId (nothing to re-fetch / not ours)', async () => {
    expect(await quarantinePulledDoc(USER, 'tasks', { title: 'no id' }, 'bad')).toBe(false);
    expect(await quarantinePulledDoc(USER, 'tasks', { id: uuid(2, 1), userId: 'someone-else' }, 'bad')).toBe(false);
    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });

  it('ledgers a compound link whose parent is not local; keeps the ordinary mismatch skips out of the ledger', async () => {
    const link = { id: uuid(5, 1), compoundTaskId: uuid(2, 50), childTaskId: uuid(2, 1), childIndex: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false };

    expect(await applyRemoteSubdoc('compoundChildren', link, USER)).toMatch(/parent compound not yet present locally$/);
    expect(await applyRemoteSubdoc('tasks', task(2, { userId: 'someone-else' }), USER)).toMatch(/userId mismatch$/);

    expect((await listQuarantinedDocs(USER)).map((r) => [r.collection, r.docId])).toEqual([['compoundChildren', uuid(5, 1)]]);
  });

  it('releases a ledgered doc the moment it applies (a normal pull, a local win, or an identical echo)', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1), 'old failure', OLD);
    await quarantinePulledDoc(USER, 'tasks', task(2), 'old failure', OLD);
    await quarantinePulledDoc(USER, 'tasks', task(3), 'old failure', OLD);
    await db.tasks.put(task(2, { version: 5 }) as never); // local wins against a stale remote
    await db.tasks.put(task(3) as never); // identical echo

    await applyRemoteSubdoc('tasks', task(1), USER);
    await applyRemoteSubdoc('tasks', task(2), USER);
    await applyRemoteSubdoc('tasks', task(3), USER);

    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });
});

describe('healMissingCompletionEvents — never mints over an event this build could not read', () => {
  it('waits while a taskEvents doc is quarantined, then resumes', async () => {
    await db.tasks.put(task(1, { isCompleted: true }) as never);
    await quarantinePulledDoc(USER, 'taskEvents', event(1, { kind: 'decrement' }), 'x');

    expect(await healMissingCompletionEvents(USER)).toBe(0);
    expect(await db.taskEvents.count()).toBe(0);

    await releaseQuarantinedDocs(USER, 'taskEvents', [uuid(4, 1)]);
    expect(await healMissingCompletionEvents(USER)).toBe(1);
  });
});

describe('putRemoteWinner — the push path never stores an undecodable winner raw', () => {
  it('quarantines a future-typed remote winner and leaves the local row alone', async () => {
    await db.tasks.put(task(1, { title: 'local' }) as never);

    const stored = await putRemoteWinner('tasks', task(1, { type: 'habit', version: 9, title: 'from the future' }) as never, USER);

    expect(stored).toBe(false);
    expect((await db.tasks.get(uuid(2, 1)))?.title).toBe('local');
    expect((await listQuarantinedDocs(USER)).map((r) => r.docId)).toEqual([uuid(2, 1)]);
  });

  it('stores a decodable winner (validated shape) and releases any ledger row', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1), 'old', OLD);

    const stored = await putRemoteWinner('tasks', { ...task(1, { version: 2 }), futureField: 'x' } as never, USER);

    expect(stored).toBe(true);
    const row = (await db.tasks.get(uuid(2, 1))) as unknown as Record<string, unknown>;
    expect(row.version).toBe(2);
    expect(row.futureField).toBeUndefined();
    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });
});

describe('retryQuarantinedDocs — a new build re-fetches exactly what an earlier build skipped', () => {
  /** A fake remote: id → doc per collection. */
  function makeRemote(docs: Record<string, Record<string, unknown>>) {
    const fetches: string[] = [];
    return {
      fetches,
      fetchDoc: async (collection: string, id: string) => {
        fetches.push(`${collection}/${id}`);
        return docs[`${collection}/${id}`] ?? null;
      },
    };
  }

  it('does nothing under the build that recorded the row', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1, { type: 'habit' }), 'x', NEW);
    const remote = makeRemote({});

    const out = await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);

    expect(out).toEqual({ pulled: 0, details: [] });
    expect(remote.fetches).toEqual([]);
    expect(await fetchRetryableQuarantine(USER, NEW)).toEqual([]);
  });

  it('re-fetches by id under a new build and ingests the doc and its dependent in apply order', async () => {
    await db.boards.put(board(1) as never);
    await quarantinePulledDoc(USER, 'boardTasks', placement(1), 'depends', OLD);
    await quarantinePulledDoc(USER, 'tasks', task(1, { type: 'habit' }), 'x', OLD);
    // the new build understands the type — the remote doc is now valid
    const remote = makeRemote({ [`tasks/${uuid(2, 1)}`]: task(1), [`boardTasks/${uuid(3, 1)}`]: placement(1) });

    const out = await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);

    expect(remote.fetches).toEqual([`tasks/${uuid(2, 1)}`, `boardTasks/${uuid(3, 1)}`]);
    expect(out.pulled).toBe(2);
    expect(await db.tasks.count()).toBe(1);
    expect(await db.boardTasks.count()).toBe(1);
    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });

  it('keeps a still-undecodable doc, re-stamped with the new build so it is not re-fetched again', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1, { type: 'habit' }), 'x', OLD);
    const remote = makeRemote({ [`tasks/${uuid(2, 1)}`]: task(1, { type: 'habit' }) });

    await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);
    await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);

    expect(remote.fetches).toEqual([`tasks/${uuid(2, 1)}`]);
    expect((await listQuarantinedDocs(USER)).map((r) => [r.docId, r.appBuild])).toEqual([[uuid(2, 1), NEW]]);
  });

  it('re-stamps a doc rejected for a permanent reason, so it waits for the next build', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1), 'x', OLD);
    const remote = makeRemote({ [`tasks/${uuid(2, 1)}`]: task(1, { userId: 'someone-else' }) });

    await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);

    expect(await db.tasks.count()).toBe(0);
    expect((await listQuarantinedDocs(USER)).map((r) => r.appBuild)).toEqual([NEW]);
  });

  it('releases a doc that no longer exists on the server', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1, { type: 'habit' }), 'x', OLD);

    const out = await retryQuarantinedDocs(USER, makeRemote({}).fetchDoc, NEW);

    expect(out.details).toEqual([`Released quarantined tasks/${uuid(2, 1)}: no longer on the server`]);
    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });

  it('retries a future event kind through the events batch path', async () => {
    await db.tasks.add(task(1) as never);
    await quarantinePulledDoc(USER, 'taskEvents', event(1, { kind: 'decrement' }), 'x', OLD);
    const remote = makeRemote({ [`taskEvents/${uuid(4, 1)}`]: event(1) });

    const out = await retryQuarantinedDocs(USER, remote.fetchDoc, NEW);

    expect(out.pulled).toBe(1);
    expect(await db.taskEvents.count()).toBe(1);
    expect(await listQuarantinedDocs(USER)).toEqual([]);
  });

  it('caps one pass and leaves the rest for the next pull', async () => {
    for (const n of [1, 2, 3]) await quarantinePulledDoc(USER, 'tasks', task(n, { type: 'habit' }), 'x', OLD);
    const remote = makeRemote({});

    await retryQuarantinedDocs(USER, remote.fetchDoc, NEW, 2);

    expect(remote.fetches).toHaveLength(2);
    expect(await listQuarantinedDocs(USER)).toHaveLength(1);
  });

  it('propagates a transport failure and leaves every row for the next pull', async () => {
    await quarantinePulledDoc(USER, 'tasks', task(1, { type: 'habit' }), 'x', OLD);

    await expect(retryQuarantinedDocs(USER, async () => { throw new Error('offline'); }, NEW)).rejects.toThrow('offline');

    expect((await listQuarantinedDocs(USER)).map((r) => r.appBuild)).toEqual([OLD]);
  });
});
