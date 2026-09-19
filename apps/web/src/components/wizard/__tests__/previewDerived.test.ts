import { describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  generateCounterTaskTitle,
  varyRange,
  type BoardSource,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { applyPreviewDerivedCells, makePreviewRng } from '../previewDerived';
import { buildWizardPlacement, type WizardPlacement } from '../wizardPersist';
import { algorithmSupplies, type SupplyInfoMap } from '../../../pages/createHub/wizardSources';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../../pages/createPage/useTaskLibrary';
import { db } from '../../../db/internal';

/**
 * §Member rules (B3, RC6) — the wizard Preview's DRY RUN.
 *
 * Since B2 the persist path replaces a counting member that carries a
 * target/vary rule with a window-stamped DERIVED counter whose `maxCount`
 * is the rolled target. These tests pin that the Preview shows the SAME
 * thing it is about to create:
 *
 * - the cell is a stand-in carrying the rolled target and the title that
 *   target generates — inside `varyRange`, never outside it — while keeping
 *   the original id the Save handler re-reads;
 * - the roll is seeded, so Shuffle (a new nonce) visibly re-rolls;
 * - nothing is written: the dry run is display-only and the real mint
 *   happens inside the board-create transaction;
 * - `buildWizardPlacement` WITHOUT `previewRules` is untouched — that is
 *   the persist path, which must not double-roll.
 */

const NOW = '2026-09-18T00:00:00.000Z';

const SOURCE_ID = 'board-1';

/** The source board: a weekly window. */
const WEEKLY_SOURCE = {
  timeframe: Timeframe.WEEKLY,
  startDate: '2026-09-14T00:00:00.000',
  endDate: '2026-09-20T23:59:59.999',
};

function makeTask(id: string, over: Partial<Task> = {}): Task {
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
    ...over,
  };
}

/** A counting task with a real action/unit, so the generated title is legible. */
function makeCounter(id: string, maxCount: number, over: Partial<Task> = {}): Task {
  return makeTask(id, {
    type: TaskType.COUNTING,
    title: `Run ${maxCount} miles`,
    action: 'Run',
    unit: 'miles',
    maxCount,
    currentCount: 0,
    ...over,
  });
}

function makeChild(parentId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id: `${parentId}-${childTaskId}`,
    compoundTaskId: parentId,
    childTaskId,
    childIndex,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

function makeLibrary(tasks: Task[], children: CompoundChild[] = []): TaskLibrary {
  const taskMap: Record<string, Task> = {};
  for (const t of tasks) taskMap[t.id] = t;
  const compoundChildrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of children) (compoundChildrenByCompound[c.compoundTaskId] ??= []).push(c);
  return {
    allTasks: tasks,
    allCompoundChildren: children,
    taskMap,
    compoundChildrenByCompound,
    childTaskIds: new Set(children.map((c) => c.childTaskId)),
    childToParents: {},
  };
}

/**
 * A controller holding ONE board source that supplies `supplyTaskIds`, with
 * `memberRules` as given. Only the fields the dry run reads are populated —
 * the rest of `BoardWizardController` is irrelevant here.
 */
function makeController(args: {
  tasks: Task[];
  supplyTaskIds: string[];
  memberRules?: BoardSource['memberRules'];
  childrenByCompoundId?: Record<string, CompoundChild[]>;
  manualTaskIds?: string[];
  manualTaskVary?: BoardWizardController['manualTaskVary'];
  isRecurring?: boolean;
  isRandomized?: boolean;
  /** `'pool'` drops the target stepper AND the auto/explicit target branch. */
  kind?: 'board' | 'pool';
}): BoardWizardController {
  const source: BoardSource = {
    sourceId: SOURCE_ID,
    kind: args.kind ?? 'board',
    min: 0,
    max: args.supplyTaskIds.length,
    excludedTaskIds: [],
    filter: 'all',
    ...(args.memberRules ? { memberRules: args.memberRules } : {}),
  };
  const supplyInfoBySourceId: SupplyInfoMap = {
    [SOURCE_ID]: {
      displayName: 'Last week',
      rawSupplyTaskIds: args.supplyTaskIds,
      doneTaskIds: new Set<string>(),
      // A pool has no window of its own (B3 RC5).
      ...(args.kind === 'pool' ? {} : { sourceWindow: WEEKLY_SOURCE }),
    },
  };
  const tasksById: Record<string, Task> = {};
  for (const t of args.tasks) tasksById[t.id] = t;
  const childrenByCompoundId = args.childrenByCompoundId ?? {};
  return {
    name: 'Preview Board',
    size: 3,
    timeframe: Timeframe.DAILY,
    customStartDate: '',
    customEndDate: '',
    centerType: CenterSquareType.FREE,
    isRandomized: args.isRandomized ?? false,
    weekStartDay: 'monday',
    isRecurring: args.isRecurring ?? false,
    selectedTaskIds: new Set(args.supplyTaskIds),
    centerTaskId: null,
    poolOrder: [],
    sources: [source],
    manualTaskIds: new Set(args.manualTaskIds ?? []),
    manualTaskVary: args.manualTaskVary ?? {},
    childrenByCompoundId,
    supplyInfoBySourceId,
    expandedSourceIds: new Set<string>(),
    pulledPoolIds: [],
    removedTaskIds: new Set<string>(),
    pendingTasks: new Map(),
    currentStep: 3,
    draftBoardId: null,
    editingTemplateId: null,
    isCore: false,
    targetWindowDate: null,
    tasksRequired: 8,
    expandedSupplies: algorithmSupplies(
      [source],
      supplyInfoBySourceId,
      childrenByCompoundId,
      tasksById,
    ),
    goToStep: () => {},
  } as unknown as BoardWizardController;
}

/** A single-cell placement, which is all the dry run needs to be exercised. */
function placementOf(tasks: Task[]): WizardPlacement {
  return [...tasks];
}

describe('applyPreviewDerivedCells — the Preview dry run (B3 RC6)', () => {
  it('stands a varied board-source counting member in as its derived counter, with the rolled target and generated title', () => {
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 1 } },
    });

    const out = applyPreviewDerivedCells(
      placementOf([counter]),
      controller,
      makeLibrary([counter]),
      makePreviewRng(0),
    );

    const cell = out[0];
    expect(cell).not.toBeNull();
    // A stand-in — a DIFFERENT object carrying the rolled target, but the
    // SAME id: the Save handler re-derives its selection from the
    // placement's task ids, so a preview-only id would be written straight
    // into `board_tasks` as a row pointing at no task.
    expect(cell).not.toBe(counter);
    expect(cell!.id).toBe('c1');
    expect(cell!.type).toBe(TaskType.COUNTING);

    // ±20 % of a goal of 30 — hand-computed, not re-derived from the code
    // under test.
    expect(varyRange(30, 1, 30)).toEqual([24, 30]);
    expect(cell!.maxCount).toBeGreaterThanOrEqual(24);
    expect(cell!.maxCount).toBeLessThanOrEqual(30);

    // The title is the one the minted row will carry — regenerated from the
    // ROLLED target, so the cell never reads "Run 30 miles" for a 25-mile square.
    expect(cell!.title).toBe(generateCounterTaskTitle('Run', cell!.maxCount, 'miles'));
    expect(cell!.action).toBe('Run');
    expect(cell!.unit).toBe('miles');
  });

  it('re-rolls the target when the Shuffle nonce changes, and reproduces it for the same nonce', () => {
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 1 } },
    });
    const library = makeLibrary([counter]);
    const roll = (nonce: number): number | undefined =>
      applyPreviewDerivedCells(
        placementOf([counter]),
        controller,
        library,
        makePreviewRng(nonce),
      )[0]?.maxCount;

    // Range [24, 30] — 7 distinct values, so a difference is meaningful.
    // Nonces 0 and 1 are the first two a Shuffle produces; both land inside
    // the range and on DIFFERENT values (the generator's warm-up is what
    // makes adjacent nonces decorrelate — without it every Shuffle repeated
    // itself).
    expect(roll(0)).toBe(29);
    expect(roll(1)).toBe(27);
    expect(roll(2)).toBe(25);
    // Same nonce ⇒ same preview.
    expect(roll(1)).toBe(27);
  });

  it('leaves a POOL-source counting member with no rule completely alone', () => {
    // A pool has no window to pro-rate against, so `planDerivedTasks` returns
    // a rule-less pool member as-is (B3 RC5) — nothing is minted, and the dry
    // run hands back the SAME array instance.
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      kind: 'pool',
    });

    const placement = placementOf([counter]);
    const out = applyPreviewDerivedCells(
      placement,
      controller,
      makeLibrary([counter]),
      makePreviewRng(0),
    );

    expect(out).toBe(placement);
    expect(out[0]).toBe(counter);
  });

  it('relabels a BOARD-source counting member with no rule at its own goal', () => {
    // A board source always mints (the target/vary branch is open to it), and
    // a one-off board never auto-targets — so the target IS the goal and the
    // only visible change is the REGENERATED title. A member whose stored
    // title drifted from `action + goal + unit` visibly snaps back here, which
    // is exactly what the board will carry.
    const counter = makeCounter('c1', 30, { title: 'Long run (old name)' });
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
    });

    const out = applyPreviewDerivedCells(
      placementOf([counter]),
      controller,
      makeLibrary([counter]),
      makePreviewRng(0),
    );

    expect(out[0]!.id).toBe('c1');
    expect(out[0]!.maxCount).toBe(30);
    expect(out[0]!.title).toBe('Run 30 miles');
  });

  it('previews a stand-in as unstarted rather than inheriting another window\'s progress', () => {
    // The minted counter is baseline-zeroed to THIS board's window. An
    // original that is itself window-stamped carries a baseline for its OWN
    // window, and `taskToSquareState`'s derived-counter carve-out would render
    // that stale pair — so both fields are zeroed on the stand-in.
    const counter = makeCounter('c1', 30, {
      sharedCounterId: 'root-1',
      createdInWizard: true,
      startDate: '2026-08-01T00:00:00.000',
      currentCount: 12,
      baseline: 5,
    });
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 1 } },
    });

    const out = applyPreviewDerivedCells(
      placementOf([counter]),
      controller,
      makeLibrary([counter]),
      makePreviewRng(0),
    );

    expect(out[0]!.currentCount).toBe(0);
    expect(out[0]!.baseline).toBe(0);
  });

  it('keeps a One-square compound member as its original task, so its children still resolve', () => {
    // A compound whose counting part is re-targeted mints a derived COMPOUND
    // at persist time. Its cell renders identically (same title, same type),
    // and swapping the id in would orphan the children lookup that decides
    // whether the cell previews complete — so the cell keeps the original.
    const part = makeCounter('p1', 20);
    const compound = makeTask('cmp1', {
      type: TaskType.COMPOUND,
      title: 'Morning set',
      operator: OperatorType.AND,
    });
    const children = [makeChild('cmp1', 'p1', 0)];
    const controller = makeController({
      tasks: [compound, part],
      supplyTaskIds: ['cmp1'],
      memberRules: { cmp1: { vary: 2 } },
      childrenByCompoundId: { cmp1: children },
    });

    const out = applyPreviewDerivedCells(
      placementOf([compound]),
      controller,
      makeLibrary([compound, part], children),
      makePreviewRng(0),
    );

    expect(out[0]!.id).toBe('cmp1');
    expect(out[0]!.type).toBe(TaskType.COMPOUND);
    expect(out[0]!.title).toBe('Morning set');
  });

  it('writes nothing to the database', async () => {
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 2 } },
    });

    const before = {
      tasks: await db.tasks.count(),
      compoundChildren: await db.compoundChildren.count(),
      syncQueue: await db.syncQueue.count(),
    };

    applyPreviewDerivedCells(
      placementOf([counter]),
      controller,
      makeLibrary([counter]),
      makePreviewRng(3),
    );

    expect({
      tasks: await db.tasks.count(),
      compoundChildren: await db.compoundChildren.count(),
      syncQueue: await db.syncQueue.count(),
    }).toEqual(before);
  });
});

describe('buildWizardPlacement — previewRules is opt-in (B3 RC6)', () => {
  it('places the ORIGINAL tasks when previewRules is omitted (the persist path never double-rolls)', () => {
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 1 } },
    });
    const library = makeLibrary([counter]);

    const placed = buildWizardPlacement(controller, library).filter((t) => t !== null);
    expect(placed.map((t) => t.id)).toEqual(['c1']);
    expect(placed[0].maxCount).toBe(30);
    expect(placed[0].title).toBe('Run 30 miles');
  });

  it('applies the dry run when previewRules is passed', () => {
    const counter = makeCounter('c1', 30);
    const controller = makeController({
      tasks: [counter],
      supplyTaskIds: ['c1'],
      memberRules: { c1: { vary: 1 } },
    });
    const library = makeLibrary([counter]);

    const placed = buildWizardPlacement(controller, library, undefined, {
      seed: 0,
    }).filter((t) => t !== null);

    expect(placed).toHaveLength(1);
    expect(placed[0].id).toBe('c1');
    expect(placed[0].maxCount).toBe(29);
    expect(placed[0].title).toBe('Run 29 miles');
  });

  it('is a pure function of the seed — two consecutive builds are deep-equal, and a new seed re-rolls', () => {
    // The Critical this replaces: `previewRules` used to carry a live
    // GENERATOR, so the Preview's lazy `useState` build and its mount effect
    // consumed different samples and the targets changed one frame after
    // first paint (and again on any `useLiveQuery` tick). A seed makes every
    // build for one nonce identical. `isRandomized: true` so the CELL
    // ARRANGEMENT is covered too, not just the rolls.
    const tasks = [makeCounter('c1', 30), makeTask('n1'), makeTask('n2'), makeTask('n3')];
    const controller = makeController({
      tasks,
      supplyTaskIds: ['c1', 'n1', 'n2', 'n3'],
      memberRules: { c1: { vary: 1 } },
      isRandomized: true,
    });
    const library = makeLibrary(tasks);

    const first = buildWizardPlacement(controller, library, undefined, { seed: 4 });
    const second = buildWizardPlacement(controller, library, undefined, { seed: 4 });
    expect(second).toEqual(first);

    const targetAt = (placement: WizardPlacement): number | undefined =>
      placement.find((t) => t !== null && t.id === 'c1')?.maxCount;
    expect(targetAt(second)).toBe(targetAt(first));

    // A different seed is allowed — and required — to move.
    const seeds = [0, 1, 2, 3, 4, 5].map((seed) =>
      targetAt(buildWizardPlacement(controller, library, undefined, { seed })),
    );
    expect(new Set(seeds).size).toBeGreaterThan(1);
    for (const target of seeds) {
      expect(target).toBeGreaterThanOrEqual(24);
      expect(target).toBeLessThanOrEqual(30);
    }
  });
});
