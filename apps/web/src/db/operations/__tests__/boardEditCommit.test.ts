import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import { taskToSquareState } from '../../adapters';
import { newChildPatch, type ChildPatch, type TaskEditPatch } from '../../taskEditPatch';

/**
 * Board Edit redesign slice 3 (T2) — `commitSquareEdits`, the squares
 * editor's ONE Save transaction (D15). Exercises the REAL production op
 * (unlike the pre-slice-3 `boardEditSaveAtomicity.test.ts`, whose replica
 * this train's plan explicitly retires in favor of this file + a rewritten
 * atomicity test against the real op).
 */

const START = '2026-07-01T00:00:00.000Z';
const BOARD = 'board-1';

function seedTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id, userId: 'user-1', title: `Task ${id}`, type: TaskType.NORMAL,
    isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
    ...overrides,
  };
}

function seedBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: BOARD, userId: 'user-1', name: 'Board', status: BoardStatus.ACTIVE,
    boardSize: 3, timeframe: Timeframe.MONTHLY, startDate: START,
    centerSquareType: CenterSquareType.NONE, isRandomized: false,
    totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
    ...overrides,
  };
}

function seedPlacement(id: string, taskId: string, row: number, col: number, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id, boardId: BOARD, taskId, row, col, isCenter: false,
    createdAt: START, updatedAt: START, version: 1, isDeleted: false,
    ...overrides,
  };
}

function cell(overrides: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId' | 'row' | 'col'>): SquareDraftCell {
  return {
    isLocked: false,
    originalTaskId: overrides.taskId,
    originalRow: overrides.row,
    originalCol: overrides.col,
    originalLocked: false,
    ...overrides,
  };
}

function baseInput(partial: Partial<CommitSquareEditsInput> = {}): CommitSquareEditsInput {
  return {
    boardId: BOARD,
    cells: [],
    removedBoardTaskIds: [],
    taskOverrides: new Map(),
    isLegacyChosenOnDisk: false,
    centerCellKeepLocked: false,
    ...partial,
  };
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('commitSquareEdits', () => {
  it('writes a pending new task (createdInWizard: false) + its placement + 2 queue rows', async () => {
    await db.boards.add(seedBoard());
    const pendingTask = seedTask('task-new', { createdInWizard: true });

    await commitSquareEdits(
      baseInput({
        cells: [
          cell({
            cellId: 'new-0-0-task-new',
            taskId: 'task-new',
            row: 0,
            col: 0,
            originalTaskId: null,
            pending: { task: pendingTask, childTasks: [], childLinks: [] },
          }),
        ],
      }),
    );

    const stored = await db.tasks.get('task-new');
    expect(stored).toBeDefined();
    expect(stored?.createdInWizard).toBe(false);

    const placements = await db.boardTasks.where('boardId').equals(BOARD).toArray();
    expect(placements).toHaveLength(1);
    expect(placements[0]).toMatchObject({ taskId: 'task-new', row: 0, col: 0 });

    const queued = await db.syncQueue.toArray();
    // 'boards' is enqueued too — `addBoardTaskToBoard`'s cascade always
    // re-derives + enqueues the board the new placement lands on.
    expect(queued.map((q) => q.entityType).sort()).toEqual(['boardTasks', 'boards', 'tasks']);
  });

  it('adds an existing task to a just-removed cell position, in the same save (ordering)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0));

    await commitSquareEdits(
      baseInput({
        removedBoardTaskIds: ['bt-a'],
        cells: [
          cell({ cellId: 'new-0-0-task-b', taskId: 'task-b', row: 0, col: 0, originalTaskId: null }),
        ],
      }),
    );

    const live = await db.boardTasks.where('boardId').equals(BOARD).filter((bt) => !bt.isDeleted).toArray();
    expect(live).toHaveLength(1);
    expect(live[0].taskId).toBe('task-b');
    const removed = await db.boardTasks.get('bt-a');
    expect(removed?.isDeleted).toBe(true);
  });

  it('a Free-center toggle tombstones the center placement and the metadata patch lands', async () => {
    await db.boards.add(seedBoard({ boardSize: 3, centerSquareType: CenterSquareType.NONE, totalTasks: 9 }));
    await db.tasks.add(seedTask('task-c'));
    await db.boardTasks.add(seedPlacement('bt-c', 'task-c', 1, 1, { isCenter: false }));

    await commitSquareEdits(
      baseInput({
        removedBoardTaskIds: ['bt-c'],
        centerPatch: { centerSquareType: CenterSquareType.FREE },
      }),
    );

    expect((await db.boardTasks.get('bt-c'))?.isDeleted).toBe(true);
    const board = await db.boards.get(BOARD);
    expect(board?.centerSquareType).toBe(CenterSquareType.FREE);
  });

  it('a legacy-CHOSEN board plus one unrelated edit normalizes to NONE + a locked center', async () => {
    await db.boards.add(
      seedBoard({ centerSquareType: CenterSquareType.CHOSEN, centerTaskId: 'task-c' }),
    );
    await db.tasks.add(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.tasks.add(seedTask('task-c'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0));
    await db.boardTasks.add(seedPlacement('bt-c', 'task-c', 1, 1, { isCenter: true }));

    await commitSquareEdits(
      baseInput({
        isLegacyChosenOnDisk: true,
        centerCellKeepLocked: true,
        cells: [cell({ cellId: 'bt-a', taskId: 'task-b', row: 0, col: 0, originalTaskId: 'task-a' })],
      }),
    );

    const board = await db.boards.get(BOARD);
    expect(board?.centerSquareType).toBe(CenterSquareType.NONE);
    expect(board?.centerTaskId).toBeUndefined();
    const center = await db.boardTasks.get('bt-c');
    expect(center?.isLocked).toBe(true);
    expect(center?.isCenter).toBe(false);
    expect((await db.boardTasks.get('bt-a'))?.taskId).toBe('task-b');
  });

  it('shuffled moves persist', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0));
    await db.boardTasks.add(seedPlacement('bt-b', 'task-b', 0, 1));

    await commitSquareEdits(
      baseInput({
        cells: [
          cell({ cellId: 'bt-a', taskId: 'task-a', row: 2, col: 2, originalRow: 0, originalCol: 0 }),
          cell({ cellId: 'bt-b', taskId: 'task-b', row: 0, col: 1, originalRow: 0, originalCol: 1 }),
        ],
      }),
    );

    expect(await db.boardTasks.get('bt-a')).toMatchObject({ row: 2, col: 2 });
  });

  it('a locked row in the move set rejects the WHOLE save (nothing writes)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0, { isLocked: true }));
    await db.tasks.add(seedTask('task-override-target'));

    await expect(
      commitSquareEdits(
        baseInput({
          cells: [
            cell({ cellId: 'bt-a', taskId: 'task-a', row: 1, col: 1, originalRow: 0, originalCol: 0, isLocked: true, originalLocked: true }),
          ],
          taskOverrides: new Map([['task-override-target', { title: 'Should roll back' }]]),
        }),
      ),
    ).rejects.toThrow(/locked in place/);

    expect((await db.boardTasks.get('bt-a'))?.row).toBe(0);
    expect((await db.tasks.get('task-override-target'))?.title).not.toBe('Should roll back');
    expect(await db.syncQueue.count()).toBe(0);
  });
  it('unlock + move of the same square in ONE session commits (unlocks land before moves)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-a'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0, { isLocked: true }));

    await commitSquareEdits(
      baseInput({
        cells: [
          cell({ cellId: 'bt-a', taskId: 'task-a', row: 2, col: 2, originalRow: 0, originalCol: 0, isLocked: false, originalLocked: true }),
        ],
      }),
    );

    expect(await db.boardTasks.get('bt-a')).toMatchObject({ row: 2, col: 2, isLocked: false });
  });

  it('move + lock of the same square in ONE session commits (locks land after moves)', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.add(seedTask('task-a'));
    await db.boardTasks.add(seedPlacement('bt-a', 'task-a', 0, 0));

    await commitSquareEdits(
      baseInput({
        cells: [
          cell({ cellId: 'bt-a', taskId: 'task-a', row: 2, col: 2, originalRow: 0, originalCol: 0, isLocked: true, originalLocked: false }),
        ],
      }),
    );

    expect(await db.boardTasks.get('bt-a')).toMatchObject({ row: 2, col: 2, isLocked: true });
  });

  it('a pending task’s child tasks are also written createdInWizard: false (iOS parity)', async () => {
    await db.boards.add(seedBoard());
    const parent = seedTask('task-p', { createdInWizard: true });
    const child = seedTask('task-child', { createdInWizard: true });

    await commitSquareEdits(
      baseInput({
        cells: [
          cell({
            cellId: 'new-0-0-task-p', taskId: 'task-p', row: 0, col: 0, originalTaskId: null,
            pending: { task: parent, childTasks: [child], childLinks: [] },
          }),
        ],
      }),
    );

    expect((await db.tasks.get('task-child'))?.createdInWizard).toBe(false);
  });
});

// ─── Board Edit "Edit task…" — type switches + compound edit / conversion ────

function sub(title: string, over: Partial<ChildPatch> = {}): ChildPatch {
  return { ...newChildPatch(false), title, ...over };
}

function compoundPatch(children: ChildPatch[], over: Partial<TaskEditPatch> = {}): TaskEditPatch {
  return {
    title: 'Combo', action: '', goal: '', unit: '',
    children, operator: OperatorType.AND,
    ...over,
  };
}

async function liveLinks(parentId: string) {
  return (await db.compoundChildren.where('compoundTaskId').equals(parentId).toArray()).filter((l) => !l.isDeleted);
}

describe('commitSquareEdits — type switches and compound overrides', () => {
  async function seedPlaced(task: Task): Promise<void> {
    await db.boards.add(seedBoard());
    await db.tasks.add(task);
    await db.boardTasks.add(seedPlacement('bt-a', task.id, 0, 0));
  }

  it('Simple → Compound with 2 new children: row converted, 2 child tasks + 2 links, version bumped, enqueued', async () => {
    await seedPlaced(seedTask('task-a', { isCompleted: true, completedAt: START }));

    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([
          ['task-a', { type: TaskType.COMPOUND, title: 'Combo', compound: compoundPatch([sub('One'), sub('Two')]) }],
        ]),
      }),
    );

    const row = await db.tasks.get('task-a');
    expect(row).toMatchObject({ type: TaskType.COMPOUND, title: 'Combo', operator: OperatorType.AND, isCompleted: false, version: 2 });
    expect(row?.completedAt).toBeUndefined();
    const links = await liveLinks('task-a');
    expect(links).toHaveLength(2);
    const kids = await db.tasks.bulkGet(links.map((l) => l.childTaskId));
    expect(kids.map((k) => k?.title).sort()).toEqual(['One', 'Two']);
    const queued = await db.syncQueue.toArray();
    expect(queued.filter((q) => q.entityType === 'tasks' && q.entityId === 'task-a').length).toBeGreaterThan(0);
    expect(queued.filter((q) => q.entityType === 'compoundChildren')).toHaveLength(2);
  });

  it('Counting → Compound clears the counting fields', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, currentCount: 2 }));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) }]]),
      }),
    );
    const row = (await db.tasks.get('task-a'))!;
    expect(row.type).toBe(TaskType.COMPOUND);
    expect(row.action).toBeUndefined();
    expect(row.unit).toBeUndefined();
    expect(row.maxCount).toBeUndefined();
    expect(row.currentCount).toBeUndefined();
  });

  it('existing compound: operator change + one child removed + one existing library task linked', async () => {
    await db.boards.add(seedBoard());
    await db.tasks.bulkAdd([
      seedTask('comp', { type: TaskType.COMPOUND, operator: OperatorType.AND }),
      seedTask('c1', { title: 'C1' }),
      seedTask('c2', { title: 'C2' }),
      seedTask('lib', { title: 'Library task' }),
    ]);
    await db.boardTasks.add(seedPlacement('bt-a', 'comp', 0, 0));
    const link = (id: string, child: string, i: number) => ({
      id, compoundTaskId: 'comp', childTaskId: child, childIndex: i,
      createdAt: START, updatedAt: START, version: 1, isDeleted: false,
    });
    await db.compoundChildren.bulkAdd([link('l1', 'c1', 0), link('l2', 'c2', 1)]);

    const patch = compoundPatch(
      [
        { ...sub('C1'), id: 'c1', childTaskId: 'c1' },
        { ...sub('C2'), id: 'c2', childTaskId: 'c2', markedDeleted: true },
        { ...sub('Library task'), id: 'lib', childTaskId: 'lib' },
      ],
      { operator: OperatorType.OR },
    );
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'comp', row: 0, col: 0 })],
        taskOverrides: new Map([['comp', { title: 'Combo', compound: patch }]]),
      }),
    );

    expect((await db.tasks.get('comp'))).toMatchObject({ title: 'Combo', operator: OperatorType.OR, version: 2 });
    expect((await liveLinks('comp')).map((l) => l.childTaskId).sort()).toEqual(['c1', 'lib']);
    expect((await db.compoundChildren.get('l2'))?.isDeleted).toBe(true);
    expect((await db.tasks.get('c2'))?.isDeleted).toBe(false); // link only
  });

  it('Simple → Counting switches the type in place (bypassing the immutability guard)', async () => {
    await seedPlaced(seedTask('task-a'));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km' }]]),
      }),
    );
    expect(await db.tasks.get('task-a')).toMatchObject({
      type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', maxCount: 5, unit: 'km', version: 2,
    });
    expect((await db.syncQueue.toArray()).some((q) => q.entityType === 'tasks' && q.entityId === 'task-a')).toBe(true);
  });

  it('Counting → Simple clears action / unit / maxCount', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COUNTING, title: 'Run', action: 'Run', unit: 'km', maxCount: 5 }));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.NORMAL, title: 'Run', action: undefined, unit: undefined, maxCount: undefined }]]),
      }),
    );
    const row = (await db.tasks.get('task-a'))!;
    expect(row.type).toBe(TaskType.NORMAL);
    expect(row.action).toBeUndefined();
    expect(row.unit).toBeUndefined();
    expect(row.maxCount).toBeUndefined();
    expect(row.version).toBe(2);
  });

  it('an invalid compound (1 child) rejects the Save and NOTHING was written', async () => {
    await seedPlaced(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.boardTasks.add(seedPlacement('bt-b', 'task-b', 0, 1));

    await expect(
      commitSquareEdits(
        baseInput({
          // an earlier step (a removal) would have written before 7b throws
          removedBoardTaskIds: ['bt-b'],
          cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
          taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('Only one')]) }]]),
        }),
      ),
    ).rejects.toThrow(/at least two sub-tasks/);

    expect((await db.tasks.get('task-a'))).toMatchObject({ type: TaskType.NORMAL, version: 1 });
    expect((await db.boardTasks.get('bt-b'))?.isDeleted).toBe(false);
    expect(await db.compoundChildren.count()).toBe(0);
    expect(await db.tasks.count()).toBe(2);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('a Counting target without a unit rejects the whole Save', async () => {
    await seedPlaced(seedTask('task-a'));
    await expect(
      commitSquareEdits(
        baseInput({
          cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
          taskOverrides: new Map([['task-a', { type: TaskType.COUNTING, maxCount: 5 }]]),
        }),
      ),
    ).rejects.toThrow(/goal and a unit/);
    expect((await db.tasks.get('task-a'))?.type).toBe(TaskType.NORMAL);
  });

  it('an override on a PENDING (picker-born) task: step 1 inserts it, 7b converts it', async () => {
    await db.boards.add(seedBoard());
    const pending = seedTask('task-new', { createdInWizard: true });
    await commitSquareEdits(
      baseInput({
        cells: [
          cell({
            cellId: 'new-0-0-task-new', taskId: 'task-new', row: 0, col: 0, originalTaskId: null,
            pending: { task: pending, childTasks: [], childLinks: [] },
          }),
        ],
        taskOverrides: new Map([['task-new', { type: TaskType.COMPOUND, title: 'Combo', compound: compoundPatch([sub('One'), sub('Two')]) }]]),
      }),
    );
    expect(await db.tasks.get('task-new')).toMatchObject({ type: TaskType.COMPOUND, createdInWizard: false });
    expect(await liveLinks('task-new')).toHaveLength(2);
    expect((await db.boardTasks.where('boardId').equals(BOARD).toArray())[0].taskId).toBe('task-new');
  });

  it('a converted compound is written with operator AND and completes only when BOTH children complete (real derivation)', async () => {
    await seedPlaced(seedTask('task-a'));
    // Seed exactly as the sheet does for a non-compound task: no operator authored.
    const draftNoOp = compoundPatch([sub('One'), sub('Two')]);
    delete draftNoOp.operator;
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: draftNoOp }]]),
      }),
    );
    const row = (await db.tasks.get('task-a'))!;
    expect(row.operator).toBe(OperatorType.AND);
    const links = await liveLinks('task-a');
    const kids = (await db.tasks.bulkGet(links.map((l) => l.childTaskId))) as Task[];
    const childrenByCompound = { 'task-a': links };
    const stateWith = (done: boolean[]) => {
      const taskMap: Record<string, Task> = { 'task-a': row };
      kids.forEach((k, i) => { taskMap[k.id] = { ...k, isCompleted: done[i] }; });
      return taskToSquareState(row, links, taskMap, childrenByCompound).isCompleted;
    };
    expect(stateWith([true, false])).toBe(false);
    expect(stateWith([true, true])).toBe(true);
  });

  it('a Simple task staged → Compound → back to Simple commits a plain title edit (no conversion)', async () => {
    await seedPlaced(seedTask('task-a'));
    // The reducer's end state after: stage compound, then stage the switch back.
    const staged = { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) };
    const back = { type: TaskType.NORMAL, title: 'Renamed', compound: undefined };
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { ...staged, ...back }]]),
      }),
    );
    expect(await db.tasks.get('task-a')).toMatchObject({ type: TaskType.NORMAL, title: 'Renamed' });
    expect(await db.compoundChildren.count()).toBe(0);
    expect(await db.tasks.count()).toBe(1);
  });

  it('a linked (window-stamped derived) counter rejects a type change and a compound patch', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, sharedCounterId: 'root-1' }));
    const cells = [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })];
    await expect(
      commitSquareEdits(baseInput({ cells, taskOverrides: new Map([['task-a', { type: TaskType.NORMAL }]]) })),
    ).rejects.toThrow(/linked counter/);
    await expect(
      commitSquareEdits(
        baseInput({ cells, taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) }]]) }),
      ),
    ).rejects.toThrow(/linked counter/);
    expect(await db.tasks.get('task-a')).toMatchObject({ type: TaskType.COUNTING, version: 1 });
    expect(await db.compoundChildren.count()).toBe(0);
  });

  it('a linked counter still accepts a same-type (title) edit', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, sharedCounterId: 'root-1' }));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COUNTING, title: 'Renamed' }]]),
      }),
    );
    expect((await db.tasks.get('task-a'))?.title).toBe('Renamed');
  });

  it('convert A then Remove A → Save converts nothing', async () => {
    await seedPlaced(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await db.boardTasks.add(seedPlacement('bt-b', 'task-b', 0, 1));
    await commitSquareEdits(
      baseInput({
        removedBoardTaskIds: ['bt-a'],
        cells: [cell({ cellId: 'bt-b', taskId: 'task-b', row: 0, col: 1 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) }]]),
      }),
    );
    expect(await db.tasks.get('task-a')).toMatchObject({ type: TaskType.NORMAL, version: 1 });
    expect(await db.compoundChildren.count()).toBe(0);
    expect(await db.tasks.count()).toBe(2);
  });

  it('convert A then Replace A with B → nothing happens to A', async () => {
    await seedPlaced(seedTask('task-a'));
    await db.tasks.add(seedTask('task-b'));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-b', row: 0, col: 0, originalTaskId: 'task-a' })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) }]]),
      }),
    );
    expect(await db.tasks.get('task-a')).toMatchObject({ type: TaskType.NORMAL, version: 1 });
    expect(await db.compoundChildren.count()).toBe(0);
    expect((await db.boardTasks.get('bt-a'))?.taskId).toBe('task-b');
  });

  it('rename-only on a stored 1-child compound saves (no structure submitted)', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COMPOUND, operator: OperatorType.AND }));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, title: 'Renamed', compound: undefined }]]),
      }),
    );
    expect(await db.tasks.get('task-a')).toMatchObject({ type: TaskType.COMPOUND, title: 'Renamed' });
  });

  it('conversion clears currentCount (iOS-aligned)', async () => {
    await seedPlaced(seedTask('task-a', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, currentCount: 3 }));
    await commitSquareEdits(
      baseInput({
        cells: [cell({ cellId: 'bt-a', taskId: 'task-a', row: 0, col: 0 })],
        taskOverrides: new Map([['task-a', { type: TaskType.COMPOUND, compound: compoundPatch([sub('One'), sub('Two')]) }]]),
      }),
    );
    expect((await db.tasks.get('task-a'))?.currentCount).toBeUndefined();
  });
});
