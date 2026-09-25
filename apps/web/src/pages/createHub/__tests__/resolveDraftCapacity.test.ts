import { vi, afterEach, describe, expect, it } from 'vitest';

// The component/resolver chain reaches `firebase/config` through the hooks
// barrel (→ useSyncLoop → syncService), whose `initializeApp` throws
// `auth/invalid-api-key` at import on CI (no .env.local). Stub it, as
// `firebase/__tests__/guestMode.test.ts` does; nothing here touches Firebase.
vi.mock('../../../firebase/config', () => ({ auth: {}, firestore: {} }));
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardSource,
  type BoardTask,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../../db/internal';
import { fetchBoardSourceSupplyForWindow } from '../../../db/operations/boardSources';
import { spawnTemplateBoard } from '../../../db/operations/recurringBoardSpawn';
import { resolveDraftCapacity } from '../resolveDraftCapacity';
import { buildSupplyInfoMap, sourceCapacity } from '../wizardSources';
import { boardSupplyEntryForResolution } from '../wizardSourcesLogic';
import { resolveResumableDraft } from '../useResumableDraft';

/**
 * 2026-09 audit T2 — the drafts-list count and the resume step used to
 * resolve a draft through the retired pool-mix mirror (`poolIds` /
 * `removedTaskIds`). That mirror carries no board-kind sources and no
 * ranges, so:
 *   - a draft pulling ONLY a board counted 0 and reopened on Setup;
 *   - a pool source capped by `max` counted the whole pool.
 * These fixtures are exactly those two shapes; each literal below is the
 * number the reopened wizard's capacity shows, not the old read's.
 */

const USER = 'user-1';
const NOW = '2026-09-01T00:00:00.000';

function makeTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makePool(id: string, taskIds: string[]): Pool {
  return {
    id,
    userId: USER,
    name: `Pool ${id}`,
    taskIds,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

function makeBoard(over: Partial<Board> & { id: string }): Board {
  return {
    userId: USER,
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.CUSTOM,
    startDate: '2026-09-01T00:00:00.000',
    endDate: '2099-12-31T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

function source(over: Partial<BoardSource> & Pick<BoardSource, 'sourceId' | 'kind'>): BoardSource {
  return { min: 0, max: null, excludedTaskIds: [], filter: 'all', ...over };
}

/** A v2 blob whose legacy mirror is what the wizard's dual-write produces:
 *  `poolIds` lists pool-kind sources only, so a board-only draft's mirror
 *  is EMPTY. */
function blob(sources: BoardSource[], manualTaskIds: string[] = []): string {
  return JSON.stringify({
    v: 2,
    poolIds: sources.filter((s) => s.kind === 'pool').map((s) => s.sourceId),
    manualTaskIds,
    removedTaskIds: [],
    sources,
  });
}

/** Seeds an ACTIVE source board with `taskIds` placed row-major. */
async function seedSourceBoard(id: string, taskIds: string[]): Promise<void> {
  await db.tasks.bulkAdd(taskIds.map((t) => makeTask(t)));
  await db.boards.add(makeBoard({ id }));
  await db.boardTasks.bulkAdd(
    taskIds.map((taskId, i): BoardTask => ({
      id: `${id}-bt-${i}`,
      boardId: id,
      taskId,
      row: Math.floor(i / 3),
      col: i % 3,
      isCenter: false,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    })),
  );
}

function draftBoard(mix: string): Board {
  return makeBoard({
    id: 'draft-1',
    status: BoardStatus.DRAFT,
    recurringDraftMix: mix,
  });
}

afterEach(async () => {
  await db.tasks.clear();
  await db.pools.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.recurringBoardTemplates.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('resolveDraftCapacity — the drafts-list count', () => {
  it('counts a board-only draft from the board source (old pool-mix read: 0)', async () => {
    await seedSourceBoard('src-board', ['b1', 'b2', 'b3', 'b4']);
    const draft = draftBoard(blob([source({ sourceId: 'src-board', kind: 'board' })]));

    expect(await resolveDraftCapacity(draft)).toBe(4);
  });

  it('respects a pool source capped by max (old pool-mix read: the whole pool)', async () => {
    const ids = Array.from({ length: 10 }, (_, i) => `p${i}`);
    await db.tasks.bulkAdd(ids.map((id) => makeTask(id)));
    await db.pools.add(makePool('pool-1', ids));
    const draft = draftBoard(blob([source({ sourceId: 'pool-1', kind: 'pool', max: 3 })]));

    expect(await resolveDraftCapacity(draft)).toBe(3);
  });

  it('adds a manual task no source supplies on top of a board source', async () => {
    await seedSourceBoard('src-board', ['b1', 'b2']);
    await db.tasks.add(makeTask('m1'));
    const draft = draftBoard(blob([source({ sourceId: 'src-board', kind: 'board' })], ['m1']));

    expect(await resolveDraftCapacity(draft)).toBe(3);
  });

  it('maps a v1 blob (no `sources`) forward through the decoder — pools count uncapped', async () => {
    await db.tasks.bulkAdd([makeTask('a'), makeTask('b'), makeTask('c')]);
    await db.pools.add(makePool('pool-v1', ['a', 'b', 'c']));
    const v1 = JSON.stringify({
      poolIds: ['pool-v1'],
      manualTaskIds: [],
      removedTaskIds: ['b'],
    });

    expect(await resolveDraftCapacity(draftBoard(v1))).toBe(2);
  });

  it('returns 0 for a malformed blob without throwing', async () => {
    expect(await resolveDraftCapacity(draftBoard('not json'))).toBe(0);
  });
});

describe('resolveResumableDraft — the resume step', () => {
  it('reopens a board-only draft on the Tasks step (old pool-mix read: Setup)', async () => {
    // 3×3 with a FREE center needs 8; the board supplies 4.
    await seedSourceBoard('src-board', ['b1', 'b2', 'b3', 'b4']);
    const draft = draftBoard(blob([source({ sourceId: 'src-board', kind: 'board' })]));

    expect((await resolveResumableDraft(draft)).initialStep).toBe(2);
  });

  it('reopens a capped-pool draft on the Tasks step when the cap is below the grid (old read: Preview)', async () => {
    const ids = Array.from({ length: 10 }, (_, i) => `p${i}`);
    await db.tasks.bulkAdd(ids.map((id) => makeTask(id)));
    await db.pools.add(makePool('pool-1', ids));
    const draft = draftBoard(blob([source({ sourceId: 'pool-1', kind: 'pool', max: 3 })]));

    expect((await resolveResumableDraft(draft)).initialStep).toBe(2);
  });

  it('reopens on Preview once the sources can fill the board', async () => {
    await seedSourceBoard('src-board', ['b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'b8']);
    const draft = draftBoard(blob([source({ sourceId: 'src-board', kind: 'board' })]));

    expect((await resolveResumableDraft(draft)).initialStep).toBe(3);
  });
});

/**
 * Owner ruling 2026-09-24 — ENDED BOARDS ARE NEVER SOURCES, and every
 * surface resolves a board source against the NEW board's window start. A
 * repeating board pulling a weekly series whose only instance is LAST week
 * must count 0 from that source identically in the drafts-list capacity,
 * the wizard's live supply (what Preview reads), and the spawned deal.
 * iOS twin: `SourceBoardForWindowTests.swift` (the capacity == preview == deal test).
 */
describe('ended source — capacity == preview == persisted deal', () => {
  const WINDOW_START = '2026-09-16T00:00:00.000';
  const WINDOW_END = '2026-09-16T23:59:59.999';
  const CLOCK = new Date('2026-09-16T12:00:00.000');
  const POOL_IDS = Array.from({ length: 8 }, (_, i) => `p${i}`);
  const SERIES_IDS = ['s1', 's2', 's3'];
  const SOURCES = [
    source({ sourceId: 'pool-1', kind: 'pool' }),
    source({ sourceId: 'wk-last', kind: 'board' }),
  ];

  async function seedFixture(): Promise<void> {
    await db.tasks.bulkAdd([...POOL_IDS, ...SERIES_IDS].map((id) => makeTask(id)));
    await db.pools.add(makePool('pool-1', POOL_IDS));
    await db.boards.add(
      makeBoard({
        id: 'wk-last',
        timeframe: Timeframe.WEEKLY,
        startDate: '2026-09-07T00:00:00.000',
        endDate: '2026-09-13T23:59:59.999',
        spawnedFromTemplateId: 'series-weekly',
      }),
    );
    await db.boardTasks.bulkAdd(
      SERIES_IDS.map((taskId, i): BoardTask => ({
        id: `wk-last-bt-${i}`,
        boardId: 'wk-last',
        taskId,
        row: 0,
        col: i,
        isCenter: false,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      })),
    );
  }

  it('counts 0 from the windowless series on every surface', async () => {
    await seedFixture();
    const draft = makeBoard({
      id: 'draft-1',
      status: BoardStatus.DRAFT,
      timeframe: Timeframe.DAILY,
      startDate: WINDOW_START,
      endDate: WINDOW_END,
      isRecurringDraft: true,
      recurringDraftMix: blob(SOURCES),
    });

    // 1. Drafts-list capacity.
    const capacity = await resolveDraftCapacity(draft, CLOCK);

    // 2. The wizard's live supply (useWizardSources → Preview reads it).
    const resolution = await fetchBoardSourceSupplyForWindow('wk-last', WINDOW_START, CLOCK);
    const entry = boardSupplyEntryForResolution(resolution);
    expect(entry.noBoardForWindow).toBe(true);
    const tasksById = Object.fromEntries((await db.tasks.toArray()).map((t) => [t.id, t]));
    const poolsById = { 'pool-1': makePool('pool-1', POOL_IDS) };
    const preview = sourceCapacity(
      SOURCES,
      buildSupplyInfoMap(SOURCES, poolsById, true, tasksById, { 'wk-last': entry }),
      new Set(),
      {},
    );

    // 3. The spawned deal for the same window.
    const template: RecurringBoardTemplate = {
      id: 'tmpl-daily',
      userId: USER,
      name: 'Daily',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
      isRandomized: true,
      seedTaskIds: [],
      manualTaskIds: [],
      sources: SOURCES,
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);
    const spawned = await spawnTemplateBoard(
      { template, windowStart: WINDOW_START, windowEnd: WINDOW_END, suggestedName: 'Daily' },
      { now: CLOCK },
    );
    expect(spawned.ok).toBe(true);
    if (!spawned.ok) return;
    const dealt = (await db.boardTasks.where('boardId').equals(spawned.boardId).toArray()).map(
      (bt) => bt.taskId,
    );

    expect(capacity).toBe(8);
    expect(preview).toBe(capacity);
    expect(dealt).toHaveLength(capacity);
    for (const id of SERIES_IDS) expect(dealt).not.toContain(id);
    expect(spawned.noBoardForWindowSourceIds).toEqual(['wk-last']);
  });
});
