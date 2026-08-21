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
import {
  applyManualBookkeepingOnSelect,
  applyPullPool,
  applyUntogglePool,
} from '../../../pages/createHub/poolPullLogic';

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
 * P3 (same doc, §Surfaces item 5 "Wizard step 2") added the "PULL IN A
 * POOL" wizard-session UI (`pulledPoolIds`/`manualTaskIds`/
 * `removedTaskIds` on `BoardWizardController`, driven by
 * `poolPullLogic.ts`'s pure functions). That UI/session layer is
 * unaffected by `persistRecurringTemplate`, which — per this revert —
 * only ever reads the flattened `controller.selectedTaskIds`, exactly as
 * in P1. The two regression tests below ("P3 regression") exist because
 * an earlier version of this branch mistakenly made
 * `persistRecurringTemplate` consult `pulledPoolIds`/`manualTaskIds`/
 * `removedTaskIds` directly, which (a) broke the legacy write-through the
 * moment a user added a single ordinary task during an edit, since
 * `manualTaskIds` is populated by every ordinary select, not just pool
 * pulls, and (b) could write a live-but-untoggled pool's tasks into the
 * WRONG (stale, template-linked) pool. Both tests drive the real
 * `toggleTaskSelection`-equivalent pure functions rather than hand-setting
 * controller state, so they actually exercise the bug's trigger path.
 *
 * `persistRecurringTemplate` only reads a handful of `BoardWizardController`
 * fields (`name`, `centerType`, `selectedTaskIds`,
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
    isRandomized: true,
    weekStartDay: 'monday',
    isRecurring: true,
    selectedTaskIds: new Set<string>(),
    centerTaskId: null,
    // P3 (Task Pools + Recurring Boards Rework) added these fields to
    // `BoardWizardController` for the "PULL IN A POOL" session UI.
    // `persistRecurringTemplate` does not read them (see this file's
    // top docstring); default to "untouched" so the type is satisfied.
    pulledPoolIds: [],
    manualTaskIds: new Set<string>(),
    removedTaskIds: new Set<string>(),
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

describe('persistRecurringTemplate — P3 regression (pool-pull session state must not drive persistence)', () => {
  /**
   * Critical-1 regression. A shipped version of this branch evaluated the
   * legacy-shape gate against `controller.pulledPoolIds`/`manualTaskIds`/
   * `removedTaskIds` instead of the fetched template's own persisted
   * shape. Since `applyManualBookkeepingOnSelect` (the exact function
   * `toggleTaskSelection` delegates to for every ordinary row select, not
   * just pool-pull actions) unconditionally adds the toggled id to
   * `manualTaskIds`, editing a legacy single-pool template and simply
   * adding ONE ordinary task flipped the wizard-shape gate to
   * non-legacy — silently switching the edit from "write through to the
   * shared Pool" to "write a native poolIds/manualTaskIds/removedTaskIds
   * shape onto the template", which P1/P3 spec forbids before P4.
   *
   * This test drives the exact sequence `useBoardWizard.toggleTaskSelection`
   * runs (see `useBoardWizard.ts` lines ~630-676): hydrate the edit session
   * the way it hydrates a legacy single-pool template (`pulledPoolIds:
   * [pool.id]`, empty manual/removed), then call the real
   * `applyManualBookkeepingOnSelect` pure function — never hand-set
   * `manualTaskIds` directly — to add one ordinary task. The fix must keep
   * writing through to the linked Pool.
   */
  it('editing a legacy single-pool template and adding one ordinary task still writes through to the Pool, not a native shape', async () => {
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

    // Hydration on wizard-open (as `useBoardWizard` does for an edit
    // session): the template's one linked pool is pulled in, nothing
    // manual/removed yet.
    let selectedTaskIds = new Set(originalTaskIds);
    let manualTaskIds = new Set<string>();
    let removedTaskIds = new Set<string>();
    const pulledPoolIds = ['pool-1'];

    // The user adds ONE ordinary task via `toggleTaskSelection`'s real
    // select-side path — not a pool-pull action.
    const [extraTaskId] = await seedTasks(1, 'extra');
    const wasSelected = selectedTaskIds.has(extraTaskId); // false
    selectedTaskIds = new Set(selectedTaskIds);
    selectedTaskIds.add(extraTaskId);
    expect(wasSelected).toBe(false);
    const bookkeeping = applyManualBookkeepingOnSelect(
      extraTaskId,
      manualTaskIds,
      removedTaskIds,
    );
    manualTaskIds = bookkeeping.manualTaskIds;
    removedTaskIds = bookkeeping.removedTaskIds;

    // Confirms the trigger condition: an ordinary select DOES populate
    // manualTaskIds (this is what made the old wizard-shape gate flip).
    expect(manualTaskIds.has(extraTaskId)).toBe(true);

    const controller = makeController({
      name: 'Daily Workout',
      editingTemplateId: 'tmpl-1',
      selectedTaskIds,
      pulledPoolIds,
      manualTaskIds,
      removedTaskIds,
    });

    await persistRecurringTemplate({ controller, userId: 'user-1' });

    // Still writes through to the linked Pool — no native shape leaked
    // onto the template.
    const updatedPool = await db.pools.get('pool-1');
    expect(new Set(updatedPool?.taskIds)).toEqual(new Set(selectedTaskIds));

    const updatedTemplate = await db.recurringBoardTemplates.get('tmpl-1');
    expect(updatedTemplate?.poolIds).toEqual(['pool-1']);
    expect(updatedTemplate?.manualTaskIds).toEqual([]);
    expect(updatedTemplate?.removedTaskIds).toEqual([]);
  });

  /**
   * Critical-2 regression. A shipped version of this branch's fresh-create
   * native-write path (and the edit richer-shape path) read
   * `controller.pulledPoolIds` for the Pool lookup, while a defensive
   * write-through elsewhere read `existingTemplate.poolIds?.[0]` (a
   * DIFFERENT, stale pool reference) — a latent cross-pool corruption
   * risk if those two ever diverged. This test drives the real
   * pull/untoggle session sequence (`applyPullPool` then `applyUntogglePool`,
   * the exact functions `useBoardWizard`'s `pullPool`/`untogglePool`
   * delegate to) for a FRESH create, and asserts a completely unrelated,
   * never-pulled pool B is left untouched and no native pool-mix shape
   * leaks onto the template — only ONE freshly-minted pool exists,
   * exactly like the P1 legacy create path.
   */
  it('fresh CREATE after a pull+untoggle session mints exactly one pool and never touches an unrelated pool', async () => {
    const poolATaskIds = await seedTasks(POOL_SIZE, 'poolA');
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
    const poolBTaskIds = await seedTasks(4, 'poolB');
    const poolB: Pool = {
      id: 'pool-b',
      userId: 'user-1',
      name: 'Pool B (unrelated, never pulled)',
      taskIds: poolBTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.bulkAdd([poolA, poolB]);

    const poolsById: Record<string, Pool> = { 'pool-a': poolA, 'pool-b': poolB };
    const tasksById: Record<string, Task> = {};
    for (const id of [...poolATaskIds, ...poolBTaskIds]) {
      tasksById[id] = {
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
    }

    // Fresh-create session: pull pool A in, then untoggle it again, then
    // hand-pick tasks to fill the board.
    let selectedTaskIds = new Set<string>();
    let pulledPoolIds: string[] = [];
    let manualTaskIds = new Set<string>();
    let removedTaskIds = new Set<string>();

    const pulled = applyPullPool(
      'pool-a',
      selectedTaskIds,
      pulledPoolIds,
      removedTaskIds,
      poolsById,
      tasksById,
    );
    selectedTaskIds = pulled.selectedTaskIds;
    pulledPoolIds = pulled.pulledPoolIds;
    expect(pulledPoolIds).toEqual(['pool-a']);
    expect(selectedTaskIds.size).toBe(POOL_SIZE);

    const untoggled = applyUntogglePool(
      'pool-a',
      selectedTaskIds,
      pulledPoolIds,
      manualTaskIds,
      removedTaskIds,
      poolsById,
      tasksById,
    );
    selectedTaskIds = untoggled.selectedTaskIds;
    pulledPoolIds = untoggled.pulledPoolIds;
    removedTaskIds = untoggled.removedTaskIds;
    expect(pulledPoolIds).toEqual([]);
    expect(selectedTaskIds.size).toBe(0);

    // Hand-pick a fresh set of tasks (real select-side bookkeeping).
    const [handPicked] = await seedTasks(POOL_SIZE, 'hand');
    const handPickedIds = await seedTasks(POOL_SIZE - 1, 'hand2');
    const allHandPicked = [handPicked, ...handPickedIds];
    for (const id of allHandPicked) {
      selectedTaskIds = new Set(selectedTaskIds);
      selectedTaskIds.add(id);
      const bookkeeping = applyManualBookkeepingOnSelect(id, manualTaskIds, removedTaskIds);
      manualTaskIds = bookkeeping.manualTaskIds;
      removedTaskIds = bookkeeping.removedTaskIds;
    }
    expect(selectedTaskIds.size).toBe(POOL_SIZE);

    const controller = makeController({
      name: 'Fresh Recurring Board',
      selectedTaskIds,
      pulledPoolIds,
      manualTaskIds,
      removedTaskIds,
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });

    // Exactly ONE new pool minted from the final flattened selection.
    const pools = await db.pools.toArray();
    const mintedPools = pools.filter((p) => p.id !== 'pool-a' && p.id !== 'pool-b');
    expect(mintedPools).toHaveLength(1);
    expect(new Set(mintedPools[0].taskIds)).toEqual(new Set(allHandPicked));
    expect(mintedPools[0].name).toBe('Fresh Recurring Board pool');

    // Pool A (pulled then untoggled) and pool B (never touched) are both
    // completely unaffected.
    const storedPoolA = await db.pools.get('pool-a');
    const storedPoolB = await db.pools.get('pool-b');
    expect(storedPoolA?.taskIds).toEqual(poolATaskIds);
    expect(storedPoolA?.version).toBe(1);
    expect(storedPoolB?.taskIds).toEqual(poolBTaskIds);
    expect(storedPoolB?.version).toBe(1);

    // No native multi-pool shape leaks onto the template — legacy shape,
    // one minted pool, exactly like the P1 create path.
    const template = await db.recurringBoardTemplates.get(result.templateId);
    expect(template?.poolIds).toEqual([mintedPools[0].id]);
    expect(template?.manualTaskIds).toEqual([]);
    expect(template?.removedTaskIds).toEqual([]);

    expect(result.spawnedBoardId).not.toBeNull();
  });
});
