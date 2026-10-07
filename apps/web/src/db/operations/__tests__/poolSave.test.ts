import { afterEach, describe, expect, it } from 'vitest';
import { OperatorType, TaskType, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { emptyPatch, type ChildPatch, type TaskEditPatch } from '../../taskEditPatch';
import { savePoolWithStagedEdits } from '../poolSave';
import { StagedEditError, applyStagedTaskEditsForWizardPersist } from '../wizardBoard';

/**
 * The pool save applies staged inline edits STRICTLY (iOS parity): a missing
 * task, an invalid patch, or a failed compound link guard throws inside the
 * transaction so the whole save rolls back — the pool row is never written
 * while the user's edit is dropped. The wizard persist stays lenient.
 */

const USER = 'user-1';
const NOW = '2026-07-01T00:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: id,
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

function child(over: Partial<ChildPatch>): ChildPatch {
  return {
    id: 'x',
    childTaskId: null,
    title: '',
    isCounting: false,
    action: '',
    goal: '',
    unit: '',
    countKind: 'discrete',
    markedDeleted: false,
    childType: TaskType.NORMAL,
    ...over,
  };
}

afterEach(async () => {
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.pools.clear();
  await db.syncQueue.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.taskEvents.clear();
});

async function expectRolledBack(
  run: () => Promise<unknown>,
  reason: StagedEditError['reason'],
  untouched: { id: string; title: string },
): Promise<void> {
  await expect(run()).rejects.toMatchObject({ name: 'StagedEditError', reason });
  expect(await db.pools.count()).toBe(0);
  expect((await db.tasks.get(untouched.id))?.title).toBe(untouched.title);
  expect(await db.syncQueue.count()).toBe(0);
}

describe('savePoolWithStagedEdits — strict staged edits', () => {
  it('applies a valid staged edit together with the pool', async () => {
    await db.tasks.add(task('a', { title: 'Old' }));
    const pool = await savePoolWithStagedEdits(USER, undefined, {
      name: 'P',
      taskIds: ['a'],
      stagedEdits: new Map([['a', emptyPatch('New')]]),
    });
    expect(pool.taskIds).toEqual(['a']);
    expect((await db.tasks.get('a'))?.title).toBe('New');
  });

  it('an invalid patch -> pool row absent, task unchanged, sync queue empty', async () => {
    await db.tasks.add(task('a', { title: 'Old' }));
    await expectRolledBack(
      () =>
        savePoolWithStagedEdits(USER, undefined, {
          name: 'P',
          taskIds: ['a'],
          stagedEdits: new Map([['a', emptyPatch('   ')]]),
        }),
      'invalid-patch',
      { id: 'a', title: 'Old' },
    );
  });

  it('a staged edit whose task vanished -> pool row absent, nothing written', async () => {
    await db.tasks.add(task('a', { title: 'Old' }));
    await expectRolledBack(
      () =>
        savePoolWithStagedEdits(USER, undefined, {
          name: 'P',
          taskIds: ['a', 'gone'],
          stagedEdits: new Map([
            ['a', emptyPatch('New')],
            ['gone', emptyPatch('Ghost')],
          ]),
        }),
      'missing-task',
      { id: 'a', title: 'Old' },
    );
  });

  it('a failed compound link guard -> pool row absent, compound unchanged, sync queue empty', async () => {
    await db.tasks.bulkAdd([
      task('c', { title: 'Routine', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task('k1', { title: 'One' }),
    ]);
    const patch: TaskEditPatch = {
      ...emptyPatch('Renamed'),
      operator: OperatorType.AND,
      children: [
        child({ id: 'k1', childTaskId: 'k1', title: 'One' }),
        // Names a Task that does not exist -> the link guard refuses it.
        child({ id: 'nope', childTaskId: 'nope', title: 'Ghost' }),
      ],
    };
    await expectRolledBack(
      () =>
        savePoolWithStagedEdits(USER, undefined, {
          name: 'P',
          taskIds: ['c'],
          stagedEdits: new Map([['c', patch]]),
        }),
      'link-guard',
      { id: 'c', title: 'Routine' },
    );
  });

  it('prunes a removed row\'s staged edit (id not in taskIds) so it never applies', async () => {
    await db.tasks.bulkAdd([task('a', { title: 'A' }), task('b', { title: 'B' })]);
    await savePoolWithStagedEdits(USER, undefined, {
      name: 'P',
      taskIds: ['a'],
      stagedEdits: new Map([['b', emptyPatch('Edited but removed')]]),
    });
    expect((await db.tasks.get('b'))?.title).toBe('B');
  });
});

describe('applyStagedTaskEditsForWizardPersist — default stays lenient', () => {
  it('silently skips an invalid patch and a missing task', async () => {
    await db.tasks.add(task('a', { title: 'Old' }));
    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      () =>
        applyStagedTaskEditsForWizardPersist(
          new Map([
            ['a', emptyPatch('')],
            ['gone', emptyPatch('x')],
          ]),
          new Set(),
          NOW,
        ),
    );
    expect((await db.tasks.get('a'))?.title).toBe('Old');
  });
});
