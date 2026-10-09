import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../../db/internal';
import { saveTaskEdit } from '../../../db/operations/compoundStructureEdit';
import {
  counterEditDedupePool,
  counterEditIdentityChanged,
  counterEditSubmit,
  seedCounterEditDraft,
} from '../counterEditModel';

const T0 = '2026-10-01T00:00:00.000Z';

const root = (over: Partial<Task> = {}): Task =>
  ({
    id: 'root', userId: 'u1', title: 'Run miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    isCounter: true, countKind: 'discrete', currentCount: 12, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(),
    db.compoundChildren.clear(), db.syncQueue.clear(),
  ]);
});

describe('seedCounterEditDraft', () => {
  it('prefills verb (action), noun (unit) and kind from the root', () => {
    expect(seedCounterEditDraft(root({ countKind: 'continuous' }))).toEqual({
      verb: 'Run', noun: 'miles', kind: 'continuous',
    });
  });
});

describe('counterEditSubmit', () => {
  it('an auto-titled root: title follows the new verb / noun; kind sent only when changed', () => {
    expect(counterEditSubmit(root(), { verb: 'Jog', noun: 'km', kind: 'discrete' })).toEqual({
      title: 'Jog km', action: 'Jog', unit: 'km',
    });
    expect(counterEditSubmit(root(), { verb: 'Run', noun: 'miles', kind: 'continuous' })).toEqual({
      title: 'Run miles', action: 'Run', unit: 'miles', countKind: 'continuous',
    });
  });

  it('a blank verb submits as "Do" (the create sheet rule)', () => {
    expect(counterEditSubmit(root(), { verb: '  ', noun: 'push-ups', kind: 'discrete' })).toMatchObject({
      action: 'Do', unit: 'push-ups', title: 'Push-ups',
    });
  });

  it('a custom title is kept verbatim', () => {
    expect(counterEditSubmit(root({ title: 'Morning miles' }), { verb: 'Jog', noun: 'miles', kind: 'discrete' }))
      .toMatchObject({ title: 'Morning miles', action: 'Jog' });
  });

  it('a board-born auto-titled root regenerates with its (switched) goal', () => {
    const r = root({ isCounter: false, title: 'Run 2.6 miles', maxCount: 2.6, countKind: 'continuous' });
    expect(counterEditSubmit(r, { verb: 'Run', noun: 'miles', kind: 'discrete' }).title).toBe('Run 3 miles');
  });
});

describe('counterEditIdentityChanged / counterEditDedupePool', () => {
  it('detects a verb / noun change and drops the counter family from the dedupe pool', () => {
    const r = root();
    expect(counterEditIdentityChanged(r, { verb: 'Run', noun: 'miles', kind: 'continuous' })).toBe(false);
    expect(counterEditIdentityChanged(r, { verb: 'Run', noun: 'km', kind: 'discrete' })).toBe(true);
    const copy = root({ id: 'copy', isCounter: false, sharedCounterId: 'root' });
    const other = root({ id: 'other', action: 'Do', unit: 'push-ups' });
    expect(counterEditDedupePool(r, [r, copy, other]).map((t) => t.id)).toEqual(['other']);
  });
});

describe('the counter sheet save goes through saveTaskEdit (the Task Detail write)', () => {
  it('rename + kind switch reach the root and its live copy', async () => {
    await db.tasks.add(root());
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Run 10 miles', currentCount: 0 }));

    await saveTaskEdit('root', counterEditSubmit(root(), { verb: 'Jog', noun: 'miles', kind: 'continuous' }));

    expect(await db.tasks.get('root')).toMatchObject({ title: 'Jog miles', action: 'Jog', countKind: 'continuous', type: TaskType.COUNTING });
    expect(await db.tasks.get('copy')).toMatchObject({ action: 'Jog', countKind: 'continuous', title: 'Jog 10 miles' });
  });
});
