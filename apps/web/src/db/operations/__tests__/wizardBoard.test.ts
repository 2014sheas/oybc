import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  derivedTaskId,
  varyRange,
  type Board,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { emptyPatch, type ChildPatch, type TaskEditPatch } from '../../taskEditPatch';
import {
  applyStagedTaskEditsForWizardPersist,
  persistWizardBoardRows,
  type PersistWizardBoardRowsInput,
  type WizardPendingTaskWrite,
} from '../wizardBoard';

/**
 * Item 2 (bingo-pipeline hardening) — wizard board creation bypassed
 * derivation: wizard persist / activation hand-init stats (`completedTasks:
 * 0`, etc.) instead of running the shared derivation pass, so a new board
 * placing an already-in-window-complete task (or with a FREE center) stored
 * wrong stats + synced a wrong CREATE until the next app-open self-heal. The
 * fix mirrors the recurring-spawn path (`recurringBoardSpawn.ts`): stored
 * stats are always derivation output, computed over the just-written
 * placements after the board row (and, for a fresh active board, the
 * activation) lands — in the same Dexie transaction.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';

function uuid(n: number): string {
  return `50000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedWindowedCompleteTask(id: string): Promise<Task> {
  const task: Task = {
    id,
    userId: USER,
    title: 'Already done this window',
    type: TaskType.NORMAL,
    isCompleted: false, // lifetime cache is stale/irrelevant — the event decides.
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `${id}-ev`,
    userId: USER,
    taskId: id,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
  return task;
}

function baseInput(
  over: Partial<PersistWizardBoardRowsInput> = {},
): PersistWizardBoardRowsInput {
  return {
    userId: USER,
    draftBoardId: null,
    isCore: false,
    isRecurringDraft: false,
    status: 'active',
    boardFields: {
      name: 'Test board',
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
    },
    placement: new Array(9).fill(null),
    size: 3,
    centerType: CenterSquareType.NONE,
    pendingTasks: [],
    ...over,
  };
}

describe('persistWizardBoardRows — windowed derivation pass (item 2)', () => {
  it('fresh create + activate: a task already windowed-complete stores completedTasks=1, not a hand-init 0', async () => {
    const task = await seedWindowedCompleteTask(uuid(1));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(baseInput({ placement }));

    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.ACTIVE);
    expect(board?.completedTasks).toBe(1);
    expect(board?.linesCompleted).toBe(0); // one cell alone is not a full line.
  });

  it('fresh create + activate: a FREE center auto-fills and counts toward completedTasks', async () => {
    // Odd board (3x3), FREE center, no task placed at the center cell (index 4).
    const boardId = await persistWizardBoardRows(
      baseInput({
        boardFields: {
          name: 'Free center board',
          boardSize: 3,
          timeframe: Timeframe.DAILY,
          startDate: START,
          centerSquareType: CenterSquareType.FREE,
          isRandomized: false,
        },
        centerType: CenterSquareType.FREE,
        placement: new Array(9).fill(null),
      }),
    );

    const board = await db.boards.get(boardId);
    expect(board?.completedTasks).toBe(1); // just the auto-filled FREE center.
  });

  it('does NOT stage an unactivated draft as complete — a draft-status persist skips activation and still derives correctly', async () => {
    const task = await seedWindowedCompleteTask(uuid(2));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({ status: 'draft', placement }),
    );

    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.DRAFT);
    // Derivation still ran (stored stats are always derivation output, never
    // a hand-init) even though the board never activated.
    expect(board?.completedTasks).toBe(1);
  });

  it('draft-resume activation path: saving an existing draft as active derives stats from its placements', async () => {
    // Simulate an existing DRAFT board (as if created by a prior wizard
    // session) with no placements yet.
    const draftId = uuid(3);
    const draftBoard: Board = {
      id: draftId,
      userId: USER,
      name: 'Resumed draft',
      status: BoardStatus.DRAFT,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.boards.add(draftBoard);

    const task = await seedWindowedCompleteTask(uuid(4));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({ draftBoardId: draftId, status: 'active', placement }),
    );

    expect(boardId).toBe(draftId);
    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.ACTIVE);
    expect(board?.completedTasks).toBe(1);
  });

  it('a task with no in-window event does NOT count (no phantom completion from a stale lifetime cache)', async () => {
    // isCompleted=true lifetime cache, but no event in this fresh board's
    // window — must resolve incomplete (the windowed seam item 5 pins at the
    // kernel level; this proves the wizard-persist call site actually wires
    // a real windowContext rather than passing undefined/lifetime).
    const task: Task = {
      id: uuid(5),
      userId: USER,
      title: 'Stale lifetime-complete',
      type: TaskType.NORMAL,
      isCompleted: true,
      completedAt: '2020-01-01T00:00:00.000Z',
      totalCompletions: 1,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(task);
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(baseInput({ placement }));

    const board = await db.boards.get(boardId);
    expect(board?.completedTasks).toBe(0);
  });
});

/**
 * Inline Task Editing (web PR-2) — the staged-edit apply inside the
 * board-create transaction. This is the highest-risk path per the design
 * handoff: it mirrors iOS `saveWizardBoard`'s staged-edits block, which is
 * exactly where the earlier Bug #85 drops (stagedEdits, pending tasks) hid
 * on iOS. Covers: a library normal/counting edit applying on active create
 * but never on a draft create, and — the case this handoff calls out
 * explicitly — a PENDING compound created with an inline sub-task AND a
 * staged edit (rename + a second inline-added sub-task + an existing
 * sub-task rename) all landing correctly in one atomic create.
 */
function simpleChildPatch(over: Partial<ChildPatch>): ChildPatch {
  return { id: 'x', childTaskId: null, title: '', isCounting: false, action: '', goal: '', unit: '', markedDeleted: false, ...over, childType: over.childType ?? (over.isCounting ? TaskType.COUNTING : TaskType.NORMAL) };
}

describe('persistWizardBoardRows — staged inline edits (Inline Task Editing PR-2)', () => {
  it('applies a staged edit to a LIBRARY normal task on an ACTIVE create', async () => {
    const task: Task = {
      id: uuid(10),
      userId: USER,
      title: 'Old title',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(task);
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const stagedEdits = new Map<string, TaskEditPatch>([[task.id, emptyPatch('New title')]]);
    await persistWizardBoardRows(baseInput({ placement, stagedEdits, status: 'active' }));

    const updated = await db.tasks.get(task.id);
    expect(updated?.title).toBe('New title');
    expect(updated?.version).toBe(2);
  });

  it('does NOT apply a staged edit when saving as a DRAFT — a draft never carries a task edit', async () => {
    const task: Task = {
      id: uuid(11),
      userId: USER,
      title: 'Old title',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(task);
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const stagedEdits = new Map<string, TaskEditPatch>([[task.id, emptyPatch('New title')]]);
    await persistWizardBoardRows(baseInput({ placement, stagedEdits, status: 'draft' }));

    const unchanged = await db.tasks.get(task.id);
    expect(unchanged?.title).toBe('Old title');
    expect(unchanged?.version).toBe(1);
  });

  it('skips a staged edit for a task that no longer exists (defensive)', async () => {
    const placement = new Array(9).fill(null);
    const stagedEdits = new Map<string, TaskEditPatch>([['missing-task', emptyPatch('New title')]]);
    // Must not throw.
    await expect(
      persistWizardBoardRows(baseInput({ placement, stagedEdits, status: 'active' })),
    ).resolves.toBeTruthy();
  });

  it('a PENDING compound created with one inline sub-task, plus a staged edit that renames it and adds a second inline sub-task, persists correctly in one atomic create', async () => {
    const compoundId = uuid(20);
    const originalChildId = uuid(21);

    const originalChild: Task = {
      id: originalChildId,
      userId: USER,
      title: 'Warm up',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    const compoundTask: Task = {
      id: compoundId,
      userId: USER,
      title: 'Morning routine',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    const originalLink: CompoundChild = {
      id: uuid(22),
      compoundTaskId: compoundId,
      childTaskId: originalChildId,
      childIndex: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };

    const pendingTasks: WizardPendingTaskWrite[] = [
      { task: compoundTask, childTasks: [originalChild], childLinks: [originalLink] },
    ];

    // Staged edit: rename the parent + rename the existing sub-task + add a
    // brand-new inline sub-task ("Cool down", isNewChild — childTaskId null).
    const stagedEdits = new Map<string, TaskEditPatch>([
      [
        compoundId,
        {
          ...emptyPatch('Morning routine v2'),
          operator: OperatorType.AND,
          children: [
            simpleChildPatch({ id: originalChildId, childTaskId: originalChildId, title: 'Warm-up stretch' }),
            simpleChildPatch({ id: 'new-child-draft-id', childTaskId: null, title: 'Cool down' }),
          ],
        },
      ],
    ]);

    const placement = new Array(9).fill(null);
    placement[0] = compoundTask;

    const boardId = await persistWizardBoardRows(
      baseInput({ placement, pendingTasks, stagedEdits, status: 'active' }),
    );
    expect(boardId).toBeTruthy();

    // Parent: renamed + version bumped once (pending write = v1, staged
    // edit apply = v2).
    const savedParent = await db.tasks.get(compoundId);
    expect(savedParent?.title).toBe('Morning routine v2');
    expect(savedParent?.version).toBe(2);

    // Existing sub-task: renamed + version bumped.
    const savedOriginalChild = await db.tasks.get(originalChildId);
    expect(savedOriginalChild?.title).toBe('Warm-up stretch');
    expect(savedOriginalChild?.version).toBe(2);

    // Two live (non-deleted) links now — the kept original + the new one —
    // in the patch's display order.
    const links = (await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()).filter(
      (l) => !l.isDeleted,
    );
    expect(links).toHaveLength(2);
    const byIndex = [...links].sort((a, b) => a.childIndex - b.childIndex);
    expect(byIndex[0].childTaskId).toBe(originalChildId);
    expect(byIndex[0].childIndex).toBe(0);

    const newChildId = byIndex[1].childTaskId;
    expect(byIndex[1].childIndex).toBe(1);
    const newChildTask = await db.tasks.get(newChildId);
    expect(newChildTask?.title).toBe('Cool down');
    expect(newChildTask?.type).toBe(TaskType.NORMAL);

    // The new sub-task's sync-queue CREATE entry actually landed (not just
    // the DB row) — otherwise it would silently never sync.
    const syncRows = (await db.syncQueue.toArray()).filter((r) => r.entityId === newChildId);
    expect(syncRows.some((r) => r.entityType === 'tasks')).toBe(true);
  });

  it('a staged compound edit that removes a sub-task soft-deletes only the LINK — the child Task survives as a library orphan', async () => {
    const compoundId = uuid(30);
    const keptChildId = uuid(31);
    const keptChildId2 = uuid(35);
    const removedChildId = uuid(32);

    const compoundTask: Task = {
      id: compoundId,
      userId: USER,
      title: 'Routine',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(compoundTask);
    for (const [id, title] of [
      [keptChildId, 'Keep me'],
      [keptChildId2, 'Keep me too'],
      [removedChildId, 'Remove me'],
    ] as const) {
      await db.tasks.add({
        id,
        userId: USER,
        title,
        type: TaskType.NORMAL,
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: START,
        updatedAt: START,
        version: 1,
        isDeleted: false,
      });
    }
    const keptLink: CompoundChild = {
      id: uuid(33),
      compoundTaskId: compoundId,
      childTaskId: keptChildId,
      childIndex: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    const keptLink2: CompoundChild = {
      id: uuid(36),
      compoundTaskId: compoundId,
      childTaskId: keptChildId2,
      childIndex: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    const removedLink: CompoundChild = {
      id: uuid(34),
      compoundTaskId: compoundId,
      childTaskId: removedChildId,
      childIndex: 2,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.compoundChildren.bulkAdd([keptLink, keptLink2, removedLink]);

    const stagedEdits = new Map<string, TaskEditPatch>([
      [
        compoundId,
        {
          ...emptyPatch('Routine'),
          operator: OperatorType.AND,
          // Only the two kept children survive in the patch's children
          // array — dropping a sub-task from the editor means it's simply
          // absent (validation still passes: 2 >= 2 required).
          children: [
            simpleChildPatch({ id: keptChildId, childTaskId: keptChildId, title: 'Keep me' }),
            simpleChildPatch({ id: keptChildId2, childTaskId: keptChildId2, title: 'Keep me too' }),
          ],
        },
      ],
    ]);

    const placement = new Array(9).fill(null);
    placement[0] = compoundTask;
    await persistWizardBoardRows(baseInput({ placement, stagedEdits, status: 'active' }));

    const remainingLinks = (
      await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()
    ).filter((l) => !l.isDeleted);
    expect(remainingLinks).toHaveLength(2);
    expect(remainingLinks.map((l) => l.childTaskId).sort()).toEqual([keptChildId, keptChildId2].sort());

    // The removed child's Task row is untouched — an orphan, not deleted.
    const orphan = await db.tasks.get(removedChildId);
    expect(orphan?.isDeleted).toBe(false);
    expect(orphan?.title).toBe('Remove me');
  });
});

describe('applyStagedTaskEditsForWizardPersist — standalone (recurring-template call site)', () => {
  it('applies a compound edit and cascades when called directly inside a wide-enough transaction', async () => {
    const compoundId = uuid(40);
    const compoundTask: Task = {
      id: compoundId,
      userId: USER,
      title: 'Old',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(compoundTask);

    const stagedEdits = new Map<string, TaskEditPatch>([
      [
        compoundId,
        {
          ...emptyPatch('New'),
          operator: OperatorType.AND,
          children: [
            simpleChildPatch({ id: 'a', childTaskId: null, title: 'A' }),
            simpleChildPatch({ id: 'b', childTaskId: null, title: 'B' }),
          ],
        },
      ],
    ]);

    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      async () => {
        await applyStagedTaskEditsForWizardPersist(stagedEdits, new Set(), START);
      },
    );

    const saved = await db.tasks.get(compoundId);
    expect(saved?.title).toBe('New');
    expect(saved?.version).toBe(2);
    const links = (await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()).filter(
      (l) => !l.isDeleted,
    );
    expect(links).toHaveLength(2);
  });
});

/**
 * Board Sources §Member rules (B2) — the persist path mints window-stamped
 * derived counters before the `board_tasks` rows that point at them, and a
 * replaced member keeps its cell (the centre pin is the load-bearing case).
 */
describe('persistWizardBoardRows — member-rule mint', () => {
  // The source board's window is 2026-06-22..28; an ENDED board supplies
  // nothing (owner ruling 2026-09-24), so the persist runs while it is
  // still open — planning July's board during that week.
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-06-25T12:00:00.000'));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  const ROOT = uuid(90);
  const FILLER = uuid(91);
  const SOURCE_BOARD = uuid(92);

  async function seedSourceBoardWithCounter(): Promise<Task> {
    const root: Task = {
      id: ROOT,
      userId: USER,
      title: 'Run 35 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 35,
      currentCount: 20,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(root);
    await db.taskEvents.add({
      id: `${ROOT}-pre`,
      userId: USER,
      taskId: ROOT,
      kind: 'increment',
      delta: 14,
      occurredAt: '2026-06-01T00:00:00.000Z', // strictly before START
      createdAt: '2026-06-01T00:00:00.000Z',
      updatedAt: '2026-06-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    });
    const source: Board = {
      id: SOURCE_BOARD,
      userId: USER,
      name: 'Source',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: '2026-06-22T00:00:00.000',
      endDate: '2026-06-28T23:59:59.999',
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.boards.add(source);
    await db.boardTasks.add({
      id: `bt-src-${ROOT}`,
      boardId: SOURCE_BOARD,
      taskId: ROOT,
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    });
    return root;
  }

  it('places the derived counter instead of the pulled member, and writes its row first', async () => {
    const root = await seedSourceBoardWithCounter();
    const placement = new Array(9).fill(null);
    placement[3] = root;

    const boardId = await persistWizardBoardRows(
      baseInput({
        placement,
        sources: [
          {
            sourceId: SOURCE_BOARD,
            kind: 'board',
            min: 0,
            max: null,
            excludedTaskIds: [],
            filter: 'all',
            memberRules: { [ROOT]: { target: 12 } },
          },
        ],
        manualTaskIds: [],
      }),
    );

    const derivedId = derivedTaskId(boardId, ROOT);
    const derived = await db.tasks.get(derivedId);
    expect(derived?.maxCount).toBe(12); // the member rule's explicit target
    expect(derived?.baseline).toBe(14); // the root's pre-window log
    expect(derived?.sharedCounterId).toBe(ROOT);

    const rows = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(rows).toHaveLength(1);
    // The placement points at the derived row — which therefore must already
    // have existed when `createBoardTask` ran (it validates against `tasks`).
    expect(rows[0].taskId).toBe(derivedId);
    expect(rows[0].row).toBe(1);
    expect(rows[0].col).toBe(0); // cell 3 — the member kept its square
  });

  it('a CHOSEN centre that resolves to a derived counter keeps its cell and the board follows it', async () => {
    const root = await seedSourceBoardWithCounter();
    const filler: Task = {
      id: FILLER,
      userId: USER,
      title: 'Filler',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(filler);

    const placement = new Array(9).fill(null);
    placement[0] = filler;
    placement[4] = root; // the centre cell of a 3×3

    const boardId = await persistWizardBoardRows(
      baseInput({
        placement,
        centerType: CenterSquareType.CHOSEN,
        boardFields: {
          name: 'Centre board',
          boardSize: 3,
          timeframe: Timeframe.DAILY,
          startDate: START,
          centerSquareType: CenterSquareType.CHOSEN,
          centerTaskId: ROOT,
          isRandomized: false,
        },
        sources: [
          {
            sourceId: SOURCE_BOARD,
            kind: 'board',
            min: 0,
            max: null,
            excludedTaskIds: [],
            filter: 'all',
          },
        ],
        manualTaskIds: [],
      }),
    );

    const derivedId = derivedTaskId(boardId, ROOT);
    const rows = await db.boardTasks.where('boardId').equals(boardId).toArray();
    const centre = rows.find((bt) => bt.isCenter);
    expect(centre?.taskId).toBe(derivedId);
    expect(centre?.row).toBe(1);
    expect(centre?.col).toBe(1);
    // The other cell is untouched by the plan.
    expect(rows.find((bt) => !bt.isCenter)?.taskId).toBe(FILLER);
    const board = await db.boards.get(boardId);
    expect(board?.centerTaskId).toBe(derivedId);
  });

  it('a DRAFT save mints nothing; activating the same draft mints it', async () => {
    const root = await seedSourceBoardWithCounter();
    const placement = new Array(9).fill(null);
    placement[0] = root;
    const source = {
      sourceId: SOURCE_BOARD,
      kind: 'board' as const,
      min: 0,
      max: null,
      excludedTaskIds: [],
      filter: 'all' as const,
      memberRules: { [ROOT]: { target: 12 } },
    };

    const boardId = await persistWizardBoardRows(
      baseInput({ placement, status: 'draft', sources: [source], manualTaskIds: [] }),
    );

    // A draft's window is still editable, so nothing is stamped for it yet.
    const derivedId = derivedTaskId(boardId, ROOT);
    expect(await db.tasks.get(derivedId)).toBeUndefined();
    expect(
      await db.compoundChildren.where('compoundTaskId').equals(derivedId).count(),
    ).toBe(0);
    expect((await db.syncQueue.toArray()).filter((q) => q.entityId === derivedId)).toHaveLength(
      0,
    );
    expect(
      (await db.boardTasks.where('boardId').equals(boardId).toArray())[0].taskId,
    ).toBe(ROOT);

    // Resuming the same draft and saving it ACTIVE derives the window once,
    // from final values.
    await persistWizardBoardRows(
      baseInput({
        placement,
        draftBoardId: boardId,
        status: 'active',
        sources: [source],
        manualTaskIds: [],
      }),
    );

    const derived = await db.tasks.get(derivedId);
    expect(derived?.maxCount).toBe(12);
    expect(derived?.baseline).toBe(14);
    const rows = (await db.boardTasks.where('boardId').equals(boardId).toArray()).filter(
      (bt) => !bt.isDeleted,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].taskId).toBe(derivedId);
  });

  it('leaves a hand-added member alone — no source, no rule, no derived row', async () => {
    const root = await seedSourceBoardWithCounter();
    const placement = new Array(9).fill(null);
    placement[0] = root;

    const boardId = await persistWizardBoardRows(
      baseInput({
        placement,
        sources: [
          {
            sourceId: SOURCE_BOARD,
            kind: 'board',
            min: 0,
            max: null,
            excludedTaskIds: [],
            filter: 'all',
            memberRules: { [ROOT]: { target: 12 } },
          },
        ],
        manualTaskIds: [ROOT], // hand-added beats the source copy
      }),
    );

    expect(await db.tasks.get(derivedTaskId(boardId, ROOT))).toBeUndefined();
    const rows = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(rows[0].taskId).toBe(ROOT);
  });
});

/**
 * §Member rules (B3, RC3) — the hand-added layer's dice. `manualTaskVary`
 * now reaches the mint from the wizard controller (it was a hard-coded `{}`
 * placeholder in B2), so a hand-added counter with a dice level is placed as
 * a window-stamped derived counter whose target is ROLLED inside its range
 * instead of always taking the goal.
 */
describe('persistWizardBoardRows — manualTaskVary (B3)', () => {
  const HAND = uuid(95);
  const GOAL = 10;

  async function seedHandAddedCounter(): Promise<Task> {
    const task: Task = {
      id: HAND,
      userId: USER,
      title: 'Push-ups',
      type: TaskType.COUNTING,
      action: 'Do',
      unit: 'reps',
      maxCount: GOAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(task);
    return task;
  }

  it('a hand-added counting member with vary 1 mints a derived row ROLLED inside varyRange', async () => {
    const task = await seedHandAddedCounter();
    const placement = new Array(9).fill(null);
    placement[0] = task;

    // Seeded rng — `varyRange(10, 1, 10)` is [8, 10] and its top IS the goal,
    // so a range-only assertion would also pass against a no-roll
    // implementation. Pinning the low end proves the roll happened.
    const boardId = await persistWizardBoardRows(
      baseInput({
        placement,
        sources: [],
        manualTaskIds: [HAND],
        manualTaskVary: { [HAND]: 1 },
        rng: () => 0,
      }),
    );

    const [lo, hi] = varyRange(GOAL, 1, GOAL);
    expect(lo).toBeLessThan(GOAL); // the assertion below is not degenerate
    const derived = await db.tasks.get(derivedTaskId(boardId, HAND));
    expect(derived).toBeDefined();
    expect(derived?.sharedCounterId).toBe(HAND);
    expect(derived?.maxCount).toBe(lo);
    expect(derived?.maxCount).toBeLessThanOrEqual(hi);

    const rows = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(rows[0].taskId).toBe(derived?.id);
  });

  it('the roll really is the rng\u2019s: the top of the range lands with the opposite seed', async () => {
    const task = await seedHandAddedCounter();
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({
        placement,
        sources: [],
        manualTaskIds: [HAND],
        manualTaskVary: { [HAND]: 2 },
        rng: () => 0.999,
      }),
    );

    const [, hi] = varyRange(GOAL, 2, GOAL);
    expect(await db.tasks.get(derivedTaskId(boardId, HAND))).toMatchObject({ maxCount: hi });
  });

  it('vary 0 (or an absent map) places the hand-added task itself — nothing is minted', async () => {
    const task = await seedHandAddedCounter();
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({ placement, sources: [], manualTaskIds: [HAND] }),
    );

    expect(await db.tasks.get(derivedTaskId(boardId, HAND))).toBeUndefined();
    const rows = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(rows[0].taskId).toBe(HAND);
  });
});
