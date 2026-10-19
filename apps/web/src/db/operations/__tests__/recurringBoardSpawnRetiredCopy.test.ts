import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { spawnTemplateBoard } from '../recurringBoardSpawn';

/**
 * The owner's daily repeating board (2026-10-19): the retired slice-4a
 * placement sweep tombstoned its hand-added linked copy "Run 2 Miles" as an
 * orphan without re-keying the record, and every window then skipped with
 * `has_deleted_tasks`. The spawn now repoints the copy at its live root.
 */

const NOW = '2026-10-19T00:00:00.000Z';
const WINDOW_START = '2026-10-19T00:00:00.000';
const WINDOW_END = '2026-10-19T23:59:59.999';
const ROOT = 'root-miles';
const COPY = 'copy-miles';

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id, userId: 'user-1', title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    ...overrides,
  };
}

const FILLERS = Array.from({ length: 8 }, (_, i) => `f${i}`);

function template(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'tmpl-daily', userId: 'user-1', name: 'Everyday exercise', timeframe: Timeframe.DAILY,
    boardSize: 3, centerSquareType: CenterSquareType.NONE, isRandomized: false,
    seedTaskIds: [ROOT, ...FILLERS], poolIds: [], removedTaskIds: [], sources: [],
    manualTaskIds: [COPY, ...FILLERS], manualTaskVary: { [COPY]: 0 },
    lastSpawnedWindowKey: '2026-10-18T00:00:00.000', isActive: true,
    createdAt: NOW, updatedAt: NOW, version: 8, isDeleted: false,
    ...overrides,
  };
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-10-19T12:00:00.000'));
  await db.tasks.bulkAdd([
    task(ROOT, {
      title: 'Run 3 Miles', type: TaskType.COUNTING, action: 'Run', unit: 'Miles', maxCount: 3,
      currentCount: 0, countKind: 'continuous', timeframeGoals: { yearly: 365 },
    }),
    task(COPY, {
      title: 'Run 2 Miles', type: TaskType.COUNTING, action: 'Run', unit: 'Miles', maxCount: 2,
      currentCount: 0, countKind: 'continuous', sharedCounterId: ROOT,
      isDeleted: true, deletedAt: '2026-10-18T11:50:36Z',
    }),
    ...FILLERS.map((id) => task(id)),
  ]);
});

afterEach(async () => {
  vi.useRealTimers();
  await db.tasks.clear();
  await db.recurringBoardTemplates.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('spawnTemplateBoard — a hand-added copy retired by the placement sweep', () => {
  it('spawns with the root at the copy\'s goal and persists the repointed record', async () => {
    const t = template();
    await db.recurringBoardTemplates.add(t);

    const result = await spawnTemplateBoard({
      template: t, windowStart: WINDOW_START, windowEnd: WINDOW_END, suggestedName: 'Everyday exercise',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const placed = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(placed.map((bt) => bt.taskId)).not.toContain(COPY);
    expect(placed.find((bt) => bt.taskId === ROOT)).toMatchObject({ targetOverride: 2, targetKind: 'continuous' });

    const stored = await db.recurringBoardTemplates.get(t.id);
    expect(stored?.manualTaskIds).toEqual([ROOT, ...FILLERS]);
    expect(stored?.manualTaskTargets).toEqual({ [ROOT]: { target: 2, kind: 'continuous' } });
    expect(stored?.lastSpawnedWindowKey).toBe(WINDOW_START);
    const queued = await db.syncQueue.filter((item) => item.entityId === t.id).toArray();
    expect(queued.length).toBeGreaterThan(0);
  });

  it('a task the person deleted still skips the window', async () => {
    await db.tasks.update('f0', { isDeleted: true });
    const t = template();
    await db.recurringBoardTemplates.add(t);

    const result = await spawnTemplateBoard({
      template: t, windowStart: WINDOW_START, windowEnd: WINDOW_END, suggestedName: 'Everyday exercise',
    });
    expect(result).toEqual({ ok: false, templateId: t.id, reason: 'has_deleted_tasks' });
  });
});
