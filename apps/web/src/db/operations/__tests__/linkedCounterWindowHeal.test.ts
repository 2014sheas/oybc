import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { derivedTaskId, isWindowStampedDerived, Timeframe } from '@oybc/shared';
import { db } from '../../internal';
import { healLinkedCounterWindows } from '../linkedCounterWindowHeal';
import {
  JUNE,
  ROOT,
  SEPT,
  USER,
  boardRow,
  clearAll,
  compoundTask,
  hubLinked,
  incEvent,
  link,
  placement,
  queued,
  rootTask,
} from './linkedCounterFixtures';

/**
 * Windowed linked counters — the heal sweep (owner rule 2026-10-01).
 * Hub-linked = `sharedCounterId` set, not window-stamped.
 */

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-10-01T00:00:00.000Z'));
  await db.tasks.put(rootTask({ currentCount: 7 }));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('healLinkedCounterWindows', () => {
  it('stamps a single placement in place (window fields, createdInWizard, version bump, enqueue)', async () => {
    await db.tasks.put(hubLinked('H'));
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 1, copied: 0 });

    const h = (await db.tasks.get('H'))!;
    expect(h.timeframe).toBe(Timeframe.MONTHLY);
    expect(h.startDate).toBe(JUNE.startDate);
    expect(h.endDate).toBe(JUNE.endDate);
    expect(h.createdInWizard).toBe(true);
    expect(isWindowStampedDerived(h)).toBe(true);
    expect(h.version).toBe(3);
    expect(await queued('tasks')).toEqual(['H']);
  });

  it('two placements: stamps the earlier board, mints a deterministic copy for the later one and repoints it', async () => {
    await db.tasks.put(hubLinked('H'));
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 1, copied: 1 });

    const copyId = derivedTaskId(SEPT.id, ROOT);
    const copy = (await db.tasks.get(copyId))!;
    expect(copy.startDate).toBe(SEPT.startDate);
    expect(copy.endDate).toBe(SEPT.endDate);
    expect(copy.maxCount).toBe(5);
    expect(copy.sharedCounterId).toBe(ROOT);
    expect(isWindowStampedDerived(copy)).toBe(true);

    expect((await db.boardTasks.get('bt-j'))!.taskId).toBe('H');
    const sept = (await db.boardTasks.get('bt-s'))!;
    expect(sept.taskId).toBe(copyId);
    expect(sept.version).toBe(2);
    expect(await queued('boardTasks')).toEqual(['bt-s']);
    expect((await queued('tasks')).sort()).toEqual(['H', copyId].sort());
  });

  it('a healed copy keeps the linked row\u2019s CUSTOM title (2026-10-06)', async () => {
    await db.tasks.put(hubLinked('H', { title: 'Sunday long run' }));
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 1, copied: 1 });

    const copy = (await db.tasks.get(derivedTaskId(SEPT.id, ROOT)))!;
    expect(copy.title).toBe('Sunday long run');
    expect((await db.tasks.get('H'))!.title).toBe('Sunday long run');
  });

  it('a healed copy of an AUTO-titled row is titled from its own fields', async () => {
    await db.tasks.put(hubLinked('H')); // 'Run 5 miles' == auto for Run / 5 / miles
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    await healLinkedCounterWindows(USER);

    expect((await db.tasks.get(derivedTaskId(SEPT.id, ROOT)))!.title).toBe('Run 5 miles');
  });

  it('stamps a child reached only through a compound placement', async () => {
    await db.tasks.bulkPut([hubLinked('H'), compoundTask('C')]);
    await db.compoundChildren.put(link('l1', 'C', 'H'));
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt-c', JUNE.id, 'C'));

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 1, copied: 0 });
    expect((await db.tasks.get('H'))!.startDate).toBe(JUNE.startDate);
  });

  it('is idempotent: a second run plans nothing and enqueues nothing new', async () => {
    await db.tasks.put(hubLinked('H'));
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    await healLinkedCounterWindows(USER);
    const before = await db.syncQueue.count();
    const versions = (await db.tasks.toArray()).map((t) => [t.id, t.version]);

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 0, copied: 0 });
    expect(await db.syncQueue.count()).toBe(before);
    expect((await db.tasks.toArray()).map((t) => [t.id, t.version])).toEqual(versions);
  });

  it('does NOT revive a tombstoned deterministic row: the copy is skipped and the placement left on the source', async () => {
    const copyId = derivedTaskId(SEPT.id, ROOT);
    await db.tasks.put(
      hubLinked(copyId, { isDeleted: true, deletedAt: '2026-08-01T00:00:00.000Z', version: 3, createdInWizard: true }),
    );
    await db.tasks.put(hubLinked('H'));
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    const result = await healLinkedCounterWindows(USER);

    expect(result.copied).toBe(0);
    const tomb = (await db.tasks.get(copyId))!;
    expect(tomb.isDeleted).toBe(true);
    expect(tomb.version).toBe(3);
    expect((await db.boardTasks.get('bt-s'))!.taskId).toBe('H');
    expect(await queued('boardTasks')).toEqual([]);
  });

  it('never duplicates a square: a board already holding a LIVE copy placement is skipped (no mint, no repoint)', async () => {
    const copyId = derivedTaskId(SEPT.id, ROOT);
    const liveCopy = hubLinked(copyId, {
      createdInWizard: true,
      timeframe: Timeframe.MONTHLY,
      startDate: SEPT.startDate,
      endDate: SEPT.endDate,
      version: 5,
    });
    await db.tasks.bulkPut([hubLinked('H'), liveCopy]);
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([
      placement('bt-j', JUNE.id, 'H'),
      placement('bt-s', SEPT.id, 'H', 0, 0),
      placement('bt-s2', SEPT.id, copyId, 0, 1),
    ]);

    const result = await healLinkedCounterWindows(USER);

    expect(result.copied).toBe(0);
    expect((await db.boardTasks.get('bt-s'))!.taskId).toBe('H');
    expect((await db.boardTasks.get('bt-s2'))!.taskId).toBe(copyId);
    expect((await db.tasks.get(copyId))!.version).toBe(5);
    expect(await queued('boardTasks')).toEqual([]);
  });

  it('queues the stamped row with its baseline already computed (payload parity with iOS)', async () => {
    await db.taskEvents.put(incEvent('e1', ROOT, 3, '2026-05-20T00:00:00.000Z'));
    await db.tasks.put(hubLinked('H', { baseline: 0 }));
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));

    await healLinkedCounterWindows(USER);

    const item = (await db.syncQueue.toArray()).find((i) => i.entityType === 'tasks' && i.entityId === 'H')!;
    const payload = typeof item.payload === 'string' ? JSON.parse(item.payload) : item.payload;
    expect((payload as { baseline?: number }).baseline).toBe(3);
  });

  it('refreshes baselines from the root events before each window start', async () => {
    await db.taskEvents.bulkPut([
      incEvent('e1', ROOT, 1, '2026-05-20T00:00:00.000Z'), // before June
      incEvent('e2', ROOT, 2, '2026-06-10T00:00:00.000Z'), // in June
      incEvent('e3', ROOT, 4, '2026-09-05T00:00:00.000Z'), // in Sept
    ]);
    await db.tasks.put(hubLinked('H'));
    await db.boards.bulkPut([boardRow(JUNE), boardRow(SEPT)]);
    await db.boardTasks.bulkPut([placement('bt-j', JUNE.id, 'H'), placement('bt-s', SEPT.id, 'H')]);

    await healLinkedCounterWindows(USER);

    expect((await db.tasks.get('H'))!.baseline).toBe(1);
    expect((await db.tasks.get(derivedTaskId(SEPT.id, ROOT)))!.baseline).toBe(3);
  });

  it('re-derives a sealed board from in-window events only (no latch)', async () => {
    // Latch says complete (7 >= 5) but only 2 miles were logged inside June.
    await db.taskEvents.put(incEvent('e1', ROOT, 2, '2026-06-10T00:00:00.000Z'));
    await db.tasks.put(hubLinked('H', { currentCount: 7, isCompleted: true }));
    await db.boards.put(
      boardRow(JUNE, {
        sealedAt: '2026-07-01T00:00:00.000Z',
        sealedCompletedCells: [0],
        completedTasks: 1,
      }),
    );
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));

    await healLinkedCounterWindows(USER);

    const june = (await db.boards.get(JUNE.id))!;
    expect(june.sealedCompletedCells).toEqual([]);
    expect(june.completedTasks).toBe(0);
  });

  it('ignores another user\'s rows', async () => {
    await db.tasks.put(hubLinked('H', { userId: 'someone-else' }));
    await db.boards.put(boardRow(JUNE, { userId: 'someone-else' }));
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));
    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 0, copied: 0 });
  });
});
