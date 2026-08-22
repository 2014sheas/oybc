import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  Timeframe,
  TaskType,
  resolveMix,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../../db/internal';
import { emptyPatch, type ChildPatch, type TaskEditPatch } from '../../../db/taskEditPatch';
import { decodeRecurringDraftMix } from '../../../db/recurringDraftMix';
import { buildWizardPlacement, persistRecurringTemplate, persistWizardBoard } from '../wizardPersist';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';
import type { PendingTaskPayload } from '../../../pages/createPage/useCreateFormState';
import type { TaskLibrary } from '../../../pages/createPage/useTaskLibrary';
import {
  applyManualBookkeepingOnSelect,
} from '../../../pages/createHub/poolPullLogic';

/**
 * P4 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md §P4)
 * rewrote `persistRecurringTemplate` to unify the recurring-template
 * persist path with the one-off `persistWizardBoard`/`persistWizardBoardRows`
 * path. Two things changed from the P1/P3 behavior the old version of this
 * file covered:
 *
 * 1. **The bug fix**: pending (in-memory, wizard-inline-created) tasks are
 *    now drained via `persistWizardPendingTasks` for the FULL
 *    `controller.selectedTaskIds` before anything else runs. Previously
 *    this path read `controller.selectedTaskIds` straight into a
 *    Pool/template without ever writing the underlying Task row for a
 *    pending task, so `resolveMix`'s resolvable-id filter silently and
 *    permanently dropped it from the mix.
 * 2. **The P1 legacy write-through retires**: `controller.pulledPoolIds` /
 *    `manualTaskIds` / `removedTaskIds` (P3's "PULL IN A POOL" session
 *    state) are now the ONLY shape this path writes — no more minting a
 *    Pool on create, no more shape-scoped write-through-to-the-linked-Pool
 *    on edit. `useBoardWizard` itself is a hook with no DOM harness in
 *    this repo (see `wizardTimeframeSeed.test.ts`), so a minimal
 *    controller-shaped object is built directly rather than rendering the
 *    hook — same convention as this file used pre-P4.
 */

const NOW = '2026-07-19T00:00:00.000Z';

// A 3×3 FREE-center board needs 8 fillable cells (`fillableCellCount`).
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
  };
}

async function seedTasks(n: number, prefix = 'task'): Promise<string[]> {
  const ids: string[] = [];
  for (let i = 0; i < n; i += 1) {
    const id = `${prefix}-${i}`;
    await db.tasks.add(makeTask(id));
    ids.push(id);
  }
  return ids;
}

function makePool(id: string, name: string, taskIds: string[]): Pool {
  return {
    id,
    userId: 'user-1',
    name,
    taskIds,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

function makeTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'tmpl-1',
    userId: 'user-1',
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: [],
    poolIds: [],
    manualTaskIds: [],
    removedTaskIds: [],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
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

describe('persistRecurringTemplate — P4 native shape (no legacy write-through)', () => {
  it('CREATE writes poolIds/manualTaskIds/removedTaskIds straight from controller state — no Pool is minted', async () => {
    const poolTaskIds = await seedTasks(6, 'pool');
    const pool = makePool('pool-existing', 'Morning Kickstart', poolTaskIds);
    await db.pools.add(pool);
    const manualTaskIds = await seedTasks(2, 'manual');

    const selectedTaskIds = new Set([...poolTaskIds, ...manualTaskIds]);
    const controller = makeController({
      name: 'Daily Workout',
      selectedTaskIds,
      pulledPoolIds: ['pool-existing'],
      manualTaskIds: new Set(manualTaskIds),
      removedTaskIds: new Set(),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });

    // No Pool minted — the pre-existing pool is the only one in the DB.
    const pools = await db.pools.toArray();
    expect(pools).toHaveLength(1);
    expect(pools[0].id).toBe('pool-existing');
    expect(pools[0].taskIds).toEqual(poolTaskIds); // untouched

    const template = await db.recurringBoardTemplates.get(result.templateId);
    expect(template?.poolIds).toEqual(['pool-existing']);
    expect(new Set(template?.manualTaskIds)).toEqual(new Set(manualTaskIds));
    expect(template?.removedTaskIds).toEqual([]);
    // Decode-compat snapshot only.
    expect(new Set(template?.seedTaskIds)).toEqual(selectedTaskIds);

    expect(result.spawnedBoardId).not.toBeNull();
  });

  it('EDIT writes the native fields directly and never mutates a linked Pool\'s own taskIds', async () => {
    const poolTaskIds = await seedTasks(POOL_SIZE, 'pool');
    const pool = makePool('pool-1', 'Daily Workout pool', poolTaskIds);
    await db.pools.add(pool);
    const template = makeTemplate({
      id: 'tmpl-1',
      poolIds: ['pool-1'],
      manualTaskIds: [],
      removedTaskIds: [],
    });
    await db.recurringBoardTemplates.add(template);

    // The user removes one pool-sourced task and hand-adds a new one —
    // exactly the session state `useBoardWizard` would produce.
    const [newManualId] = await seedTasks(1, 'extra');
    const removedId = poolTaskIds[0];
    const selectedTaskIds = new Set([...poolTaskIds.slice(1), newManualId]);

    const controller = makeController({
      editingTemplateId: 'tmpl-1',
      selectedTaskIds,
      pulledPoolIds: ['pool-1'],
      manualTaskIds: new Set([newManualId]),
      removedTaskIds: new Set([removedId]),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });
    expect(result.templateId).toBe('tmpl-1');
    expect(result.spawnedBoardId).toBeNull(); // edits never spawn

    // The linked Pool's OWN taskIds are untouched — P1's write-through is
    // retired; the template's own poolIds/manualTaskIds/removedTaskIds are
    // now the source of truth.
    const storedPool = await db.pools.get('pool-1');
    expect(storedPool?.taskIds).toEqual(poolTaskIds);
    expect(storedPool?.version).toBe(1);

    const updatedTemplate = await db.recurringBoardTemplates.get('tmpl-1');
    expect(updatedTemplate?.poolIds).toEqual(['pool-1']);
    expect(updatedTemplate?.manualTaskIds).toEqual([newManualId]);
    expect(updatedTemplate?.removedTaskIds).toEqual([removedId]);
    // seedTaskIds left verbatim/stale — never read after P1.
    expect(updatedTemplate?.seedTaskIds).toEqual([]);
  });

  it('editing a template with 2 pools + manual tasks preserves the multi-pool shape (not flattened, not pool-mutated)', async () => {
    // §4 required test — the `?editTemplate=` re-point round-trip: a
    // native multi-pool/manual record must stay editable without
    // collapsing to a single flattened list.
    const poolATaskIds = await seedTasks(4, 'poolA');
    const poolBTaskIds = await seedTasks(4, 'poolB');
    const poolA = makePool('pool-a', 'Pool A', poolATaskIds);
    const poolB = makePool('pool-b', 'Pool B', poolBTaskIds);
    await db.pools.bulkAdd([poolA, poolB]);
    const [originalManualId] = await seedTasks(1, 'manual');
    const template = makeTemplate({
      id: 'tmpl-multi',
      name: 'Two-Pool Board',
      poolIds: ['pool-a', 'pool-b'],
      manualTaskIds: [originalManualId],
      removedTaskIds: [],
    });
    await db.recurringBoardTemplates.add(template);

    // Hydration on wizard-open, exactly as `useBoardWizard`'s
    // `useTemplateMix` resolves it: real `resolveMix` against the real
    // pools/tasks, not a hand-rolled union.
    const poolsById: Record<string, Pool> = { 'pool-a': poolA, 'pool-b': poolB };
    const allTaskIds = [...poolATaskIds, ...poolBTaskIds, originalManualId];
    const tasksById: Record<string, Task> = {};
    for (const id of allTaskIds) tasksById[id] = makeTask(id);
    let selectedTaskIds = new Set(resolveMix(template, poolsById, tasksById).taskIds);
    expect(selectedTaskIds.size).toBe(9); // 4 + 4 + 1 manual

    // "Make a small edit": hand-add one more manual task via the REAL
    // select-side bookkeeping function `toggleTaskSelection` delegates to.
    const [newManualId] = await seedTasks(1, 'newmanual');
    selectedTaskIds = new Set(selectedTaskIds);
    selectedTaskIds.add(newManualId);
    let manualTaskIds = new Set([originalManualId]);
    let removedTaskIds = new Set<string>();
    const bookkeeping = applyManualBookkeepingOnSelect(newManualId, manualTaskIds, removedTaskIds);
    manualTaskIds = bookkeeping.manualTaskIds;
    removedTaskIds = bookkeeping.removedTaskIds;

    const controller = makeController({
      name: 'Two-Pool Board',
      editingTemplateId: 'tmpl-multi',
      selectedTaskIds,
      pulledPoolIds: ['pool-a', 'pool-b'],
      manualTaskIds,
      removedTaskIds,
    });

    await persistRecurringTemplate({ controller, userId: 'user-1' });

    // Neither pool was touched — never flattened, never pool-mutated.
    const storedPoolA = await db.pools.get('pool-a');
    const storedPoolB = await db.pools.get('pool-b');
    expect(storedPoolA?.taskIds).toEqual(poolATaskIds);
    expect(storedPoolB?.taskIds).toEqual(poolBTaskIds);
    expect(storedPoolA?.version).toBe(1);
    expect(storedPoolB?.version).toBe(1);

    const updatedTemplate = await db.recurringBoardTemplates.get('tmpl-multi');
    // Still a native 2-pool shape — not flattened to a single manual list.
    expect(updatedTemplate?.poolIds).toHaveLength(2);
    expect(new Set(updatedTemplate?.poolIds)).toEqual(new Set(['pool-a', 'pool-b']));
    expect(new Set(updatedTemplate?.manualTaskIds)).toEqual(
      new Set([originalManualId, newManualId]),
    );
    expect(updatedTemplate?.removedTaskIds).toEqual([]);
  });
});

describe('persistRecurringTemplate — P4 pending-task drain (the bug this phase fixes)', () => {
  /**
   * Regression test A. Before the fix, this path read
   * `controller.selectedTaskIds` straight into the persisted record
   * without ever writing the underlying Task row for a pending
   * (wizard-inline-"New Task"-created) task. `resolveMix` /
   * `resolvablePoolSupply` filter a mix down to ids that actually resolve
   * in `tasksById` — so the pending task was silently and PERMANENTLY
   * dropped from every future spawn. If the drop takes the mix below the
   * fillable floor, the window skips forever with `pool_too_small`
   * (`spawnedBoardId` stays null).
   *
   * Drives the exact sequence the wizard's real actions produce
   * (`toggleTaskSelection` + `addPendingTask` for an inline "New Task"),
   * without rendering `useBoardWizard` itself (no DOM harness in this
   * repo — see this file's top docstring), then calls
   * `persistRecurringTemplate` exactly as `BoardWizardPreviewStep`'s
   * `performCreation` does (no explicit `pendingTasks` arg — falls back to
   * `controller.pendingTasks`).
   */
  it('a pending (not-yet-persisted) task in the selection is written to the DB and reaches the spawned board', async () => {
    // One short of the 3×3 FREE-center floor (8) with real library tasks.
    const libraryTaskIds = await seedTasks(POOL_SIZE - 1);

    // Simulate the wizard's inline "New Task" sheet: `toggleTaskSelection`
    // adds the id to the selection + `manualTaskIds`; `addPendingTask`
    // stores the in-memory payload. Neither writes to `db.tasks`.
    const pendingTaskId = 'pending-task-1';
    const pendingPayload: PendingTaskPayload = {
      task: makeTask(pendingTaskId, { title: 'Just typed this' }),
      childTasks: [],
      childLinks: [],
    };
    const selectedTaskIds = new Set([...libraryTaskIds, pendingTaskId]);
    expect(selectedTaskIds.size).toBe(POOL_SIZE); // reaches the floor exactly

    const controller = makeController({
      selectedTaskIds,
      manualTaskIds: new Set(selectedTaskIds), // every ordinary select populates this
      pendingTasks: new Map([[pendingTaskId, pendingPayload]]),
    });

    // No `pendingTasks` arg — reproduces the Preview step's call site.
    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });

    // (a) The pending task now exists as a real row.
    const persistedTask = await db.tasks.get(pendingTaskId);
    expect(persistedTask).toBeDefined();
    expect(persistedTask?.title).toBe('Just typed this');

    // (b) The spawn succeeded — the mix reached the floor.
    expect(result.spawnedBoardId).not.toBeNull();
    const boardId = result.spawnedBoardId as string;

    // (c) The spawned board is filled to exactly the fillable-floor count
    // (all 8 mix tasks — no missing cells) and includes a cell for the
    // pending task's id specifically.
    const boardTasks = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(boardTasks).toHaveLength(POOL_SIZE);
    expect(boardTasks.some((bt) => bt.taskId === pendingTaskId)).toBe(true);
  });
});

describe('persistRecurringTemplate — P4 regression (finishing a repeating wizard never saves a plain draft Board)', () => {
  /**
   * Regression test B. `BoardWizardPage.handleDialogSaveDraft` used to
   * call the one-off `persistWizardBoard` UNCONDITIONALLY, ignoring
   * `wizard.isRecurring` entirely — so backing out of a recurring-board-
   * in-progress via the cancel dialog's "Save Draft" silently saved a
   * plain one-off draft Board instead of a recurring spawn record. The
   * fix branches on `wizard.isRecurring` and calls `persistRecurringTemplate`
   * (this file's function) with the exact same argument shape
   * (`{ controller, userId, pendingTasks: wizard.pendingTasks }`) the
   * cancel dialog now uses.
   *
   * This repo has no DOM/component-rendering harness (see this file's top
   * docstring), so the cancel-dialog's button-click plumbing itself isn't
   * exercised here — that's a two-line, directly-reviewable
   * `if (wizard.isRecurring)` branch in `BoardWizardPage.tsx`. What IS
   * exercised, end-to-end, twice (matching both call sites verbatim) is
   * the actual persisted OUTCOME: a `recurringBoardTemplates` row, never a
   * `boards` row with `status: 'draft'`.
   */
  it('the Preview step\'s direct call produces a RecurringBoardTemplate + an ACTIVE spawned board, never a draft Board', async () => {
    const taskIds = await seedTasks(POOL_SIZE);
    const controller = makeController({
      selectedTaskIds: new Set(taskIds),
      manualTaskIds: new Set(taskIds),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });

    const templates = await db.recurringBoardTemplates.toArray();
    expect(templates).toHaveLength(1);

    const boards = await db.boards.toArray();
    expect(boards).toHaveLength(1); // only the spawned board — no draft
    expect(boards[0].id).toBe(result.spawnedBoardId);
    expect(boards[0].status).not.toBe('draft');
    expect(boards[0].spawnedFromTemplateId).toBe(templates[0].id);
  });

  it('the cancel dialog\'s equivalent call (explicit pendingTasks arg) produces the same outcome', async () => {
    const taskIds = await seedTasks(POOL_SIZE);
    const controller = makeController({
      selectedTaskIds: new Set(taskIds),
      manualTaskIds: new Set(taskIds),
    });

    // Mirrors `BoardWizardPage.handleDialogSaveDraft`'s exact call:
    // `persistRecurringTemplate({ controller: wizard, userId, pendingTasks: wizard.pendingTasks })`.
    const result = await persistRecurringTemplate({
      controller,
      userId: 'user-1',
      pendingTasks: controller.pendingTasks,
    });

    const templates = await db.recurringBoardTemplates.toArray();
    expect(templates).toHaveLength(1);

    const boards = await db.boards.toArray();
    expect(boards).toHaveLength(1);
    expect(boards[0].id).toBe(result.spawnedBoardId);
    expect(boards[0].status).not.toBe('draft');
    expect(boards[0].spawnedFromTemplateId).toBe(templates[0].id);
  });
});

/**
 * Inline Task Editing (web PR-2) — staged edits threaded through the
 * wizard-level persist entry points. `wizardBoard.test.ts` already covers
 * the transaction-layer apply in isolation; these tests confirm the
 * `wizardPersist.ts` glue (the pending-edit pre-merge + the active/draft
 * gate + the recurring-template call site) wires it correctly end to end —
 * this is the exact seam where the analogous iOS bugs (dropped
 * `stagedEdits`, dropped pending tasks) hid.
 */
function emptyTaskLibrary(allTasks: Task[] = []): TaskLibrary {
  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;
  return {
    allTasks,
    allCompoundChildren: [],
    taskMap,
    compoundChildrenByCompound: {},
    childTaskIds: new Set(),
    childToParents: {},
  };
}

function simpleChild(over: Partial<ChildPatch>): ChildPatch {
  return { id: 'x', childTaskId: null, title: '', isCounting: false, action: '', goal: '', unit: '', markedDeleted: false, ...over };
}

describe('buildWizardPlacement — staged-edit overlay (Inline Task Editing PR-2)', () => {
  it('overlays a staged rename onto the Step-3 preview without touching the DB', async () => {
    const task = makeTask('t1', { title: 'Old title' });
    await db.tasks.add(task);
    const stagedEdits = new Map<string, TaskEditPatch>([['t1', emptyPatch('New title')]]);
    const controller = makeController({
      selectedTaskIds: new Set(['t1']),
      stagedEdits,
    } as Partial<BoardWizardController>);

    const placement = buildWizardPlacement(controller, emptyTaskLibrary([task]));
    const placed = placement.find((t) => t?.id === 't1');
    expect(placed?.title).toBe('New title');

    // The DB itself is untouched — only the preview is overlaid.
    const stored = await db.tasks.get('t1');
    expect(stored?.title).toBe('Old title');
  });
});

describe('persistWizardBoard — staged edits (Inline Task Editing PR-2)', () => {
  it('applies a staged edit to a LIBRARY task on an ACTIVE create, but not on a DRAFT save', async () => {
    const task = makeTask('lib-1', { title: 'Old title' });
    await db.tasks.add(task);
    const controller = makeController({
      selectedTaskIds: new Set(['lib-1']),
      isRecurring: false,
      stagedEdits: new Map<string, TaskEditPatch>([['lib-1', emptyPatch('New title')]]),
    } as Partial<BoardWizardController>);

    await persistWizardBoard({
      controller,
      library: emptyTaskLibrary([task]),
      userId: 'user-1',
      placement: buildWizardPlacement(controller, emptyTaskLibrary([task])),
      dates: { startDate: NOW },
      status: 'draft',
    });
    expect((await db.tasks.get('lib-1'))?.title).toBe('Old title'); // draft: untouched

    await persistWizardBoard({
      controller,
      library: emptyTaskLibrary([task]),
      userId: 'user-1',
      placement: buildWizardPlacement(controller, emptyTaskLibrary([task])),
      dates: { startDate: NOW },
      status: 'active',
    });
    expect((await db.tasks.get('lib-1'))?.title).toBe('New title'); // active: applied
  });

  it('merges a staged edit into a PENDING task\'s payload before it is ever written, so the row lands with the edited values in one shot', async () => {
    const pendingTask = makeTask('pending-1', { title: 'Original pending title' });
    const controller = makeController({
      selectedTaskIds: new Set(['pending-1']),
      isRecurring: false,
      pendingTasks: new Map<string, PendingTaskPayload>([
        ['pending-1', { task: pendingTask, childTasks: [], childLinks: [] }],
      ]),
      stagedEdits: new Map<string, TaskEditPatch>([['pending-1', emptyPatch('Edited before it ever existed')]]),
    } as Partial<BoardWizardController>);

    const library = emptyTaskLibrary([]);
    await persistWizardBoard({
      controller,
      library,
      userId: 'user-1',
      placement: buildWizardPlacement(controller, library),
      dates: { startDate: NOW },
      status: 'active',
    });

    const written = await db.tasks.get('pending-1');
    expect(written?.title).toBe('Edited before it ever existed');
    expect(written?.version).toBe(1); // written once, already carrying the edit — no separate re-save/version bump.
  });
});

describe('persistRecurringTemplate — staged edits (Inline Task Editing PR-2)', () => {
  it('a PENDING compound with an inline sub-task, plus a staged edit adding a second inline sub-task, persists correctly through the recurring path', async () => {
    const libraryTaskIds = await seedTasks(POOL_SIZE - 1);
    const compoundId = 'pending-compound-1';
    const originalChildId = 'pending-compound-1-child-a';

    const originalChild = makeTask(originalChildId, { title: 'Warm up' });
    const compoundTask: Task = {
      ...makeTask(compoundId, { title: 'Morning routine' }),
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
    };
    const originalLink = {
      id: 'link-1',
      compoundTaskId: compoundId,
      childTaskId: originalChildId,
      childIndex: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };

    const selectedTaskIds = new Set([...libraryTaskIds, compoundId]);
    const controller = makeController({
      selectedTaskIds,
      manualTaskIds: new Set([...libraryTaskIds, compoundId]),
      pendingTasks: new Map<string, PendingTaskPayload>([
        [compoundId, { task: compoundTask, childTasks: [originalChild], childLinks: [originalLink] }],
      ]),
      stagedEdits: new Map<string, TaskEditPatch>([
        [
          compoundId,
          {
            ...emptyPatch('Morning routine v2'),
            operator: OperatorType.AND,
            children: [
              simpleChild({ id: originalChildId, childTaskId: originalChildId, title: 'Warm up' }),
              simpleChild({ id: 'new-child-draft', childTaskId: null, title: 'Cool down' }),
            ],
          },
        ],
      ]),
    } as Partial<BoardWizardController>);

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });
    expect(result.spawnedBoardId).not.toBeNull();

    const savedCompound = await db.tasks.get(compoundId);
    expect(savedCompound?.title).toBe('Morning routine v2');

    const links = (await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()).filter(
      (l) => !l.isDeleted,
    );
    expect(links).toHaveLength(2);
    const newChildId = links.find((l) => l.childTaskId !== originalChildId)?.childTaskId;
    expect(newChildId).toBeTruthy();
    const newChildTask = newChildId ? await db.tasks.get(newChildId) : undefined;
    expect(newChildTask?.title).toBe('Cool down');
  });
});

/**
 * Board Creation Split (web PR D) — recurring drafts. `persistWizardBoard`
 * (the SAME one-off draft-save path) is now also the recurring wizard's
 * "Save as Draft" / cancel-dialog "Save Draft" writer: it stamps
 * `isRecurringDraft` + a JSON `recurringDraftMix` snapshot instead of
 * spawning a `RecurringBoardTemplate` immediately. "Create Board" on a
 * resumed recurring draft then converts it: `persistRecurringTemplate`'s
 * fresh-create path creates the real template (+ spawn) and retires
 * (soft-deletes) the placeholder draft Board.
 */
describe('Board Creation Split (web PR D) — recurring draft save writes isRecurringDraft + recurringDraftMix', () => {
  it('a recurring "Save as Draft" writes isRecurringDraft=true and a mix snapshot; a one-off draft never sets the mix field', async () => {
    const poolTaskIds = await seedTasks(3, 'pool');
    await db.pools.add(makePool('pool-1', 'Morning Kickstart', poolTaskIds));
    const [manualId] = await seedTasks(1, 'manual');

    const recurringController = makeController({
      isRecurring: true,
      selectedTaskIds: new Set([...poolTaskIds, manualId]),
      pulledPoolIds: ['pool-1'],
      manualTaskIds: new Set([manualId]),
      removedTaskIds: new Set(),
    });

    const boardId = await persistWizardBoard({
      controller: recurringController,
      library: emptyTaskLibrary(),
      userId: 'user-1',
      placement: buildWizardPlacement(recurringController, emptyTaskLibrary()),
      dates: { startDate: NOW },
      status: 'draft',
    });

    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.DRAFT);
    expect(board?.isRecurringDraft).toBe(true);
    expect(board?.recurringDraftMix).toBeDefined();
    expect(decodeRecurringDraftMix(board?.recurringDraftMix)).toEqual({
      poolIds: ['pool-1'],
      manualTaskIds: [manualId],
      removedTaskIds: [],
    });

    // A one-off draft save (the pre-existing behavior) never sets the key
    // at all — decodes as an empty mix, matching a plain draft's
    // forward-compat shape.
    const oneOffController = makeController({
      isRecurring: false,
      selectedTaskIds: new Set(poolTaskIds),
      manualTaskIds: new Set(poolTaskIds),
    });
    const oneOffBoardId = await persistWizardBoard({
      controller: oneOffController,
      library: emptyTaskLibrary(),
      userId: 'user-1',
      placement: buildWizardPlacement(oneOffController, emptyTaskLibrary()),
      dates: { startDate: NOW },
      status: 'draft',
    });
    const oneOffBoard = await db.boards.get(oneOffBoardId);
    expect(oneOffBoard?.isRecurringDraft).toBe(false);
    expect(oneOffBoard?.recurringDraftMix).toBeUndefined();
  });

  it('re-saving a resumed recurring draft overwrites the mix with the CURRENT session state, never merging with the prior snapshot', async () => {
    const [oldManualId, newManualId] = await seedTasks(2, 'manual');
    const firstController = makeController({
      isRecurring: true,
      selectedTaskIds: new Set([oldManualId]),
      manualTaskIds: new Set([oldManualId]),
    });
    const boardId = await persistWizardBoard({
      controller: firstController,
      library: emptyTaskLibrary(),
      userId: 'user-1',
      placement: buildWizardPlacement(firstController, emptyTaskLibrary()),
      dates: { startDate: NOW },
      status: 'draft',
    });

    // Resume: the user drops the old manual task and adds a new one, then
    // saves again — same draftBoardId, fresh selection.
    const resumedController = makeController({
      isRecurring: true,
      draftBoardId: boardId,
      selectedTaskIds: new Set([newManualId]),
      manualTaskIds: new Set([newManualId]),
    });
    await persistWizardBoard({
      controller: resumedController,
      library: emptyTaskLibrary(),
      userId: 'user-1',
      placement: buildWizardPlacement(resumedController, emptyTaskLibrary()),
      dates: { startDate: NOW },
      status: 'draft',
    });

    const board = await db.boards.get(boardId);
    expect(decodeRecurringDraftMix(board?.recurringDraftMix).manualTaskIds).toEqual([newManualId]);
  });
});

describe('Board Creation Split (web PR D) — convert draft → template on Create Board', () => {
  it('a resumed recurring draft, once Created, produces a RecurringBoardTemplate + spawned board and retires (soft-deletes) the placeholder draft', async () => {
    const taskIds = await seedTasks(POOL_SIZE, 'task');

    // 1) Save as Draft — mirrors the recurring Preview step's "Save as
    //    Draft" / the cancel dialog's unified "Save Draft".
    const draftController = makeController({
      isRecurring: true,
      selectedTaskIds: new Set(taskIds),
      manualTaskIds: new Set(taskIds),
    });
    const draftBoardId = await persistWizardBoard({
      controller: draftController,
      library: emptyTaskLibrary(),
      userId: 'user-1',
      placement: buildWizardPlacement(draftController, emptyTaskLibrary()),
      dates: { startDate: NOW },
      status: 'draft',
    });
    const savedDraft = await db.boards.get(draftBoardId);
    expect(savedDraft?.status).toBe(BoardStatus.DRAFT);
    expect(savedDraft?.isDeleted).toBe(false);

    // 2) Resume: hydrate a fresh controller from the draft's decoded mix
    //    exactly as `useBoardWizard`'s recurring-draft-resume hydration
    //    would (poolIds/manualTaskIds/removedTaskIds straight off the
    //    decoded payload; draftBoardId carried forward).
    const decodedMix = decodeRecurringDraftMix(savedDraft?.recurringDraftMix);
    const resumedController = makeController({
      isRecurring: true,
      draftBoardId,
      selectedTaskIds: new Set(taskIds),
      pulledPoolIds: decodedMix.poolIds,
      manualTaskIds: new Set(decodedMix.manualTaskIds),
      removedTaskIds: new Set(decodedMix.removedTaskIds),
    });

    // 3) "Create Board" — the fresh-create path, since editingTemplateId
    //    is still null on a resumed DRAFT (mutually exclusive with
    //    editingTemplateId per the hydration-priority rule).
    const result = await persistRecurringTemplate({ controller: resumedController, userId: 'user-1' });
    expect(result.spawnedBoardId).not.toBeNull();

    const templates = await db.recurringBoardTemplates.toArray();
    expect(templates).toHaveLength(1);
    expect(new Set(templates[0].manualTaskIds)).toEqual(new Set(taskIds));

    // The placeholder draft is now tombstoned — it must not linger
    // alongside the board it just spawned.
    const retiredDraft = await db.boards.get(draftBoardId);
    expect(retiredDraft?.isDeleted).toBe(true);

    // The spawned board is a SEPARATE, non-deleted, ACTIVE row.
    const spawnedBoard = await db.boards.get(result.spawnedBoardId as string);
    expect(spawnedBoard?.id).not.toBe(draftBoardId);
    expect(spawnedBoard?.isDeleted).toBe(false);
    expect(spawnedBoard?.status).not.toBe(BoardStatus.DRAFT);
  });

  it('editing an EXISTING repeating board (editingTemplateId set) never retires any draft — there is none to retire', async () => {
    const taskIds = await seedTasks(POOL_SIZE, 'task');
    const template = makeTemplate({
      id: 'tmpl-edit-1',
      manualTaskIds: taskIds,
      poolIds: [],
      removedTaskIds: [],
    });
    await db.recurringBoardTemplates.add(template);

    const controller = makeController({
      editingTemplateId: 'tmpl-edit-1',
      draftBoardId: null,
      selectedTaskIds: new Set(taskIds),
      manualTaskIds: new Set(taskIds),
    });

    const result = await persistRecurringTemplate({ controller, userId: 'user-1' });
    expect(result.spawnedBoardId).toBeNull(); // edits never spawn

    // No board was created OR deleted by the edit path.
    const boards = await db.boards.toArray();
    expect(boards).toHaveLength(0);
  });
});
