import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, isWindowStampedDerived, type Task } from '@oybc/shared';
import {
  buildPendingLinkedCounter,
  counterMatchRowGoal,
  counterMatchRowName,
  isLinkedPendingPayload,
  isSharedCounterRoot,
} from '../quickAddCounterPlacement';
import { WizardQuickAddRow } from '../WizardQuickAddRow';

const T0 = '2026-10-01T00:00:00.000Z';
const task = (over: Partial<Task>): Task =>
  ({
    id: 'root', userId: 'u1', title: 'Books', type: TaskType.COUNTING, action: 'Read', unit: 'books', isCounter: true,
    currentCount: 412, isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

describe('isSharedCounterRoot', () => {
  it('a hub counter or a root with defaults; never a linked row / plain counter / other type', () => {
    expect(isSharedCounterRoot(task({}))).toBe(true);
    expect(isSharedCounterRoot(task({ isCounter: false, maxCount: 12, timeframeGoals: { weekly: 2 } }))).toBe(true);
    expect(isSharedCounterRoot(task({ isCounter: false, maxCount: 12 }))).toBe(false);
    expect(isSharedCounterRoot(task({ sharedCounterId: 'other' }))).toBe(false);
    expect(isSharedCounterRoot(task({ type: TaskType.NORMAL }))).toBe(false);
  });
});

describe('counterMatchRowGoal', () => {
  it('a timeframe default carries the board timeframe prefix; the root goal has none; nothing → null', () => {
    expect(counterMatchRowGoal(task({ timeframeGoals: { weekly: 2 } }), Timeframe.WEEKLY)).toEqual({ prefix: 'Weekly · ', value: '2 books' });
    expect(counterMatchRowGoal(task({ timeframeGoals: { weekly: 7 } }), Timeframe.DAILY)).toEqual({ prefix: 'Daily · ', value: '1 books' });
    expect(counterMatchRowGoal(task({ maxCount: 12 }), Timeframe.WEEKLY)).toEqual({ prefix: '', value: '12 books' });
    expect(counterMatchRowGoal(task({ maxCount: 12, timeframeGoals: { weekly: 2 } }), Timeframe.CUSTOM)).toEqual({ prefix: '', value: '12 books' });
    expect(counterMatchRowGoal(task({}), Timeframe.WEEKLY)).toBeNull();
    expect(counterMatchRowGoal(task({ timeframeGoals: { weekly: 2 } }), Timeframe.CUSTOM)).toBeNull();
  });

  it('formats with the counter\'s real kind', () => {
    expect(counterMatchRowGoal(task({ countKind: 'duration', unit: '', timeframeGoals: { weekly: 90 } }), Timeframe.WEEKLY))
      .toEqual({ prefix: 'Weekly · ', value: '1h 30m' });
    expect(counterMatchRowGoal(task({ countKind: 'continuous', unit: 'mi', timeframeGoals: { weekly: 10 } }), Timeframe.DAILY))
      .toEqual({ prefix: 'Daily · ', value: '1.5 mi' });
  });
});

describe('buildPendingLinkedCounter', () => {
  it('a linked counting task at the typed goal, titled through the root templates, with NO window fields', () => {
    const root = task({ titleTemplateSingular: 'Read #N book', titleTemplatePlural: 'Read #N novels', counterName: 'Books' });
    const { task: t, childTasks, childLinks } = buildPendingLinkedCounter(root, 3, 'u1', 'new', T0);
    expect(t).toMatchObject({
      id: 'new', userId: 'u1', type: TaskType.COUNTING, title: 'Read 3 novels', action: 'Read', unit: 'books', maxCount: 3,
      sharedCounterId: 'root', baseline: 412, currentCount: 0, createdInWizard: true, version: 1, isDeleted: false,
    });
    expect('countKind' in t).toBe(false);
    expect(t.startDate).toBeUndefined();
    expect(t.timeframe).toBeUndefined();
    expect(isWindowStampedDerived(t)).toBe(false);
    expect(childTasks).toEqual([]);
    expect(childLinks).toEqual([]);
    // With a host board window the row is stamped like `useLinkedCounterCreate`'s,
    // so wherever it IS persisted (a draft, a repeating board's members) it expires.
    const stamped = buildPendingLinkedCounter(root, 3, 'u1', 'n4', T0, {
      timeframe: Timeframe.WEEKLY, startDate: '2026-10-05T00:00:00.000', endDate: '2026-10-11T23:59:59.999',
    }).task;
    expect(stamped).toMatchObject({ timeframe: Timeframe.WEEKLY, startDate: '2026-10-05T00:00:00.000', endDate: '2026-10-11T23:59:59.999' });
    expect(isLinkedPendingPayload({ task: stamped, childTasks: [], childLinks: [] })).toBe(true);
    expect(isLinkedPendingPayload({ task: { ...stamped, sharedCounterId: undefined }, childTasks: [], childLinks: [] })).toBe(false);
    expect(buildPendingLinkedCounter(root, 1, 'u1', 'n2', T0).task.title).toBe('Read 1 book');
    expect(buildPendingLinkedCounter(task({ countKind: 'continuous', unit: 'mi' }), 2.5, 'u1', 'n3', T0).task).toMatchObject({ countKind: 'continuous', title: 'Read 2.5 mi' });
  });

  it('the row name is the counter display name', () => {
    expect(counterMatchRowName(task({ counterName: 'Reading' }))).toBe('Reading');
    expect(counterMatchRowName(task({ action: 'Do', unit: 'push-ups' }))).toBe('Push-ups');
  });
});

describe('WizardQuickAddRow match rows', () => {
  const render = (library: Task[], props: Partial<React.ComponentProps<typeof WizardQuickAddRow>> = {}): string =>
    renderToStaticMarkup(
      React.createElement(WizardQuickAddRow, {
        userId: 'u1', onTaskCreated: () => {}, libraryTasks: library, onExistingTaskPicked: () => {},
        currentTimeframe: Timeframe.WEEKLY, onPendingCreated: () => {}, ...props,
      }),
    );

  const library = [
    task({ id: 'r1', title: 'Books', counterName: 'Books', timeframeGoals: { weekly: 2 } }),
    task({ id: 'r2', title: 'Book pages', action: 'Read', unit: 'pages', counterName: 'Pages' }),
    task({ id: 'r3', title: 'Book flights', type: TaskType.NORMAL, isCounter: false }),
  ];

  it('no typed text → no dropdown', () => {
    expect(render(library)).not.toContain('Matching library tasks');
  });

  it('a root with a default: name · dense kind tag · "Weekly · 2 books" · plus, as ONE button row', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r1 = rows.find((r) => r.includes('>Books<'))!;
    expect(r1).toMatch(/<button[^>]*>.*>Books<.*Discrete.*Weekly · <span[^>]*>2 books<\/span>.*<\/button>/s);
    expect(r1).toContain('tagDense');
  });

  it('a goal-less root with no default: the slot is a Goal entry with the unit, the plus disabled; the typed goal gates it', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r2 = rows.find((r) => r.includes('>Pages<'))!;
    expect(r2).toContain('role="group"');
    expect(r2).toContain('aria-label="Goal for Pages"');
    expect(r2).toContain('placeholder="Goal"');
    expect(r2).toContain('>pages<');
    expect(r2).toMatch(/<button[^>]*aria-label="Add Pages"[^>]*disabled/);
  });

  it('a plain task row is unchanged; without a board timeframe every row is plain', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r3 = rows.find((r) => r.includes('Book flights'))!;
    expect(r3).not.toContain('tagDense');
    expect(r3).not.toContain('role="group"');
    const noBoard = render(library, { seedText: 'book', currentTimeframe: undefined });
    expect(noBoard).not.toContain('tagDense');
    expect(noBoard).not.toContain('role="group"');
    // A host without `onPendingCreated` (no deferred path) keeps the plain row for the no-default root too.
    const noPending = render(library, { seedText: 'book', onPendingCreated: undefined });
    expect(noPending).toContain('Weekly · ');
    expect(noPending).not.toContain('role="group"');
  });
});
