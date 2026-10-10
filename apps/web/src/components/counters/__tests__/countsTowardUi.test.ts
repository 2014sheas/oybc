import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, type Board, type Task } from '@oybc/shared';
import { CountsTowardSection, amountText, countsTowardHeading, creditCountText } from '../CountsTowardSection';
import {
  countsTowardSubmitFor,
  filterCountsTowardTargets,
  needsRepointConfirm,
  showsCountsTowardRow,
  stepAmount,
  storedCountsToward,
} from '../countsTowardFieldModel';
import { countsTowardProblemLabel } from '../countsTowardLabels';
import { selectCountsTowardTargets } from '../../../hooks/useCountsTowardTargets';

/**
 * "Counts toward" PR 4 — the UI's pure models (docs/SHARED_COUNTER_SETTINGS.md
 * §3d; design handoff §C1 / §C2): the section's heading / "× N" / "+N" rules
 * and render, the editor row's visibility, search, re-point confirm, stepper
 * floor and submit diff, the target selector and the refusal labels.
 */

const T0 = '2026-10-01T00:00:00.000Z';
function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: 'u', title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}
const root = (id: string, over: Partial<Task> = {}): Task =>
  task(id, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 12, currentCount: 412, isCounter: true, counterName: 'Books', ...over });

describe('CountsTowardSection — model', () => {
  it('heading counts rows; "× N" only from 2 credits; "+N" only when the amount is not 1', () => {
    expect(countsTowardHeading(0)).toBe('Counts toward');
    expect(countsTowardHeading(1)).toBe('Counts toward · 1 task');
    expect(countsTowardHeading(6)).toBe('Counts toward · 6 tasks');
    expect(creditCountText({ creditCount: 0 })).toBeNull();
    expect(creditCountText({ creditCount: 1 })).toBeNull();
    expect(creditCountText({ creditCount: 3 })).toBe('× 3');
    expect(amountText({ amount: 1 })).toBeNull();
    expect(amountText({ amount: 2 })).toBe('+2');
  });

  it('renders the rows as drawn: badge, title (done = strikethrough class), board + dot, × N, +N, pill; and the empty one-liner', () => {
    const board = { id: 'b1', name: '2026 Reading', timeframe: Timeframe.YEARLY } as Board;
    const html = renderToStaticMarkup(
      React.createElement(CountsTowardSection, {
        counterName: 'Books',
        onNew: () => {},
        onOpenTask: () => {},
        data: {
          rows: [
            { taskId: 'dune', status: 'done', boardId: 'b1', amount: 1, creditCount: 3, latestOccurredAt: T0 },
            { taskId: 'club', status: 'inProgress', boardId: null, amount: 2, creditCount: 1, latestOccurredAt: null },
            { taskId: 'loose', status: 'notStarted', boardId: null, amount: 1, creditCount: 0, latestOccurredAt: null },
          ],
          taskById: {
            dune: task('dune', { title: 'Finish Dune' }),
            club: task('club', { title: 'Book club', type: TaskType.COMPOUND }),
            loose: task('loose', { title: 'Audiobook: Piranesi' }),
          },
          boardById: { b1: board },
        },
      }),
    );
    expect(html).toContain('Counts toward · 3 tasks');
    expect(html).toContain('+ New');
    expect(html).toContain('Finish Dune');
    expect(html).toContain('2026 Reading');
    expect(html).toContain('× 3');
    expect(html).toContain('+2');
    expect(html).toContain('>Done<');
    expect(html).toContain('>In progress<');
    expect(html).toContain('>Not started<');
    expect((html.match(/titleDone/g) ?? []).length).toBe(1);
    expect(html).toContain('background:var(--riso-red)');
    expect(html).not.toContain('Nothing counts toward');

    const empty = renderToStaticMarkup(
      React.createElement(CountsTowardSection, { counterName: 'Books', onNew: () => {}, onOpenTask: () => {}, data: { rows: [], taskById: {}, boardById: {} } }),
    );
    expect(empty).toContain('>Counts toward<');
    expect(empty).toContain('Nothing counts toward Books yet.');
  });
});

describe('countsTowardFieldModel', () => {
  const books = root('books');
  const miles = root('miles', { counterName: 'Miles', countKind: 'continuous' });
  const linked = task('copy', { type: TaskType.COUNTING, sharedCounterId: 'books', maxCount: 1 });
  const dune = task('dune');
  const all = [books, miles, linked, dune, task('ach', { type: TaskType.ACHIEVEMENT })];

  it('shows the row only for a task that can contribute', () => {
    expect(showsCountsTowardRow(dune, all)).toBe(true);
    expect(showsCountsTowardRow(dune, all, TaskType.ACHIEVEMENT)).toBe(false);
    expect(showsCountsTowardRow(linked, all)).toBe(false);
    expect(showsCountsTowardRow(books, all)).toBe(false);
    expect(showsCountsTowardRow(task('ach', { type: TaskType.ACHIEVEMENT }), all)).toBe(false);
    // A root other rows link to (no `isCounter`) is a counter too.
    expect(showsCountsTowardRow(task('r', { type: TaskType.COUNTING, maxCount: 5 }), [task('x', { sharedCounterId: 'r' })])).toBe(false);
  });

  it('selects Discrete roots only, never the edited task, sorted by name; search is the counter search', () => {
    const targets = selectCountsTowardTargets(all, 'dune');
    expect(targets.map((t) => t.id)).toEqual(['books']);
    expect(targets[0]).toMatchObject({ name: 'Books', lifetime: 412, kind: 'discrete' });
    expect(selectCountsTowardTargets([...all, root('chapters', { counterName: 'Chapters' })]).map((t) => t.name)).toEqual(['Books', 'Chapters']);
    expect(selectCountsTowardTargets(all, 'books')).toEqual([]);
    expect(filterCountsTowardTargets(targets, '')).toHaveLength(1);
    expect(filterCountsTowardTargets(targets, 'boo')).toHaveLength(1);
    expect(filterCountsTowardTargets(targets, 'read')).toHaveLength(1);
    expect(filterCountsTowardTargets(targets, 'push')).toHaveLength(0);
  });

  it('asks only when re-pointing an already-counting task to a different counter', () => {
    expect(needsRepointConfirm(null, 'books')).toBe(false);
    expect(needsRepointConfirm('books', 'books')).toBe(false);
    expect(needsRepointConfirm('books', null)).toBe(false);
    expect(needsRepointConfirm('books', 'chapters')).toBe(true);
  });

  it('stepper floors at 1; the submit is a diff against the stored row', () => {
    expect(stepAmount(1, -1)).toBe(1);
    expect(stepAmount(2, -1)).toBe(1);
    expect(stepAmount(1, 1)).toBe(2);
    const stored = storedCountsToward(task('t', { countsTowardCounterId: 'books', countsTowardAmount: 2 }));
    expect(stored).toEqual({ counterId: 'books', amount: 2 });
    expect(storedCountsToward(task('t'))).toEqual({ counterId: null, amount: 1 });
    expect(countsTowardSubmitFor(stored, { counterId: 'books', amount: 2 })).toBeUndefined();
    expect(countsTowardSubmitFor(stored, { counterId: 'books', amount: 3 })).toEqual({ counterId: 'books', amount: 3 });
    expect(countsTowardSubmitFor(stored, { counterId: 'chapters', amount: 2 })).toEqual({ counterId: 'chapters', amount: 2 });
    expect(countsTowardSubmitFor(stored, { counterId: null, amount: 1 })).toEqual({ counterId: null });
    expect(countsTowardSubmitFor({ counterId: null, amount: 1 }, { counterId: null, amount: 1 })).toBeUndefined();
    expect(countsTowardSubmitFor({ counterId: null, amount: 1 }, { counterId: 'books', amount: 1 })).toEqual({ counterId: 'books', amount: 1 });
  });

  it('every refusal code has a short label', () => {
    for (const code of ['self', 'contributor-is-counter', 'contributor-is-linked', 'contributor-is-achievement', 'target-not-counter', 'target-not-discrete', 'invalid-amount', 'cycle'] as const) {
      expect(countsTowardProblemLabel(code).length).toBeGreaterThan(0);
    }
    expect(countsTowardProblemLabel('cycle')).toBe('That counter already feeds this task.');
  });
});
