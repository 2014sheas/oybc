import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, type Board, type Task } from '@oybc/shared';
import { CountsTowardSection } from '../CountsTowardSection';
import { RemoveUnitTaskConfirmDialog } from '../RemoveUnitTaskConfirmDialog';
import { UnitTag } from '../UnitTag';
import {
  countsTowardProblemLabel,
  creditCountText,
  removeConfirmBody,
  removeConfirmTitle,
  removableRow,
  removeNeedsConfirm,
  removeSlotLabel,
  rowProgressText,
  unitTagLabel,
  unitTasksHeading,
  unitTasksKeptNote,
  UNIT_TASKS_EMPTY,
} from '../countsTowardLabels';

/**
 * "Counts toward" PR 4 — the UI's pure models (docs/SHARED_COUNTER_SETTINGS.md
 * §3d): the section's heading / "× N" / "+N" rules and render, and the
 * refusal labels.
 */

const T0 = '2026-10-01T00:00:00.000Z';
function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: 'u', title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}
const none = { progress: null, childProgress: null } as const;
const noop = async (): Promise<void> => {};

describe('CountsTowardSection — model', () => {
  it('heading counts rows; "× N" only from 2 credits', () => {
    expect(unitTasksHeading(0)).toBe('Unit tasks');
    expect(unitTasksHeading(1)).toBe('Unit tasks · 1');
    expect(unitTasksHeading(6)).toBe('Unit tasks · 6');
    expect(UNIT_TASKS_EMPTY).toBe('No unit tasks yet.');
    expect(creditCountText({ creditCount: 0 })).toBeNull();
    expect(creditCountText({ creditCount: 1 })).toBeNull();
    expect(creditCountText({ creditCount: 3 })).toBe('× 3');
  });

  it('progress text: counting mid-progress in its kind, compound tallies, nothing otherwise', () => {
    const pages = { unit: 'pages' };
    expect(rowProgressText({ status: 'inProgress', progress: { current: 120, goal: 300, kind: 'discrete' }, childProgress: null }, pages)).toBe('120 / 300 pages');
    expect(rowProgressText({ status: 'inProgress', progress: { current: 90, goal: 180, kind: 'duration' }, childProgress: null }, pages)).toBe('1h 30m / 3h');
    expect(rowProgressText({ status: 'notStarted', progress: { current: 0, goal: 300, kind: 'discrete' }, childProgress: null }, pages)).toBeNull();
    expect(rowProgressText({ status: 'notStarted', progress: null, childProgress: { done: 0, total: 0 } }, pages)).toBe('No subtasks yet');
    expect(rowProgressText({ status: 'inProgress', progress: null, childProgress: { done: 1, total: 2 } }, pages)).toBe('1 of 2 subtasks');
    expect(rowProgressText({ status: 'done', progress: null, childProgress: { done: 2, total: 2 } }, pages)).toBeNull();
    expect(rowProgressText({ status: 'done', progress: null, childProgress: null }, pages)).toBeNull();
  });

  it('remove gate: confirm only with credits; confirm copy pluralises the credits', () => {
    expect(removeNeedsConfirm({ creditCount: 0 })).toBe(false);
    expect(removeNeedsConfirm({ creditCount: 1 })).toBe(true);
    expect(removeConfirmTitle('Books')).toBe('Remove from Books?');
    expect(removeConfirmBody('Read before bed', 4, 'Books')).toBe("'Read before bed' stays in your library. Its 4 credits on Books are withdrawn.");
    expect(removeConfirmBody('Finish Dune', 1, 'Books')).toBe("'Finish Dune' stays in your library. Its 1 credit on Books is withdrawn.");
    expect(removableRow({ childProgress: { done: 0, total: 0 } })).toBe(false);
    expect(removableRow({ childProgress: { done: 0, total: 2 } })).toBe(true);
    expect(removableRow({ childProgress: null })).toBe(true);
    expect(removeSlotLabel('Books')).toBe('Remove from Books');
    expect(unitTagLabel('Books')).toBe('Unit task of Books');
  });

  it('counter-delete line pluralises and hides at 0', () => {
    expect(unitTasksKeptNote(0)).toBeNull();
    expect(unitTasksKeptNote(1)).toBe('Its 1 unit task is kept as an ordinary task.');
    expect(unitTasksKeptNote(6)).toBe('Its 6 unit tasks are kept as ordinary tasks.');
  });

  it('renders the rows as drawn: badge, title (done = strikethrough class), board + dot, progress, × N, pill, remove slot; and the empty one-liner', () => {
    const board = { id: 'b1', name: '2026 Reading', timeframe: Timeframe.YEARLY } as Board;
    const html = renderToStaticMarkup(
      React.createElement(CountsTowardSection, {
        counterName: 'Books',
        onNew: () => {},
        onOpenTask: () => {},
        onRemove: noop,
        arrivedTaskId: 'club',
        data: {
          rows: [
            { taskId: 'pages', memberIds: ['pages'], status: 'inProgress', boardId: 'b1', creditCount: 0, latestOccurredAt: null, progress: { current: 120, goal: 300, kind: 'discrete' }, childProgress: null },
            { taskId: 'club', memberIds: ['club'], status: 'notStarted', boardId: null, creditCount: 0, latestOccurredAt: null, progress: null, childProgress: { done: 0, total: 0 } },
            { taskId: 'dune', memberIds: ['dune'], status: 'done', boardId: 'b1', creditCount: 3, latestOccurredAt: T0, ...none },
          ],
          taskById: {
            pages: task('pages', { title: 'Read 300 pages', type: TaskType.COUNTING, unit: 'pages' }),
            club: task('club', { title: 'Book club night', type: TaskType.COMPOUND }),
            dune: task('dune', { title: 'Finish Dune' }),
          },
          boardById: { b1: board },
        },
      }),
    );
    expect(html).toContain('Unit tasks · 3');
    expect(html).toContain('+ New');
    expect(html).toContain('2026 Reading');
    expect(html).toContain('120 / 300 pages');
    expect(html).toContain('No subtasks yet');
    expect(html).toContain('× 3');
    expect(html).toContain('>Done<');
    expect(html).toContain('>In progress<');
    expect(html).toContain('>Not started<');
    expect((html.match(/titleDone/g) ?? []).length).toBe(1);
    // The zero-subtask compound has no remove control (an empty same-width slot keeps the layout).
    expect((html.match(/aria-label="Remove from Books"/g) ?? []).length).toBe(2);
    expect((html.match(/removeSpacer/g) ?? []).length).toBe(1);
    // Only the just-created row wears the return ring.
    expect((html.match(/arrived/g) ?? []).length).toBe(1);
    expect(html).toContain('background:var(--riso-red)');
    expect(html).not.toContain('Nothing counts toward');

    const empty = renderToStaticMarkup(
      React.createElement(CountsTowardSection, { counterName: 'Books', onNew: () => {}, onOpenTask: () => {}, onRemove: noop, data: { rows: [], taskById: {}, boardById: {} } }),
    );
    expect(empty).toContain('>Unit tasks<');
    expect(empty).toContain('No unit tasks yet.');
    expect(empty).not.toContain('Remove from');
  });
});

describe('UnitTag / RemoveUnitTaskConfirmDialog', () => {
  it('UnitTag is dots + the counter name with the a11y label; dense adds the dense class', () => {
    const regular = renderToStaticMarkup(React.createElement(UnitTag, { name: 'Books' }));
    expect(regular).toContain('aria-label="Unit task of Books"');
    expect(regular).toContain('title="Unit task of Books"');
    expect(regular).toContain('Books');
    expect(regular).not.toContain('tagDense');
    expect(renderToStaticMarkup(React.createElement(UnitTag, { name: 'Books', dense: true }))).toContain('tagDense');
  });

  it('the remove confirm names the counter and the withdrawn credits, with Cancel / Remove', () => {
    const html = renderToStaticMarkup(
      React.createElement(RemoveUnitTaskConfirmDialog, { counterName: 'Books', taskTitle: 'Read before bed', credits: 4, busy: false, onConfirm: () => {}, onCancel: () => {} }),
    );
    expect(html).toContain('Remove from Books?');
    expect(html).toContain('Its 4 credits on Books are withdrawn.');
    expect(html).toContain('>Cancel<');
    expect(html).toContain('>Remove<');
  });
});

describe('countsTowardLabels', () => {
  it('every refusal code has a short label', () => {
    for (const code of ['self', 'contributor-is-counter', 'contributor-is-linked', 'contributor-is-achievement', 'target-not-counter', 'target-not-discrete', 'invalid-amount', 'cycle'] as const) {
      expect(countsTowardProblemLabel(code).length).toBeGreaterThan(0);
    }
    expect(countsTowardProblemLabel('cycle')).toBe('That counter already feeds this task.');
  });
});
