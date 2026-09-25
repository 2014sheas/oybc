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
} from '@oybc/shared';
import { db } from '../../internal';
import {
  fetchBoardSourceSupplyForWindow,
  fetchTemplateSupplyResolution,
  resolveSourceBoardForWindow,
} from '../boardSources';
import { removeMissingBoardSources } from '../recurringBoardTemplates';

/**
 * Owner ruling 2026-09-24 — ENDED BOARDS ARE NEVER SOURCES. A stored board
 * source resolves, for the window starting at `reference`, to:
 *   - `live`     — an open board supplies it;
 *   - `noWindow` — the source exists but has no open board for the window
 *                  (ended/sealed one-off; a series with no instance
 *                  containing the reference) → no supply, "No board for
 *                  this window yet";
 *   - `dead`     — the stored row is gone / deleted / archived, or the
 *                  series has no existing instance → the spawn's ask.
 * iOS twin: `SourceBoardForWindowTests.swift`.
 */

const USER = 'user-1';
// Local-ISO board dates (the web convention). "Now" = Wed 2026-09-16 noon.
const NOW = new Date('2026-09-16T12:00:00.000');
const REF_THIS_WEEK = '2026-09-14T00:00:00.000';

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

describe('resolveSourceBoardForWindow — one-off boards', () => {
  it('an open one-off resolves live', async () => {
    await seed(board({ id: 'open' }));
    const r = await resolveSourceBoardForWindow('open', REF_THIS_WEEK, NOW);
    expect(r.kind).toBe('live');
  });

  it('an ENDED one-off resolves to no board for the window — null supply', async () => {
    await seed(board({ id: 'ended', name: 'Last week', ...LAST_WEEK }));
    const r = await resolveSourceBoardForWindow('ended', REF_THIS_WEEK, NOW);
    expect(r).toEqual({ kind: 'noWindow', displayName: 'Last week' });
    const supply = await fetchBoardSourceSupplyForWindow('ended', REF_THIS_WEEK, NOW);
    expect(supply.kind).toBe('noWindow');
  });

  it('a SEALED one-off resolves to no board for the window', async () => {
    await seed(board({ id: 'sealed', sealedAt: '2026-09-15T00:00:00.000Z' }));
    const r = await resolveSourceBoardForWindow('sealed', REF_THIS_WEEK, NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('a deleted, archived or missing one-off is dead', async () => {
    await seed(board({ id: 'deleted', isDeleted: true }));
    await seed(board({ id: 'archived', status: BoardStatus.ARCHIVED }));
    expect((await resolveSourceBoardForWindow('deleted', REF_THIS_WEEK, NOW)).kind).toBe('dead');
    expect((await resolveSourceBoardForWindow('archived', REF_THIS_WEEK, NOW)).kind).toBe('dead');
    expect((await resolveSourceBoardForWindow('nope', REF_THIS_WEEK, NOW)).kind).toBe('dead');
  });
});

describe('resolveSourceBoardForWindow — series binding', () => {
  const inSeries = (id: string, dates: { startDate: string; endDate: string }) =>
    board({ id, spawnedFromTemplateId: 'series-1', ...dates });

  it("binds a stale stored id to the instance CONTAINING the new board's window start", async () => {
    await seed(inSeries('wk-last', LAST_WEEK));
    await seed(inSeries('wk-this', {
      startDate: '2026-09-14T00:00:00.000',
      endDate: '2026-09-20T23:59:59.999',
    }));
    const r = await resolveSourceBoardForWindow('wk-last', REF_THIS_WEEK, NOW);
    expect(r.kind === 'live' && r.board.id).toBe('wk-this');
  });

  it('no instance contains the reference → no board for this window (NOT the ended one)', async () => {
    // Only last week exists — the old fallback returned it ("newest started").
    await seed(inSeries('wk-last', LAST_WEEK));
    const r = await resolveSourceBoardForWindow('wk-last', REF_THIS_WEEK, NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('never binds to a FUTURE instance either', async () => {
    await seed(inSeries('wk-next', NEXT_WEEK));
    const r = await resolveSourceBoardForWindow('wk-next', REF_THIS_WEEK, NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('a containing instance that is sealed is not a source', async () => {
    await seed(board({
      id: 'wk-this-sealed',
      spawnedFromTemplateId: 'series-1',
      sealedAt: '2026-09-15T00:00:00.000Z',
    }));
    const r = await resolveSourceBoardForWindow('wk-this-sealed', REF_THIS_WEEK, NOW);
    expect(r.kind).toBe('noWindow');
  });

  it('a series whose every instance is archived is dead (the ask)', async () => {
    await seed(board({ id: 'a1', spawnedFromTemplateId: 'series-x', status: BoardStatus.ARCHIVED }));
    expect((await resolveSourceBoardForWindow('a1', REF_THIS_WEEK, NOW)).kind).toBe('dead');
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
