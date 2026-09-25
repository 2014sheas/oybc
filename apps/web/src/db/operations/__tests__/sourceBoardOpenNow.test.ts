import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  TaskType,
  Timeframe,
  type Board,
  type BoardSource,
  type RecurringBoardTemplate,
  findTemplatesPendingSpawn,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  fetchOpenBoardSourceSupply,
  fetchTemplateSupplyResolution,
  resolveOpenSourceBoard,
} from '../boardSources';
import { spawnTemplateBoard } from '../recurringBoardSpawn';
import { removeMissingBoardSources } from '../recurringBoardTemplates';

/**
 * Owner ruling 2026-09-24 (amended) — SOURCES ARE OPEN BOARDS. A stored
 * board source resolves NOW to:
 *   - `live`     — an open board supplies it (a series: its instance open
 *                  now — no containment check against the new board);
 *   - `noWindow` — the source exists but has no board open now
 *                  (ended/sealed one-off; a series with no open instance)
 *                  → no supply, "No board for this window yet";
 *   - `dead`     — the stored row is gone / deleted / archived, or the
 *                  series has no existing instance → the spawn's ask.
 * iOS twin: `SourceBoardOpenNowTests.swift`.
 */

const USER = 'user-1';
// Local-ISO board dates (the web convention). "Now" = Wed 2026-09-16 noon.
const NOW = new Date('2026-09-16T12:00:00.000');

function board(over: Partial<Board> & { id: string }): Board {
  return {
    userId: USER,
    name: `Board ${over.id}`,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: '2026-09-14T00:00:00.000',
    endDate: '2026-09-20T23:59:59.999',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
}

/** Seeds a board with one live placement (so a live resolution has supply). */
async function seed(b: Board, taskId = `t-${b.id}`): Promise<void> {
  await db.boards.add(b);
  await db.tasks.put({
    id: taskId,
    userId: USER,
    title: taskId,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: b.createdAt,
    updatedAt: b.createdAt,
    version: 1,
    isDeleted: false,
  });
  await db.boardTasks.add({
    id: `bt-${b.id}`,
    boardId: b.id,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: b.createdAt,
    updatedAt: b.createdAt,
    version: 1,
    isDeleted: false,
  });
}

const LAST_WEEK = { startDate: '2026-09-07T00:00:00.000', endDate: '2026-09-13T23:59:59.999' };
const NEXT_WEEK = { startDate: '2026-09-21T00:00:00.000', endDate: '2026-09-27T23:59:59.999' };

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.recurringBoardTemplates.clear();
  await db.syncQueue.clear();
});

describe('resolveOpenSourceBoard — one-off boards', () => {
  it('an open one-off resolves live', async () => {
    await seed(board({ id: 'open' }));
    const r = await resolveOpenSourceBoard('open', NOW);
    expect(r.kind).toBe('live');
  });

  it('an ENDED one-off resolves to no board for the window — null supply', async () => {
    await seed(board({ id: 'ended', name: 'Last week', ...LAST_WEEK }));
    const r = await resolveOpenSourceBoard('ended', NOW);
    expect(r).toEqual({ kind: 'noWindow', displayName: 'Last week' });
    const supply = await fetchOpenBoardSourceSupply('ended', NOW);
    expect(supply.kind).toBe('noWindow');
  });

  it('a SEALED one-off resolves to no board for the window', async () => {
    await seed(board({ id: 'sealed', sealedAt: '2026-09-15T00:00:00.000Z' }));
    const r = await resolveOpenSourceBoard('sealed', NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('a deleted, archived or missing one-off is dead', async () => {
    await seed(board({ id: 'deleted', isDeleted: true }));
    await seed(board({ id: 'archived', status: BoardStatus.ARCHIVED }));
    expect((await resolveOpenSourceBoard('deleted', NOW)).kind).toBe('dead');
    expect((await resolveOpenSourceBoard('archived', NOW)).kind).toBe('dead');
    expect((await resolveOpenSourceBoard('nope', NOW)).kind).toBe('dead');
  });
});

describe('resolveOpenSourceBoard — series binding', () => {
  const inSeries = (id: string, dates: { startDate: string; endDate: string }) =>
    board({ id, spawnedFromTemplateId: 'series-1', ...dates });

  it('binds a stale stored id to the instance OPEN NOW', async () => {
    await seed(inSeries('wk-last', LAST_WEEK));
    await seed(inSeries('wk-this', {
      startDate: '2026-09-14T00:00:00.000',
      endDate: '2026-09-20T23:59:59.999',
    }));
    const r = await resolveOpenSourceBoard('wk-last', NOW);
    expect(r.kind === 'live' && r.board.id).toBe('wk-this');
  });

  it('no instance open now → no board for this window (NOT the ended one)', async () => {
    // Only last week exists — the old fallback returned it ("newest started").
    await seed(inSeries('wk-last', LAST_WEEK));
    const r = await resolveOpenSourceBoard('wk-last', NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('never binds to a FUTURE instance either', async () => {
    await seed(inSeries('wk-next', NEXT_WEEK));
    const r = await resolveOpenSourceBoard('wk-next', NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('an in-window instance that is sealed is not a source', async () => {
    await seed(board({
      id: 'wk-this-sealed',
      spawnedFromTemplateId: 'series-1',
      sealedAt: '2026-09-15T00:00:00.000Z',
    }));
    const r = await resolveOpenSourceBoard('wk-this-sealed', NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('a series whose every instance is archived is dead (the ask)', async () => {
    await seed(board({ id: 'a1', spawnedFromTemplateId: 'series-x', status: BoardStatus.ARCHIVED }));
    expect((await resolveOpenSourceBoard('a1', NOW)).kind).toBe('dead');
  });
});

describe('roster + ask: no board for this window is NOT a missing source', () => {
  const source: BoardSource = {
    sourceId: 'wk-last',
    kind: 'board',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
  };
  const template: RecurringBoardTemplate = {
    id: 'tmpl-1',
    userId: USER,
    name: 'Daily',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: true,
    seedTaskIds: [],
    manualTaskIds: [],
    sources: [source],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };

  it('removeMissingBoardSources keeps a series source with no current instance', async () => {
    // Ended long ago relative to the wall clock → `noWindow`, never `dead`.
    await seed(board({ id: 'wk-last', spawnedFromTemplateId: 'series-1', ...LAST_WEEK }));
    await db.recurringBoardTemplates.add(template);
    expect(await removeMissingBoardSources('tmpl-1')).toBe(false);
    expect((await db.recurringBoardTemplates.get('tmpl-1'))!.sources).toEqual([source]);
    expect(
      (await db.syncQueue.toArray()).filter((q) => q.operationType === SyncOperationType.UPDATE),
    ).toHaveLength(0);
  });

  it('fetchTemplateSupplyResolution: empty supply, not a dead source', async () => {
    await seed(board({ id: 'wk-last', spawnedFromTemplateId: 'series-1', ...LAST_WEEK }));
    const { byTemplateId } = await fetchTemplateSupplyResolution([template]);
    expect(byTemplateId['tmpl-1'].deadBoardSourceIds).toEqual([]);
    expect(byTemplateId['tmpl-1'].supplies[0].supplyTaskIds).toEqual([]);
  });
});

/**
 * The amended ruling's headline case: a MONTHLY repeating board pulling a
 * WEEKLY series, dealt mid-month. The week containing the 1st has ended —
 * the board pulls the CURRENT week (what the Sources sheet shows), not
 * nothing. Containment against the new board's start would bind the ended
 * first week and deal 0 from it.
 */
describe('a monthly built mid-month from a weekly series', () => {
  it('pulls the CURRENT week', async () => {
    const firstWeek = Array.from({ length: 9 }, (_, i) => `f${i}`);
    const currentWeek = Array.from({ length: 9 }, (_, i) => `c${i}`);
    const inSeries = (id: string, dates: { startDate: string; endDate: string }) =>
      board({ id, spawnedFromTemplateId: 'series-weekly', ...dates });
    const seedMany = async (b: Board, ids: string[]) => {
      await db.boards.add(b);
      for (const [i, taskId] of ids.entries()) {
        await db.tasks.put({
          id: taskId,
          userId: USER,
          title: taskId,
          type: TaskType.NORMAL,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: b.createdAt,
          updatedAt: b.createdAt,
          version: 1,
          isDeleted: false,
        });
        await db.boardTasks.add({
          id: `bt-${b.id}-${i}`,
          boardId: b.id,
          taskId,
          row: Math.floor(i / 3),
          col: i % 3,
          isCenter: false,
          createdAt: b.createdAt,
          updatedAt: b.createdAt,
          version: 1,
          isDeleted: false,
        });
      }
    };
    await seedMany(
      inSeries('wk-first', { startDate: '2026-08-31T00:00:00.000', endDate: '2026-09-06T23:59:59.999' }),
      firstWeek,
    );
    await seedMany(
      inSeries('wk-current', { startDate: '2026-09-14T00:00:00.000', endDate: '2026-09-20T23:59:59.999' }),
      currentWeek,
    );
    const monthly: RecurringBoardTemplate = {
      id: 'tmpl-monthly',
      userId: USER,
      name: 'September',
      timeframe: Timeframe.MONTHLY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      seedTaskIds: [],
      manualTaskIds: [],
      sources: [
        { sourceId: 'wk-first', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all' },
      ],
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(monthly);

    const result = await spawnTemplateBoard(
      {
        template: monthly,
        windowStart: '2026-09-01T00:00:00.000',
        windowEnd: '2026-09-30T23:59:59.999',
        suggestedName: 'September',
      },
      { now: NOW }, // 2026-09-16 — mid-month
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.noBoardForWindowSourceIds).toEqual([]);
    const dealt = (await db.boardTasks.where('boardId').equals(result.boardId).toArray()).map(
      (bt) => bt.taskId,
    );
    expect(new Set(dealt)).toEqual(new Set(currentWeek));
  });
});

/**
 * Final-review F3, end to end: at a window boundary where NEITHER series has
 * this window's board yet, a monthly template M pulling from a WEEKLY series W
 * must spawn AFTER W (the pending order the spawn hook iterates), so M's
 * board source binds to W's fresh instance LIVE in the same pass. Under plain
 * parents-first order M spawns first, W's series has only last week's (ended)
 * instance, and M's source resolves `noWindow`. iOS twin:
 * `SourceBoardOpenNowTests.testF3_*`.
 */
describe('F3: dependency-ordered spawn pass (weekly series → monthly consumer)', () => {
  // Tue 2026-09-01 noon: the September window and the week of Mon 08-31 are
  // both open, and neither template has spawned them.
  const BOUNDARY = new Date('2026-09-01T12:00:00.000');
  const weeklyTasks = Array.from({ length: 9 }, (_, i) => `w${i}`);

  const tmpl = (over: Partial<RecurringBoardTemplate> & { id: string }): RecurringBoardTemplate => ({
    userId: USER,
    name: over.id,
    timeframe: Timeframe.WEEKLY,
    boardSize: 3,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: true,
    seedTaskIds: [],
    manualTaskIds: [],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-08-01T00:00:00.000Z',
    updatedAt: '2026-08-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  });

  it('spawns W first, then M binds W\'s new instance live (no noWindow, non-zero supply)', async () => {
    for (const id of weeklyTasks) {
      await db.tasks.put({
        id,
        userId: USER,
        title: id,
        type: TaskType.NORMAL,
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: '2026-08-01T00:00:00.000Z',
        updatedAt: '2026-08-01T00:00:00.000Z',
        version: 1,
        isDeleted: false,
      });
    }
    // W's previous (ended) instance — the id M's source row stored.
    await seed(
      board({
        id: 'w-prev',
        spawnedFromTemplateId: 'W',
        startDate: '2026-08-24T00:00:00.000',
        endDate: '2026-08-30T23:59:59.999',
      }),
    );
    const W = tmpl({ id: 'W', seedTaskIds: weeklyTasks, manualTaskIds: weeklyTasks });
    const M = tmpl({
      id: 'M',
      timeframe: Timeframe.MONTHLY,
      sources: [{ sourceId: 'w-prev', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all' }],
    });
    await db.recurringBoardTemplates.bulkAdd([M, W]);

    const pending = findTemplatesPendingSpawn([M, W], await db.boards.toArray(), 'monday', BOUNDARY);
    const spawnedOrder: string[] = [];
    const byTemplate: Record<string, Awaited<ReturnType<typeof spawnTemplateBoard>>> = {};
    for (const p of pending) {
      byTemplate[p.template.id] = await spawnTemplateBoard(p, { now: BOUNDARY });
      spawnedOrder.push(p.template.id);
    }
    const w = byTemplate.W;
    const m = byTemplate.M;
    expect(w.ok && m.ok).toBe(true);
    if (!w.ok || !m.ok) return;
    // The outcome first (what the user sees), then the order that caused it.
    expect(m.noBoardForWindowSourceIds).toEqual([]);
    expect(spawnedOrder).toEqual(['W', 'M']);
    const dealtOnM = (await db.boardTasks.where('boardId').equals(m.boardId).toArray()).map((bt) => bt.taskId);
    expect(dealtOnM.length).toBeGreaterThan(0);
    const onW = new Set((await db.boardTasks.where('boardId').equals(w.boardId).toArray()).map((bt) => bt.taskId));
    expect(dealtOnM.every((id) => onW.has(id))).toBe(true);
  });
});
