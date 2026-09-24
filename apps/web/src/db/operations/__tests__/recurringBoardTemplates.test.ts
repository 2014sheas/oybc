import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  TaskType,
  Timeframe,
  type Board,
  type BoardSource,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  createRecurringBoardTemplate,
  fetchRecurringBoardTemplate,
  fetchTemplatesReferencingTask,
  removeMissingBoardSources,
  softDeleteRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../recurringBoardTemplates';
import { fetchBoardSourceSupply } from '../boardSources';

/**
 * RecurringBoardTemplate CRUD (Phase 6.2) — previously untested at the
 * operations layer. Added alongside P7 (Task Pools + Recurring Boards
 * Rework, docs/POOLS_RECURRING.md §Surfaces item 9) because the
 * Board-settings roster's Pause/Resume toggle (`RepeatingBoardRow`) and
 * "Edit tasks" save (the recurring wizard's edit-mode `persistRecurringTemplate`
 * path, since Board Creation Split web PR D — previously the now-retired
 * `RosterEditSheet`) both rest on `updateRecurringBoardTemplate` — it
 * deserves direct coverage rather than only being exercised incidentally
 * through spawn-path tests.
 */

afterEach(async () => {
  await db.recurringBoardTemplates.clear();
  await db.boards.clear();
  await db.users.clear();
  await db.syncQueue.clear();
});

function baseInput() {
  return {
    name: 'Morning routine',
    timeframe: Timeframe.DAILY,
    boardSize: 3 as const,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: [] as string[],
    isActive: true,
  };
}

describe('recurringBoardTemplates CRUD', () => {
  it('createRecurringBoardTemplate inserts a row and enqueues a sync CREATE', async () => {
    const template = await createRecurringBoardTemplate('user-1', baseInput());

    expect(template.name).toBe('Morning routine');
    expect(template.isActive).toBe(true);
    expect(template.lastSpawnedWindowKey).toBeNull();
    expect(template.version).toBe(1);

    const queue = await db.syncQueue.toArray();
    expect(queue).toHaveLength(1);
    expect(queue[0].entityType).toBe('recurringBoardTemplates');
    expect(queue[0].operationType).toBe(SyncOperationType.CREATE);
  });

  /**
   * \u00a7Member rules \u2014 THE rule for an empty `manualTaskVary`, on either
   * record and on either platform: OMIT it (final review M2). A record the
   * rule editor never touched must serialise exactly as it did before B3;
   * the UPDATE path is the deliberate exception (an empty map there means
   * "clear the dice", which an omission can't say). iOS twin:
   * `BoardWizardPersistRecurringTemplateTests
   * .test_freshCreatePath_omitsAnEmptyManualTaskVary`.
   */
  it('createRecurringBoardTemplate OMITS an empty manualTaskVary and keeps a non-empty one', async () => {
    const empty = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      manualTaskVary: {},
    });
    expect('manualTaskVary' in empty).toBe(false);

    const withDice = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      manualTaskVary: { t1: 2 as const },
    });
    expect(withDice.manualTaskVary).toEqual({ t1: 2 });
  });

  it('Pause/Resume: updateRecurringBoardTemplate flips isActive and bumps version', async () => {
    const template = await createRecurringBoardTemplate('user-1', baseInput());
    expect(template.isActive).toBe(true);

    await updateRecurringBoardTemplate(template.id, { isActive: false });
    const paused = await fetchRecurringBoardTemplate(template.id);
    expect(paused?.isActive).toBe(false);
    expect(paused?.version).toBe(2);

    await updateRecurringBoardTemplate(template.id, { isActive: true });
    const resumed = await fetchRecurringBoardTemplate(template.id);
    expect(resumed?.isActive).toBe(true);
    expect(resumed?.version).toBe(3);
  });

  it('the roster edit sheet save path: updateRecurringBoardTemplate writes poolIds/manualTaskIds/removedTaskIds together', async () => {
    const template = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      poolIds: ['pool-old'],
      manualTaskIds: [],
      removedTaskIds: [],
    });

    await updateRecurringBoardTemplate(template.id, {
      poolIds: ['pool-a', 'pool-b'],
      manualTaskIds: ['manual-1'],
      removedTaskIds: ['removed-1'],
    });

    const updated = await fetchRecurringBoardTemplate(template.id);
    expect(updated?.poolIds).toEqual(['pool-a', 'pool-b']);
    expect(updated?.manualTaskIds).toEqual(['manual-1']);
    expect(updated?.removedTaskIds).toEqual(['removed-1']);
  });

  it('softDeleteRecurringBoardTemplate sets isDeleted/deletedAt and bumps version', async () => {
    const template = await createRecurringBoardTemplate('user-1', baseInput());

    await softDeleteRecurringBoardTemplate(template.id);

    const stored = await db.recurringBoardTemplates.get(template.id);
    expect(stored?.isDeleted).toBe(true);
    expect(stored?.deletedAt).toBeTruthy();
    expect(stored?.version).toBe(2);
  });
});

// ─── Board Sources P4 — removeMissingBoardSources ──────────────────────────

const NOW = '2026-09-01T00:00:00.000Z';

function makeBoard(id: string, overrides: Partial<Board> = {}): Board {
  return {
    id,
    userId: 'user-1',
    name: `Board ${id}`,
    size: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: NOW,
    status: BoardStatus.ACTIVE,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: true,
    totalTasks: 0,
    completedTasks: 0,
    completedLineIds: [],
    isCore: false,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as Board;
}

function makeSourcesInput() {
  return {
    ...baseInput(),
    sources: [
      { sourceId: 'pool-1', kind: 'pool' as const, min: 0, max: null, excludedTaskIds: [], filter: 'all' as const },
      { sourceId: 'board-gone', kind: 'board' as const, min: 0, max: null, excludedTaskIds: [], filter: 'all' as const },
      { sourceId: 'board-archived', kind: 'board' as const, min: 1, max: 2, excludedTaskIds: ['x'], filter: 'todo' as const },
      { sourceId: 'board-live', kind: 'board' as const, min: 0, max: 3, excludedTaskIds: [], filter: 'all' as const },
    ],
    poolIds: ['pool-1'],
    manualTaskIds: [] as string[],
    removedTaskIds: ['x'] as string[],
  };
}

describe('removeMissingBoardSources (the deleted-source ask)', () => {
  it('drops board sources whose board is missing/deleted/archived, keeps live ones, refreshes the trio mirror, and enqueues', async () => {
    // board-gone: no row at all. board-archived: ARCHIVED. board-live: ok.
    await db.boards.add(makeBoard('board-archived', { status: BoardStatus.ARCHIVED }));
    await db.boards.add(makeBoard('board-live'));
    const template = await createRecurringBoardTemplate('user-1', makeSourcesInput());
    await db.syncQueue.clear();

    const changed = await removeMissingBoardSources(template.id);
    expect(changed).toBe(true);

    const updated = await fetchRecurringBoardTemplate(template.id);
    expect(updated?.sources?.map((s) => s.sourceId)).toEqual(['pool-1', 'board-live']);
    // The archived source's exclude dies with it — the trio mirror
    // recomputes from the KEPT sources only.
    expect(updated?.poolIds).toEqual(['pool-1']);
    expect(updated?.removedTaskIds).toEqual([]);
    expect(updated?.version).toBe((template.version ?? 0) + 1);

    const queue = await db.syncQueue.toArray();
    expect(queue).toHaveLength(1);
    expect(queue[0].operationType).toBe(SyncOperationType.UPDATE);
  });

  it('returns false (no write, no enqueue) when every board source is alive', async () => {
    await db.boards.add(makeBoard('board-live'));
    const input = {
      ...baseInput(),
      sources: [
        { sourceId: 'board-live', kind: 'board' as const, min: 0, max: null, excludedTaskIds: [], filter: 'all' as const },
      ],
    };
    const template = await createRecurringBoardTemplate('user-1', input);
    await db.syncQueue.clear();

    expect(await removeMissingBoardSources(template.id)).toBe(false);
    const untouched = await fetchRecurringBoardTemplate(template.id);
    expect(untouched?.version).toBe(template.version);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('returns false for a template with no board-kind sources', async () => {
    const template = await createRecurringBoardTemplate('user-1', baseInput());
    await db.syncQueue.clear();
    expect(await removeMissingBoardSources(template.id)).toBe(false);
  });
});


// ─── 2026-09 audit T2 — "used in repeating boards" from sources ────────────

describe('fetchTemplatesReferencingTask (sources model, not the seedTaskIds snapshot)', () => {
  afterEach(async () => {
    await db.tasks.clear();
    await db.pools.clear();
    await db.boardTasks.clear();
  });

  function makeTask(id: string, overrides: Partial<Task> = {}): Task {
    return {
      id,
      userId: 'user-1',
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
    } as Task;
  }

  function source(sourceId: string, kind: 'pool' | 'board', over: Partial<BoardSource> = {}): BoardSource {
    return { sourceId, kind, min: 0, max: null, excludedTaskIds: [], filter: 'all', ...over };
  }

  const ids = async (taskId: string) =>
    (await fetchTemplatesReferencingTask(taskId)).map((t) => t.id);

  it('an edit that swaps A for B moves the reference — the stale seedTaskIds snapshot said the opposite', async () => {
    await db.tasks.bulkAdd([makeTask('task-a'), makeTask('task-b')]);
    // Created with A (the wizard create path writes the snapshot AND the
    // hand-added layer) …
    const template = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      seedTaskIds: ['task-a'],
      manualTaskIds: ['task-a'],
      sources: [],
    });
    // … then edited to drop A and add B. The edit path never rewrites
    // `seedTaskIds` (wizardPersist's edit branch omits it).
    await updateRecurringBoardTemplate(template.id, { manualTaskIds: ['task-b'] });
    const stored = await fetchRecurringBoardTemplate(template.id);
    expect(stored?.seedTaskIds).toEqual(['task-a']);

    expect(await ids('task-a')).toEqual([]);
    expect(await ids('task-b')).toEqual([template.id]);
  });

  it('a pool source references its members minus that source\'s excludes, whatever the range', async () => {
    await db.tasks.bulkAdd([makeTask('p1'), makeTask('p2'), makeTask('p3')]);
    await db.pools.add({
      id: 'pool-1',
      userId: 'user-1',
      name: 'Pool',
      taskIds: ['p1', 'p2', 'p3'],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    const template = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      manualTaskIds: [],
      sources: [source('pool-1', 'pool', { max: 1, excludedTaskIds: ['p2'] })],
    });

    expect(await ids('p1')).toEqual([template.id]);
    expect(await ids('p3')).toEqual([template.id]);
    expect(await ids('p2')).toEqual([]);
  });

  it('a board source references its live placements even when the "Not done yet" filter would skip a done one', async () => {
    // A compound reads the lifetime isCompleted cache on a source board, so
    // this one is DONE there without any event plumbing.
    await db.tasks.bulkAdd([
      makeTask('b-open'),
      makeTask('b-done', { type: TaskType.COMPOUND, isCompleted: true }),
    ]);
    await db.boards.add(makeBoard('board-src'));
    await db.boardTasks.bulkAdd(
      ['b-open', 'b-done'].map((taskId, col) => ({
        id: `bt-${taskId}`,
        boardId: 'board-src',
        taskId,
        row: 0,
        col,
        isCenter: false,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      })),
    );
    const template = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      manualTaskIds: [],
      sources: [source('board-src', 'board', { filter: 'todo' })],
    });
    // Precondition: the filter WOULD drop b-done from a spawn's supply.
    const info = await fetchBoardSourceSupply('board-src');
    expect(info?.doneTaskIds.has('b-done')).toBe(true);

    expect(await ids('b-open')).toEqual([template.id]);
    expect(await ids('b-done')).toEqual([template.id]);
  });

  it('a soft-deleted template is never listed', async () => {
    await db.tasks.add(makeTask('task-a'));
    const template = await createRecurringBoardTemplate('user-1', {
      ...baseInput(),
      manualTaskIds: ['task-a'],
      sources: [],
    });
    expect(await ids('task-a')).toEqual([template.id]);
    await softDeleteRecurringBoardTemplate(template.id);
    expect(await ids('task-a')).toEqual([]);
  });
});
