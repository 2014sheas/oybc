import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, type Board, type Task } from '@oybc/shared';
import { CountsTowardSection, countsTowardHeading, creditCountText } from '../CountsTowardSection';
import { countsTowardProblemLabel } from '../countsTowardLabels';

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
describe('CountsTowardSection — model', () => {
  it('heading counts rows; "× N" only from 2 credits', () => {
    expect(countsTowardHeading(0)).toBe('Counts toward');
    expect(countsTowardHeading(1)).toBe('Counts toward · 1 task');
    expect(countsTowardHeading(6)).toBe('Counts toward · 6 tasks');
    expect(creditCountText({ creditCount: 0 })).toBeNull();
    expect(creditCountText({ creditCount: 1 })).toBeNull();
    expect(creditCountText({ creditCount: 3 })).toBe('× 3');
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
            { taskId: 'dune', status: 'done', boardId: 'b1', creditCount: 3, latestOccurredAt: T0 },
            { taskId: 'club', status: 'inProgress', boardId: null, creditCount: 1, latestOccurredAt: null },
            { taskId: 'loose', status: 'notStarted', boardId: null, creditCount: 0, latestOccurredAt: null },
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
    expect(html).not.toContain('+2');
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

describe('countsTowardLabels', () => {
  it('every refusal code has a short label', () => {
    for (const code of ['self', 'contributor-is-counter', 'contributor-is-linked', 'contributor-is-achievement', 'target-not-counter', 'target-not-discrete', 'invalid-amount', 'cycle'] as const) {
      expect(countsTowardProblemLabel(code).length).toBeGreaterThan(0);
    }
    expect(countsTowardProblemLabel('cycle')).toBe('That counter already feeds this task.');
  });
});
