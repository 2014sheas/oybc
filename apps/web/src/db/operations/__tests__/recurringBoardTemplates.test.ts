import { afterEach, describe, expect, it } from 'vitest';
import { CenterSquareType, SyncOperationType, Timeframe } from '@oybc/shared';
import { db } from '../../internal';
import {
  createRecurringBoardTemplate,
  fetchRecurringBoardTemplate,
  softDeleteRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../recurringBoardTemplates';

/**
 * RecurringBoardTemplate CRUD (Phase 6.2) — previously untested at the
 * operations layer. Added alongside P7 (Task Pools + Recurring Boards
 * Rework, docs/POOLS_RECURRING.md §Surfaces item 9) because the
 * Board-settings roster's Pause/Resume toggle (`RepeatingBoardRow`) and
 * "Edit tasks" save (`RosterEditSheet`) both rest on
 * `updateRecurringBoardTemplate` — it deserves direct coverage rather
 * than only being exercised incidentally through spawn-path tests.
 */

afterEach(async () => {
  await db.recurringBoardTemplates.clear();
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
