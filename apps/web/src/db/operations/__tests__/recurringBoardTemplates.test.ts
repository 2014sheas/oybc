import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  Timeframe,
  type Board,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  createRecurringBoardTemplate,
  fetchRecurringBoardTemplate,
  removeMissingBoardSources,
  softDeleteRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../recurringBoardTemplates';

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

