import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, type PlacementParams, type Task } from '@oybc/shared';
import {
  counterGoalParams,
  counterMatchRowName,
  counterRootIdsIn,
  isExpiredForBrowse,
  isSharedCounterRoot,
  quickAddExcludedIds,
  quickAddPlacementParams,
  restampPlacementParams,
} from '../quickAddCounterPlacement';
import { withPlacementParamsFor, withoutPlacementParams } from '../../../pages/createHub/wizardPlacementParamsLogic';
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

  it('a plain counting task another live task links to is a root too (counterRootIdsIn)', () => {
    const plain = task({ id: 'p', isCounter: false, maxCount: 12 });
    const copy = task({ id: 'c', isCounter: false, maxCount: 3, sharedCounterId: 'p' });
    const ids = counterRootIdsIn([plain, copy]);
    expect(isSharedCounterRoot(plain, ids)).toBe(true);
    expect(isSharedCounterRoot(copy, ids)).toBe(false);
    expect(isSharedCounterRoot(plain, counterRootIdsIn(new Map([[plain.id, plain]])))).toBe(false);
    expect(isSharedCounterRoot(plain, counterRootIdsIn([plain, { ...copy, isDeleted: true }]))).toBe(false);
  });
});

describe('isExpiredForBrowse', () => {
  const NOW = new Date('2026-10-14T12:00:00.000Z');
  const june = { timeframe: Timeframe.MONTHLY, startDate: '2026-06-01T00:00:00.000', endDate: '2026-06-30T23:59:59.999' };

  it('an expired counter root stays browsable; an expired plain task, linked copy or normal task does not', () => {
    // A root born in a June board's wizard carries June's window — it is still the counter.
    expect(isExpiredForBrowse(task({ ...june }), new Set(), NOW)).toBe(false);
    expect(isExpiredForBrowse(task({ ...june, isCounter: false, maxCount: 100, timeframeGoals: { daily: 100 } }), new Set(), NOW)).toBe(false);
    const plain = task({ id: 'p', ...june, isCounter: false, maxCount: 100 });
    const copy = task({ id: 'c', ...june, isCounter: false, maxCount: 100, sharedCounterId: 'p' });
    expect(isExpiredForBrowse(plain, counterRootIdsIn([plain, copy]), NOW)).toBe(false); // linked-to → a root
    expect(isExpiredForBrowse(plain, new Set(), NOW)).toBe(true);
    expect(isExpiredForBrowse(copy, counterRootIdsIn([plain, copy]), NOW)).toBe(true);
    expect(isExpiredForBrowse(task({ ...june, type: TaskType.NORMAL, isCounter: undefined }), new Set(), NOW)).toBe(true);
  });

  it('nothing in its window, or without an endDate, is expired', () => {
    expect(isExpiredForBrowse(task({ ...june, isCounter: false, maxCount: 1 }), new Set(), new Date('2026-06-15T12:00:00.000Z'))).toBe(false);
    expect(isExpiredForBrowse(task({ isCounter: false, maxCount: 1 }), new Set(), NOW)).toBe(false);
  });
});

describe('counterMatchRowName', () => {
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
        currentTimeframe: Timeframe.WEEKLY, onPlacementParams: () => {}, ...props,
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

  it('a root with a default: name · dense kind tag · plus, as ONE button row — no goal text', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r1 = rows.find((r) => r.includes('>Books<'))!;
    expect(r1).toMatch(/<button[^>]*>.*>Books<.*Discrete.*<\/button>/s);
    expect(r1).not.toContain('Weekly · ');
    expect(r1).not.toContain('2 books');
    expect(r1).toContain('tagDense');
  });

  it('a goal-less root with no default places at the kind fallback: the plain row, no Goal entry', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r2 = rows.find((r) => r.includes('>Pages<'))!;
    expect(r2).toContain('tagDense');
    expect(r2).not.toContain('role="group"');
  });

  it('only a custom board with no parseable dates leaves nothing to resolve: the slot is a Goal entry', () => {
    const h = render(library, { seedText: 'book', currentTimeframe: Timeframe.CUSTOM });
    const rows = h.split('<li ').slice(1);
    const r2 = rows.find((r) => r.includes('>Pages<'))!;
    expect(r2).toContain('role="group"');
    expect(r2).toContain('aria-label="Goal for Pages"');
    expect(r2).toContain('placeholder="Goal"');
    expect(r2).toContain('>pages<');
    expect(r2).toMatch(/<button[^>]*aria-label="Add Pages"[^>]*disabled/);
    const dated = render(library, {
      seedText: 'book', currentTimeframe: Timeframe.CUSTOM, currentStartDate: '2026-10-01', currentEndDate: '2026-10-10',
    });
    expect(dated.split('<li ').slice(1).find((r) => r.includes('>Pages<'))!).not.toContain('role="group"');
  });

  it('a host that admits no goal-less counters (compound sub-tasks) never lists one', () => {
    const h = render(library, { seedText: 'book', excludeGoalLessCounters: true });
    expect(h).not.toContain('>Pages<');
    expect(h).not.toContain('>Books<');
  });

  it('a plain task row is unchanged; without a board timeframe a counter is still the counter row', () => {
    const h = render(library, { seedText: 'book' });
    const rows = h.split('<li ').slice(1);
    const r3 = rows.find((r) => r.includes('Book flights'))!;
    expect(r3).not.toContain('tagDense');
    expect(r3).not.toContain('role="group"');
    const noBoard = render(library, { seedText: 'book', currentTimeframe: undefined });
    expect(noBoard.split('<li ').slice(1).find((r) => r.includes('>Pages<'))!).toContain('tagDense');
    expect(noBoard).not.toContain('role="group"');
    // A host without `onPlacementParams` keeps the plain row for the no-default root too.
    const noParams = render(library, { seedText: 'book', onPlacementParams: undefined });
    expect(noParams).toContain('tagDense');
    expect(noParams).not.toContain('role="group"');
  });
});

describe('quickAddExcludedIds', () => {
  it('adds the counter a selected task links to, and nothing for unselected links', () => {
    const copy = task({ id: 'copy', sharedCounterId: 'root', isCounter: false });
    const other = task({ id: 'other-copy', sharedCounterId: 'other-root', isCounter: false });
    const excluded = quickAddExcludedIds(new Set(['copy', 'plain']), [task({}), copy, other]);
    expect([...excluded].sort()).toEqual(['copy', 'plain', 'root']);
  });
});

describe('quick-add placement parameters', () => {
  const root = task({ maxCount: 100, timeframeGoals: { daily: 2, weekly: 10 } });
  const daily = { timeframe: Timeframe.DAILY, startDate: '2026-10-14', endDate: '2026-10-14' };
  const weekly = { timeframe: Timeframe.WEEKLY, startDate: '2026-10-12', endDate: '2026-10-18' };

  it('a root is placed as itself with the window default as its override', () => {
    expect(quickAddPlacementParams(root, weekly)).toEqual({ targetOverride: 10, targetKind: 'discrete' });
    expect(quickAddPlacementParams(root, daily)).toEqual({ targetOverride: 2, targetKind: 'discrete' });
  });

  it('no parameters when the window goal is the root own goal', () => {
    expect(quickAddPlacementParams(task({ maxCount: 5 }), weekly)).toBeNull();
    expect(quickAddPlacementParams(task({ maxCount: 10, timeframeGoals: { weekly: 10 } }), weekly)).toBeNull();
  });

  it('a typed goal is kept even when it equals the root own goal while a window default differs', () => {
    expect(counterGoalParams(root, 100, weekly)).toEqual({ targetOverride: 100, targetKind: 'discrete' });
    expect(counterGoalParams(task({ maxCount: 5 }), 5, weekly)).toBeNull();
    expect(counterGoalParams(root, null, weekly)).toBeNull();
  });

  it('selecting sets the entry, deselecting clears it', () => {
    const none = new Map<string, PlacementParams>();
    const set = withPlacementParamsFor(none, 'root', quickAddPlacementParams(root, weekly));
    expect(set.get('root')).toEqual({ targetOverride: 10, targetKind: 'discrete' });
    expect(withoutPlacementParams(set, ['root']).size).toBe(0);
    expect(withoutPlacementParams(set, ['other'])).toBe(set);
    expect(withPlacementParamsFor(set, 'root', null).size).toBe(0);
    expect(withPlacementParamsFor(none, 'root', null)).toBe(none);
  });
});

describe('restampPlacementParams', () => {
  const root = task({ maxCount: 100, timeframeGoals: { daily: 2, weekly: 10 } });
  const daily = { timeframe: Timeframe.DAILY, startDate: '2026-10-14', endDate: '2026-10-14' };
  const weekly = { timeframe: Timeframe.WEEKLY, startDate: '2026-10-12', endDate: '2026-10-18' };
  const rootOf = (id: string): Task | undefined => (id === 'root' ? root : undefined);

  it('an override at the old window default follows to the new default', () => {
    const params = new Map<string, PlacementParams>([['root', { targetOverride: 2, targetKind: 'discrete' }]]);
    expect(restampPlacementParams(params, rootOf, daily, weekly).get('root')).toEqual({ targetOverride: 10, targetKind: 'discrete' });
  });

  it('a typed goal stays', () => {
    const params = new Map<string, PlacementParams>([['root', { targetOverride: 7, targetKind: 'discrete' }]]);
    expect(restampPlacementParams(params, rootOf, daily, weekly)).toBe(params);
  });

  it('an entry whose new default is the root own goal is dropped', () => {
    const own = task({ maxCount: 10, timeframeGoals: { daily: 2, weekly: 10 } });
    const params = new Map<string, PlacementParams>([['root', { targetOverride: 2, targetKind: 'discrete' }]]);
    expect(restampPlacementParams(params, () => own, daily, weekly).has('root')).toBe(false);
  });
});
