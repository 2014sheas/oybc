import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
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
  return { id: 'x', childTaskId: null, title: '', isCounting: false, action: '', goal: '', unit: '', markedDeleted: false, ...over };
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
