import { afterEach, describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../../db/internal';
import { persistRecurringTemplate } from '../wizardPersist';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';

/**
 * P1 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Migration "seedTaskIds end state") — covers the legacy template
 * editor's rewired write-through in `persistRecurringTemplate`:
 *
 *   - CREATE mints a Pool named "<template name> pool" + writes
 *     `poolIds: [pool.id]`.
 *   - EDIT of a legacy-shaped record (exactly one pool, no manual
 *     additions, no removals) writes straight through to the linked
 *     Pool's `taskIds`.
 *   - EDIT of a non-legacy-shaped record (defensive — cannot occur
 *     before P4 ships, but handled anyway) flattens the selection to
 *     `manualTaskIds` and clears `poolIds`/`removedTaskIds`, never
 *     touching a Pool it didn't mint.
 *
 * `persistRecurringTemplate` only reads a handful of `BoardWizardController`
 * fields (`name`, `centerType`, `centerCustomName`, `selectedTaskIds`,
 * `editingTemplateId`, `timeframe`, `size`, `isRandomized`,
 * `targetWindowDate`, `weekStartDay`) — `useBoardWizard` itself is a hook
 * with no DOM harness in this repo (see `wizardTimeframeSeed.test.ts`), so
 * a minimal controller-shaped object is built directly rather than
 * rendering the hook.
 */

const NOW = '2026-07-19T00:00:00.000Z';

// A 3×3 FREE-center board needs 8 fillable cells.
const POOL_SIZE = 8;

function makeController(overrides: Partial<BoardWizardController> = {}): BoardWizardController {
  return {
    name: 'Daily Workout',
    size: 3,
    timeframe: Timeframe.DAILY,
    customStartDate: '',
    customEndDate: '',
    centerType: CenterSquareType.FREE,
    centerCustomName: '',
    isRandomized: true,
    weekStartDay: 'monday',
    isRecurring: true,
    selectedTaskIds: new Set<string>(),
    centerTaskId: null,
    pendingTasks: new Map(),
    currentStep: 1,
    draftBoardId: null,
    editingTemplateId: null,
    isCore: false,
    targetWindowDate: null,
    ...overrides,
  } as unknown as BoardWizardController;
}

async function seedTasks(n: number, prefix = 'task'): Promise<string[]> {
  const ids: string[] = [];
  for (let i = 0; i < n; i += 1) {
    const id = `${prefix}-${i}`;
    const task: Task = {
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
    };
    await db.tasks.add(task);
    ids.push(id);
  }
  return ids;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.pools.clear();
  await db.recurringBoardTemplates.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('persistRecurringTemplate — P1 legacy write-through', () => {
  it('CREATE mints a Pool named "<template name> pool" and writes poolIds/manualTaskIds/removedTaskIds', async () => {
    const taskIds = await seedTasks(POOL_SIZE);
    const controller = makeController({
      name: 'Daily Workout',
      selectedTaskIds: new Set(taskIds),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });

    const pools = await db.pools.toArray();
    expect(pools).toHaveLength(1);
    expect(pools[0].name).toBe('Daily Workout pool');
    expect(new Set(pools[0].taskIds)).toEqual(new Set(taskIds));

    const template = await db.recurringBoardTemplates.get(result.templateId);
    expect(template?.poolIds).toEqual([pools[0].id]);
    expect(template?.manualTaskIds).toEqual([]);
    expect(template?.removedTaskIds).toEqual([]);
    expect(new Set(template?.seedTaskIds)).toEqual(new Set(taskIds));

    // Bonus: the immediate spawn also resolves through the minted pool
    // (mix formula), matching the pre-P1 seedTaskIds-based spawn output.
    expect(result.spawnedBoardId).not.toBeNull();
  });

  it('EDIT of a legacy-shaped record (exactly one pool, no manual/removed) writes straight through to the linked Pool', async () => {
    const originalTaskIds = await seedTasks(POOL_SIZE);
    const pool: Pool = {
      id: 'pool-1',
      userId: 'user-1',
      name: 'Daily Workout pool',
      taskIds: originalTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.add(pool);
    const template: RecurringBoardTemplate = {
      id: 'tmpl-1',
      userId: 'user-1',
      name: 'Daily Workout',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
      isRandomized: true,
      seedTaskIds: originalTaskIds,
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: [],
      lastSpawnedWindowKey: '2026-07-18T00:00:00.000Z',
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 2,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    // The user removed one task and added a new one in the wizard.
    const extraTaskIds = await seedTasks(1, 'extra');
    const editedSelection = [...originalTaskIds.slice(1), ...extraTaskIds];

    const controller = makeController({
      name: 'Daily Workout',
      editingTemplateId: 'tmpl-1',
      selectedTaskIds: new Set(editedSelection),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });
    expect(result.templateId).toBe('tmpl-1');
    expect(result.spawnedBoardId).toBeNull(); // edits never spawn

    // The linked Pool now carries the edited selection.
    const updatedPool = await db.pools.get('pool-1');
    expect(new Set(updatedPool?.taskIds)).toEqual(new Set(editedSelection));

    // The template's own poolIds/manualTaskIds/removedTaskIds are
    // untouched — the Pool is the source of truth for a legacy-shaped
    // record's mix.
    const updatedTemplate = await db.recurringBoardTemplates.get('tmpl-1');
    expect(updatedTemplate?.poolIds).toEqual(['pool-1']);
    expect(updatedTemplate?.manualTaskIds).toEqual([]);
    expect(updatedTemplate?.removedTaskIds).toEqual([]);
    // seedTaskIds left verbatim/stale — never read after P1.
    expect(updatedTemplate?.seedTaskIds).toEqual(originalTaskIds);
  });

  it('EDIT of a non-legacy-shaped record (2 pools) flattens to manualTaskIds and clears poolIds/removedTaskIds — never writes a Pool it did not mint', async () => {
    const poolATaskIds = await seedTasks(4, 'poolA');
    const poolBTaskIds = await seedTasks(4, 'poolB');
    const poolA: Pool = {
      id: 'pool-a',
      userId: 'user-1',
      name: 'Pool A',
      taskIds: poolATaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    const poolB: Pool = {
      id: 'pool-b',
      userId: 'user-1',
      name: 'Pool B',
      taskIds: poolBTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.bulkAdd([poolA, poolB]);
    const template: RecurringBoardTemplate = {
      id: 'tmpl-rich',
      userId: 'user-1',
      name: 'Two-Pool Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
      isRandomized: true,
      seedTaskIds: [...poolATaskIds, ...poolBTaskIds],
      // 2 pools ⇒ NOT legacy-shaped per isLegacyShapedRecord.
      poolIds: ['pool-a', 'pool-b'],
      manualTaskIds: [],
      removedTaskIds: [],
      lastSpawnedWindowKey: '2026-07-18T00:00:00.000Z',
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 2,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    const editedSelection = [...poolATaskIds, ...poolBTaskIds.slice(0, 2)];
    const controller = makeController({
      name: 'Two-Pool Board',
      editingTemplateId: 'tmpl-rich',
      selectedTaskIds: new Set(editedSelection),
    });

    await persistRecurringTemplate({ controller, userId: 'user-1' });

    // Neither pool was touched.
    const storedPoolA = await db.pools.get('pool-a');
    const storedPoolB = await db.pools.get('pool-b');
    expect(storedPoolA?.taskIds).toEqual(poolATaskIds);
    expect(storedPoolB?.taskIds).toEqual(poolBTaskIds);
    expect(storedPoolA?.version).toBe(1);
    expect(storedPoolB?.version).toBe(1);

    // The template flattened to manualTaskIds and cleared poolIds/removedTaskIds.
    const updatedTemplate = await db.recurringBoardTemplates.get('tmpl-rich');
    expect(new Set(updatedTemplate?.manualTaskIds)).toEqual(new Set(editedSelection));
    expect(updatedTemplate?.poolIds).toEqual([]);
    expect(updatedTemplate?.removedTaskIds).toEqual([]);
  });
});
