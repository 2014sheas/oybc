import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  SyncOperationType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { childPatchFromTask, newChildPatch, type ChildPatch, type TaskEditPatch } from '../../taskEditPatch';
import {
  CompoundEditValidationError,
  editCompoundStructure,
  saveTaskEdit,
} from '../compoundStructureEdit';
import { updateTaskAndCascade } from '../tasks.crud';
import { applyStagedTaskEditsForWizardPersist } from '../wizardBoard';

/**
 * Compound Task Editing After Creation (Task 1, web) — the standalone
 * Task-Detail save for a compound's rule + sub-tasks, its router, and the
 * `updateTaskAndCascade` transaction-scope fix (D9).
 *
 * Fixture: compound P = AND(A, B); A has an in-window completion event, B
 * does not — so P is incomplete under AND and complete under OR. Board X
 * places P at (0,0) and a plain task Q at (0,1); board Y places A directly.
 */

const USER = 'u1';
const START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';

function uuid(n: number): string {
  return `60000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

const P_ID = uuid(1);
const A_ID = uuid(2);
const B_ID = uuid(3);
const Q_ID = uuid(4);
const X_ID = uuid(10);
const Y_ID = uuid(11);
const S_ID = uuid(12);

function makeTask(over: Partial<Task>): Task {
  return {
    id: 'unset',
    userId: USER,
    title: 'unset',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeBoard(over: Partial<Board>): Board {
  return {
    id: 'unset',
    userId: USER,
    name: 'Board',
    status: BoardStatus.ACTIVE,
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
    ...over,
  };
}

function makePlacement(id: string, boardId: string, taskId: string, row: number, col: number): BoardTask {
  return {
    id,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function makeLink(id: string, compoundTaskId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function completionEvent(taskId: string): TaskEvent {
  return {
    id: `${taskId}-ev`,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
}

function structureFor(
  parent: { title: string; operator?: OperatorType; threshold?: number },
  children: ChildPatch[],
): TaskEditPatch {
  return {
    title: parent.title,
    action: '',
    goal: '',
    unit: '',
    children,
    operator: parent.operator,
    threshold: parent.threshold,
  };
}

let P: Task;
let A: Task;
let B: Task;
let Q: Task;

beforeEach(async () => {
  P = makeTask({ id: P_ID, title: 'P', type: TaskType.COMPOUND, operator: OperatorType.AND });
  A = makeTask({ id: A_ID, title: 'A' });
  B = makeTask({ id: B_ID, title: 'B' });
  Q = makeTask({ id: Q_ID, title: 'Q' });
  await db.tasks.bulkAdd([P, A, B, Q]);
  await db.compoundChildren.bulkAdd([
    makeLink(uuid(20), P_ID, A_ID, 0),
    makeLink(uuid(21), P_ID, B_ID, 1),
  ]);
  await db.boards.bulkAdd([
    makeBoard({ id: X_ID, name: 'X' }),
    makeBoard({ id: Y_ID, name: 'Y' }),
  ]);
  await db.boardTasks.bulkAdd([
    makePlacement(uuid(30), X_ID, P_ID, 0, 0),
    makePlacement(uuid(31), X_ID, Q_ID, 0, 1),
    makePlacement(uuid(32), Y_ID, A_ID, 0, 0),
  ]);
  await db.taskEvents.add(completionEvent(A_ID));
});

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

const keepAB = (): ChildPatch[] => [childPatchFromTask(A), childPatchFromTask(B)];

describe('editCompoundStructure — standalone Task Detail save', () => {
  it('changes the rule and re-derives a placed board immediately (Review Focus 1)', async () => {
    await editCompoundStructure(P_ID, structureFor({ title: 'P', operator: OperatorType.OR }, keepAB()));
    const p = await db.tasks.get(P_ID);
    expect(p?.operator).toBe(OperatorType.OR);
    expect(p?.version).toBe(P.version + 1);
    // Under OR, A's in-window completion completes P → X counts one cell.
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(1);

    // And back to AND → B still undone → 0.
    await editCompoundStructure(P_ID, structureFor({ title: 'P', operator: OperatorType.AND }, keepAB()));
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(0);
  });

  it('M_OF_N stores the chosen threshold, rejects one above the kept child count, and AND clears it', async () => {
    const C = makeTask({ id: uuid(5), title: 'C' });
    await db.tasks.add(C);
    await db.compoundChildren.add(makeLink(uuid(22), P_ID, C.id, 2));
    await db.taskEvents.add(completionEvent(C.id));
    const threeKids = (): ChildPatch[] => [...keepAB(), childPatchFromTask(C)];

    // 2 of 3 with A + C done → P complete on X.
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.M_OF_N, threshold: 2 }, threeKids()),
    );
    let p = await db.tasks.get(P_ID);
    expect(p?.operator).toBe(OperatorType.M_OF_N);
    expect(p?.threshold).toBe(2);
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(1);

    // 5 of 3 is refused by validatePatch before any write (the clamp in
    // applyPatchToTask is unreachable on this validated path).
    await expect(
      editCompoundStructure(
        P_ID,
        structureFor({ title: 'P', operator: OperatorType.M_OF_N, threshold: 5 }, threeKids()),
      ),
    ).rejects.toThrow('Choose how many sub-tasks must complete.');
    expect((await db.tasks.get(P_ID))?.threshold).toBe(2);

    // Switching to AND drops the threshold.
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.AND, threshold: 2 }, threeKids()),
    );
    p = await db.tasks.get(P_ID);
    expect(p?.operator).toBe(OperatorType.AND);
    expect(p?.threshold).toBeUndefined();
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(0);
  });

  it('renames a child globally and enqueues a tasks UPDATE for it (Review Focus 4)', async () => {
    const renamed = { ...childPatchFromTask(A), title: 'A renamed' };
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.AND }, [renamed, childPatchFromTask(B)]),
    );
    const a = await db.tasks.get(A_ID);
    expect(a?.title).toBe('A renamed');
    expect(a?.version).toBe(A.version + 1);
    const rows = (await db.syncQueue.toArray()).filter((r) => r.entityId === A_ID);
    expect(
      rows.some((r) => r.entityType === 'tasks' && r.operationType === SyncOperationType.UPDATE),
    ).toBe(true);
  });

  it('removing a child unlinks only — a child placed elsewhere survives (Review Focus 2)', async () => {
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.AND }, [
        childPatchFromTask(B),
        newChildPatch(false), // blank: dropped on save
        { ...newChildPatch(false), title: 'C' },
      ]),
    );
    const links = await db.compoundChildren.where('compoundTaskId').equals(P_ID).toArray();
    expect(links.find((l) => l.childTaskId === A_ID)?.isDeleted).toBe(true);
    expect((await db.tasks.get(A_ID))?.isDeleted).toBe(false);
    const aPlacements = (await db.boardTasks.where('taskId').equals(A_ID).toArray()).filter(
      (bt) => !bt.isDeleted,
    );
    expect(aPlacements).toHaveLength(1); // still on Y
    expect(aPlacements[0].boardId).toBe(Y_ID);

    const kept = links.filter((l) => !l.isDeleted).sort((l, r) => l.childIndex - r.childIndex);
    expect(kept).toHaveLength(2); // B + new C; the blank row was dropped
    expect(kept[0].childTaskId).toBe(B_ID);
    expect(kept[0].childIndex).toBe(0); // B re-indexed from 1 → 0
    const cTasks = (await db.tasks.toArray()).filter((t) => t.title === 'C');
    expect(cTasks).toHaveLength(1);
    expect(kept[1].childTaskId).toBe(cTasks[0].id);
    expect(cTasks[0].userId).toBe(USER);
  });

  it('refuses fewer than two sub-tasks with the unified message and writes nothing (Review Focus 3)', async () => {
    const before = {
      p: await db.tasks.get(P_ID),
      links: await db.compoundChildren.toArray(),
      x: await db.boards.get(X_ID),
      q: await db.syncQueue.count(),
    };
    const oneChild = structureFor({ title: 'P', operator: OperatorType.AND }, [childPatchFromTask(A)]);
    await expect(editCompoundStructure(P_ID, oneChild)).rejects.toBeInstanceOf(CompoundEditValidationError);
    await expect(editCompoundStructure(P_ID, oneChild)).rejects.toThrow(
      'A compound task needs at least two sub-tasks.',
    );
    expect(await db.tasks.get(P_ID)).toEqual(before.p);
    expect(await db.compoundChildren.toArray()).toEqual(before.links);
    expect(await db.boards.get(X_ID)).toEqual(before.x);
    expect(await db.syncQueue.count()).toBe(before.q);
  });

  it('a sealed board containing the compound keeps its snapshot (Review Focus 5)', async () => {
    const sealed = makeBoard({
      id: S_ID,
      name: 'Sealed',
      sealedAt: IN_WINDOW,
      sealedCompletedCells: [4],
      completedTasks: 1,
    });
    await db.boards.add(sealed);
    await db.boardTasks.add(makePlacement(uuid(33), S_ID, P_ID, 0, 0));

    await editCompoundStructure(P_ID, structureFor({ title: 'P', operator: OperatorType.OR }, keepAB()));

    expect(await db.boards.get(S_ID)).toEqual(sealed);
    expect((await db.syncQueue.toArray()).filter((r) => r.entityId === S_ID).length).toBe(0);
    // …while the live board X did re-derive in the same save.
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(1);
  });

  it('description rides along in the same version bump; a stored window is left untouched', async () => {
    await db.tasks.update(P_ID, {
      timeframe: Timeframe.WEEKLY,
      startDate: '2026-07-06T00:00:00.000',
      endDate: '2026-07-12T23:59:59.999',
    });
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P2', operator: OperatorType.AND }, keepAB()),
      { description: '  desc  ' },
    );
    const p = await db.tasks.get(P_ID);
    expect(p?.title).toBe('P2');
    expect(p?.description).toBe('desc');
    // No edit path writes a task's own window (it may be a derived row's
    // stamped completion window) — the stored one survives the save.
    expect(p?.timeframe).toBe(Timeframe.WEEKLY);
    expect(p?.startDate).toBe('2026-07-06T00:00:00.000');
    expect(p?.endDate).toBe('2026-07-12T23:59:59.999');
    expect(p?.version).toBe(P.version + 1);
    const parentRows = (await db.syncQueue.toArray()).filter(
      (r) => r.entityId === P_ID && r.entityType === 'tasks',
    );
    expect(parentRows).toHaveLength(1);
    expect((JSON.parse(parentRows[0].payload) as Task).description).toBe('desc');
  });

  it('a non-compound task is rejected', async () => {
    await expect(editCompoundStructure(Q_ID, structureFor({ title: 'Q' }, []))).rejects.toThrow(
      /not a compound/i,
    );
  });

  it('bumps from the stored version (seeded at 7 → 8)', async () => {
    await db.tasks.update(P_ID, { version: 7 });
    await editCompoundStructure(P_ID, structureFor({ title: 'P', operator: OperatorType.OR }, keepAB()));
    expect((await db.tasks.get(P_ID))?.version).toBe(8);
  });

  it('writes from a row re-read INSIDE the transaction, not the stale pre-read (concurrent write preserved)', async () => {
    // Simulate a sync pull / other-tab write landing between the op's
    // pre-read and its transaction: the FIRST `db.tasks.get` (the pre-read)
    // returns the row as it was, while the DB already holds the newer write.
    const stale = await db.tasks.get(P_ID);
    await db.tasks.update(P_ID, { description: 'changed', version: 9 });
    // (Cast: Dexie's `get` returns a `PromiseExtended`; a plain promise is
    // all the op awaits.)
    const getSpy = vi
      .spyOn(db.tasks, 'get')
      .mockImplementationOnce((() => Promise.resolve(stale)) as unknown as typeof db.tasks.get);
    try {
      await editCompoundStructure(P_ID, structureFor({ title: 'P', operator: OperatorType.OR }, keepAB()));
    } finally {
      getSpy.mockRestore();
    }
    const p = await db.tasks.get(P_ID);
    expect(p?.version).toBe(10);
    expect(p?.description).toBe('changed');
    expect(p?.operator).toBe(OperatorType.OR);
  });

  it('a soft-deleted compound is rejected', async () => {
    await db.tasks.update(P_ID, { isDeleted: true });
    await expect(editCompoundStructure(P_ID, structureFor({ title: 'P' }, keepAB()))).rejects.toThrow(
      /not found/,
    );
  });

  it('a missing or deleted task is rejected', async () => {
    await expect(editCompoundStructure('nope', structureFor({ title: 'x' }, keepAB()))).rejects.toThrow(
      /not found/i,
    );
  });
});

describe('editCompoundStructure — linking an EXISTING library task as a sub-task (Task 6)', () => {
  const L_ID = uuid(6);
  let L: Task;

  beforeEach(async () => {
    // L: a standalone library task with an in-window completion.
    L = makeTask({ id: L_ID, title: 'L' });
    await db.tasks.add(L);
    await db.taskEvents.add(completionEvent(L_ID));
  });

  const snapshot = async () => ({
    p: await db.tasks.get(P_ID),
    tasks: await db.tasks.toArray(),
    links: await db.compoundChildren.toArray(),
    x: await db.boards.get(X_ID),
    q: await db.syncQueue.count(),
  });

  it('links an existing task: link CREATE enqueued, task row untouched, cascade re-derives the board', async () => {
    // OR(B, L): B undone, L done → P complete ONLY if the L link exists.
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(0);
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.OR }, [childPatchFromTask(B), childPatchFromTask(L)]),
    );

    const live = (await db.compoundChildren.where('compoundTaskId').equals(P_ID).toArray())
      .filter((l) => !l.isDeleted)
      .sort((a, b) => a.childIndex - b.childIndex);
    expect(live.map((l) => [l.childTaskId, l.childIndex])).toEqual([
      [B_ID, 0],
      [L_ID, 1],
    ]);
    const lLink = live[1];
    expect(lLink.version).toBe(1);

    const rows = await db.syncQueue.toArray();
    expect(
      rows.filter(
        (r) =>
          r.entityType === 'compoundChildren' &&
          r.entityId === lLink.id &&
          r.operationType === SyncOperationType.CREATE,
      ),
    ).toHaveLength(1);
    // The picked task itself is not rewritten or enqueued.
    expect(await db.tasks.get(L_ID)).toEqual(L);
    expect(rows.filter((r) => r.entityType === 'tasks' && r.entityId === L_ID)).toHaveLength(0);
    // The board placing P re-derived with L counted.
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(1);
  });

  it('linking an existing counting task with no stored action leaves its row untouched', async () => {
    // action undefined ('' in the editor) must not read as a change.
    const C = makeTask({ id: uuid(40), title: 'Read 10 pages', type: TaskType.COUNTING, maxCount: 10, unit: 'pages' });
    await db.tasks.add(C);
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.AND }, [...keepAB(), childPatchFromTask(C)]),
    );
    expect(await db.tasks.get(C.id)).toEqual(C);
    expect((await db.syncQueue.toArray()).filter((r) => r.entityType === 'tasks' && r.entityId === C.id)).toHaveLength(0);
    const live = (await db.compoundChildren.where('compoundTaskId').equals(P_ID).toArray()).filter((l) => !l.isDeleted);
    expect(live.map((l) => l.childTaskId)).toContain(C.id);
  });

  it('allows linking a nested compound that forms no loop', async () => {
    const N = makeTask({ id: uuid(7), title: 'N', type: TaskType.COMPOUND, operator: OperatorType.AND });
    await db.tasks.add(N);
    await db.compoundChildren.add(makeLink(uuid(23), N.id, Q_ID, 0));
    await editCompoundStructure(
      P_ID,
      structureFor({ title: 'P', operator: OperatorType.AND }, [...keepAB(), childPatchFromTask(N)]),
    );
    const live = (await db.compoundChildren.where('compoundTaskId').equals(P_ID).toArray()).filter(
      (l) => !l.isDeleted,
    );
    expect(live.map((l) => l.childTaskId).sort()).toEqual([A_ID, B_ID, N.id].sort());
  });

  const refusals: Array<[string, () => Promise<ChildPatch[]>, string]> = [
    ['self', async () => [...keepAB(), childPatchFromTask(P)], 'A compound can’t contain itself.'],
    [
      'duplicate (the same library task picked twice)',
      async () => [childPatchFromTask(A), childPatchFromTask(L), { ...childPatchFromTask(L), id: 'dup-row' }],
      'That task is already a sub-task here.',
    ],
    [
      'achievement',
      async () => {
        const W = makeTask({ id: uuid(8), title: 'W', type: TaskType.ACHIEVEMENT });
        await db.tasks.add(W);
        return [...keepAB(), childPatchFromTask(W)];
      },
      'Achievements can’t be sub-tasks.',
    ],
    [
      'deleted',
      async () => {
        await db.tasks.update(L_ID, { isDeleted: true });
        return [...keepAB(), childPatchFromTask(L)];
      },
      'That task was deleted.',
    ],
    [
      'goal-less counter',
      async () => {
        const G = makeTask({ id: uuid(9), title: 'G', type: TaskType.COUNTING, isCounter: true });
        await db.tasks.add(G);
        return [...keepAB(), childPatchFromTask(G)];
      },
      'Counters without a goal can’t be sub-tasks.',
    ],
    [
      'loop (L already contains P)',
      async () => {
        await db.tasks.update(L_ID, { type: TaskType.COMPOUND, operator: OperatorType.AND });
        await db.compoundChildren.add(makeLink(uuid(24), L_ID, P_ID, 0));
        return [...keepAB(), childPatchFromTask({ ...L, type: TaskType.COMPOUND })];
      },
      'That would create a loop — it already contains this compound.',
    ],
  ];

  it.each(refusals)('refuses %s before any write', async (_name, build, message) => {
    const children = await build();
    const before = await snapshot();
    const structure = structureFor({ title: 'P2', operator: OperatorType.OR }, children);
    await expect(editCompoundStructure(P_ID, structure)).rejects.toBeInstanceOf(CompoundEditValidationError);
    await expect(editCompoundStructure(P_ID, structure)).rejects.toThrow(message);
    expect(await snapshot()).toEqual(before);
  });

  it('wizard staged path: an ineligible link skips the whole edit silently; an eligible one links', async () => {
    const tables = [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];
    const before = await snapshot();
    await db.transaction('rw', tables, () =>
      applyStagedTaskEditsForWizardPersist(
        new Map([[P_ID, structureFor({ title: 'P2', operator: OperatorType.OR }, [...keepAB(), childPatchFromTask(P)])]]),
        new Set(),
        IN_WINDOW,
      ),
    );
    expect(await snapshot()).toEqual(before); // not half-applied (title / rule untouched too)

    await db.transaction('rw', tables, () =>
      applyStagedTaskEditsForWizardPersist(
        new Map([[P_ID, structureFor({ title: 'P', operator: OperatorType.OR }, [childPatchFromTask(B), childPatchFromTask(L)])]]),
        new Set(),
        IN_WINDOW,
      ),
    );
    const live = (await db.compoundChildren.where('compoundTaskId').equals(P_ID).toArray()).filter(
      (l) => !l.isDeleted,
    );
    expect(live.map((l) => l.childTaskId).sort()).toEqual([B_ID, L_ID].sort());
  });
});

describe('saveTaskEdit — router', () => {
  it('routes a compound submit with `compound` to the structure edit and a normal submit to updateTaskAndCascade', async () => {
    await saveTaskEdit(Q_ID, { title: 'Q renamed' });
    expect((await db.tasks.get(Q_ID))?.title).toBe('Q renamed');

    await saveTaskEdit(P_ID, {
      title: 'P',
      compound: structureFor({ title: 'P', operator: OperatorType.OR }, keepAB()),
    });
    expect((await db.tasks.get(P_ID))?.operator).toBe(OperatorType.OR);
    expect((await db.boards.get(X_ID))?.completedTasks).toBe(1);
  });

  it('a compound submit WITHOUT `compound` only updates basic fields and leaves the rule and links alone', async () => {
    const linksBefore = await db.compoundChildren.toArray();
    await saveTaskEdit(P_ID, { title: 'P', description: 'hello' });
    const p = await db.tasks.get(P_ID);
    expect(p?.description).toBe('hello');
    expect(p?.operator).toBe(OperatorType.AND);
    expect(await db.compoundChildren.toArray()).toEqual(linksBefore);
  });

  it('a present-but-undefined description clears it on BOTH routes (the sheet\'s clear gesture)', async () => {
    await db.tasks.update(P_ID, { description: 'old' });
    await db.tasks.update(Q_ID, { description: 'old' });

    await saveTaskEdit(Q_ID, { title: 'Q', description: undefined });
    await saveTaskEdit(P_ID, {
      title: 'P',
      description: undefined,
      compound: structureFor({ title: 'P', operator: OperatorType.AND }, keepAB()),
    });
    expect((await db.tasks.get(Q_ID))?.description).toBeUndefined();
    expect((await db.tasks.get(P_ID))?.description).toBeUndefined();
  });
});

describe('updateTaskAndCascade — transaction scope (D9)', () => {
  it('cascade completes when the changed task sits on a board (taskEvents inside the scope)', async () => {
    await db.taskEvents.add(completionEvent(Q_ID));
    await expect(updateTaskAndCascade(Q_ID, { title: 'Q2' })).resolves.toBeUndefined();
    expect((await db.tasks.get(Q_ID))?.title).toBe('Q2');
    const x = await db.boards.get(X_ID);
    expect(x?.version).toBe(2); // the cascade re-derived X…
    expect(x?.completedTasks).toBe(1); // …counting Q's in-window completion.
  });
});
