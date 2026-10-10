import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type CounterSettingsDraft, type Task } from '@oybc/shared';
import { db } from '../../../db/internal';
import { saveTaskEdit } from '../../../db/operations/compoundStructureEdit';
import {
  counterEditDedupePool,
  counterEditIdentityChanged,
  counterEditSubmit,
  seedCounterEditDraft,
} from '../counterEditModel';
import { createCounterTask } from '../../../db/operations/tasks';
import { resolveCreditedCounterName } from '../../boardPlaySharedCounterUtils';

const T0 = '2026-10-01T00:00:00.000Z';

const root = (over: Partial<Task> = {}): Task =>
  ({
    id: 'root', userId: 'u1', title: 'Run miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    isCounter: true, countKind: 'discrete', currentCount: 12, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

/** A draft with nothing typed in the optional settings. */
const UNSET: CounterSettingsDraft = { name: '', singular: '', plural: '', goals: {} };
const draft = (verb: string, noun: string, kind: 'discrete' | 'continuous' | 'duration', settings: Partial<CounterSettingsDraft> = {}) =>
  ({ verb, noun, kind, settings: { ...UNSET, ...settings } });

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(),
    db.compoundChildren.clear(), db.syncQueue.clear(),
  ]);
});

describe('seedCounterEditDraft', () => {
  it('prefills verb (action), noun (unit), kind and the stored settings from the root', () => {
    expect(seedCounterEditDraft(root({ countKind: 'continuous' }))).toEqual({
      verb: 'Run', noun: 'miles', kind: 'continuous', settings: UNSET,
    });
    expect(
      seedCounterEditDraft(root({ counterName: 'Running', titleTemplatePlural: 'Jog #N miles', timeframeGoals: { weekly: 20 } })).settings,
    ).toEqual({ name: 'Running', singular: '', plural: 'Jog #N miles', goals: { weekly: 20 } });
  });
});

describe('counterEditSubmit', () => {
  it('an auto-titled root: title follows the new verb / noun; kind sent only when changed', () => {
    expect(counterEditSubmit(root(), draft('Jog', 'km', 'discrete'))).toEqual({
      title: 'Jog km', action: 'Jog', unit: 'km',
    });
    expect(counterEditSubmit(root(), draft('Run', 'miles', 'continuous'))).toEqual({
      title: 'Run miles', action: 'Run', unit: 'miles', countKind: 'continuous',
    });
  });

  it('the verb is required — a blank verb is submitted as typed (trimmed), never substituted', () => {
    expect(counterEditSubmit(root(), draft('  ', 'push-ups', 'discrete'))).toMatchObject({ action: '', unit: 'push-ups' });
  });

  it('a custom title is kept verbatim', () => {
    expect(counterEditSubmit(root({ title: 'Morning miles' }), draft('Jog', 'miles', 'discrete')))
      .toMatchObject({ title: 'Morning miles', action: 'Jog' });
  });

  it('a counting task other boards link to, auto-titled, regenerates with its (switched) goal', () => {
    const r = root({ isCounter: false, title: 'Run 2.6 miles', maxCount: 2.6, countKind: 'continuous' });
    expect(counterEditSubmit(r, draft('Run', 'miles', 'discrete')).title).toBe('Run 3 miles');
  });

  it('settings: only the keys whose stored value changed are sent; a clear is present-undefined', () => {
    const r = root({ counterName: 'Running', titleTemplatePlural: 'Jog #N miles', timeframeGoals: { weekly: 20 } });
    // Nothing changed → no settings keys at all.
    const same = counterEditSubmit(r, draft('Run', 'miles', 'discrete', { name: 'Running', plural: 'Jog #N miles', goals: { weekly: 20 } }));
    expect(Object.keys(same).sort()).toEqual(['action', 'title', 'unit']);
    expect(same.title).toBe('Running');

    // Name cleared (→ derived), singular typed, weekly changed + daily added.
    const changed = counterEditSubmit(
      r,
      draft('Run', 'miles', 'discrete', { name: '', singular: 'Jog #N mile', plural: 'Jog #N miles', goals: { weekly: 25, daily: 4 } }),
    );
    expect('counterName' in changed).toBe(true);
    expect(changed.counterName).toBeUndefined();
    expect(changed.titleTemplateSingular).toBe('Jog #N mile');
    expect('titleTemplatePlural' in changed).toBe(false);
    expect(changed.timeframeGoals).toEqual({ weekly: 25 });
    // The goal-less root's title is its name — now the derived one.
    expect(changed.title).toBe('Run miles');
  });

  it('a typed name equal to the derived default stores absent; the title follows the new name', () => {
    const r = root({ counterName: 'Running' });
    const out = counterEditSubmit(r, draft('Run', 'miles', 'discrete', { name: 'Run miles' }));
    expect('counterName' in out).toBe(true);
    expect(out.counterName).toBeUndefined();
    expect(out.title).toBe('Run miles');
    const renamed = counterEditSubmit(root(), draft('Run', 'miles', 'discrete', { name: 'Miles' }));
    expect(renamed).toMatchObject({ counterName: 'Miles', title: 'Miles' });
  });
});

describe('counterEditIdentityChanged / counterEditDedupePool', () => {
  it('detects a verb / noun change and drops the counter family from the dedupe pool', () => {
    const r = root();
    expect(counterEditIdentityChanged(r, { verb: 'Run', noun: 'miles' })).toBe(false);
    expect(counterEditIdentityChanged(r, { verb: 'Run', noun: 'km' })).toBe(true);
    expect(counterEditIdentityChanged(r, { verb: '', noun: 'miles' })).toBe(true);
    const copy = root({ id: 'copy', isCounter: false, sharedCounterId: 'root' });
    const other = root({ id: 'other', action: 'Do', unit: 'push-ups' });
    expect(counterEditDedupePool(r, [r, copy, other]).map((t) => t.id)).toEqual(['other']);
  });
});

describe('the counter sheet save goes through saveTaskEdit (the Task Detail write)', () => {
  it('rename + kind switch reach the root and its live copy', async () => {
    await db.tasks.add(root());
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Run 10 miles', currentCount: 0 }));

    await saveTaskEdit('root', counterEditSubmit(root(), draft('Jog', 'miles', 'continuous')));

    expect(await db.tasks.get('root')).toMatchObject({ title: 'Jog miles', action: 'Jog', countKind: 'continuous', type: TaskType.COUNTING });
    expect(await db.tasks.get('copy')).toMatchObject({ action: 'Jog', countKind: 'continuous', title: 'Jog 10 miles' });
  });

  it('the sheet submit stores typed templates + defaults and re-renders auto copies through them', async () => {
    await db.tasks.add(root());
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Run 10 miles', currentCount: 0 }));
    await db.tasks.add(root({ id: 'one', isCounter: false, sharedCounterId: 'root', maxCount: 1, title: 'Run 1 miles', currentCount: 0 }));

    await saveTaskEdit(
      'root',
      counterEditSubmit(root(), draft('Run', 'miles', 'discrete', { name: 'Running', singular: 'Jog #N mile', plural: 'Jog #N miles', goals: { weekly: 20 } })),
    );

    expect(await db.tasks.get('root')).toMatchObject({
      title: 'Running', counterName: 'Running', titleTemplateSingular: 'Jog #N mile', titleTemplatePlural: 'Jog #N miles', timeframeGoals: { weekly: 20 },
    });
    expect((await db.tasks.get('copy'))!.title).toBe('Jog 10 miles');
    expect((await db.tasks.get('one'))!.title).toBe('Jog 1 mile');
    expect(resolveCreditedCounterName((await db.tasks.get('root'))!)).toBe('Running');
  });

  it('clearing a setting in the sheet stores it absent and re-renders auto copies through the formula', async () => {
    const r = root({ counterName: 'Running', titleTemplatePlural: 'Jog #N miles', title: 'Running' });
    await db.tasks.add(r);
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Jog 10 miles', currentCount: 0 }));

    await saveTaskEdit('root', counterEditSubmit(r, draft('Run', 'miles', 'discrete')));

    const cleared = (await db.tasks.get('root'))!;
    expect('counterName' in cleared).toBe(false);
    expect('titleTemplatePlural' in cleared).toBe(false);
    expect(cleared.title).toBe('Run miles');
    expect((await db.tasks.get('copy'))!.title).toBe('Run 10 miles');
    expect(resolveCreditedCounterName(cleared)).toBe('Run miles');
  });

  it('the counter sheet edit keeps stored templates: an auto copy re-renders through them on a verb change', async () => {
    const r = root({ titleTemplatePlural: 'Run #N miles!' });
    await db.tasks.add(r);
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Run 10 miles!', currentCount: 0 }));
    await saveTaskEdit('root', counterEditSubmit(r, draft('Jog', 'miles', 'discrete', { plural: 'Run #N miles!' })));
    expect(await db.tasks.get('copy')).toMatchObject({ action: 'Jog', title: 'Run 10 miles!' });
    expect((await db.tasks.get('root'))!.titleTemplatePlural).toBe('Run #N miles!');
  });

  it('createCounterTask stores only the given settings; the goal-less title is the name', async () => {
    const t = await createCounterTask('u1', { action: 'Read', unit: 'books', settings: { counterName: '  Books ', titleTemplatePlural: '   ' } });
    const saved = (await db.tasks.get(t.id))!;
    expect(saved).toMatchObject({ title: 'Books', counterName: 'Books' });
    expect('titleTemplatePlural' in saved).toBe(false);
    expect('timeframeGoals' in saved).toBe(false);
  });
});
