import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, type Task } from '@oybc/shared';
import { TaskRow } from '../TaskRow';

/**
 * Owner ruling 2026-09-22 — the Tasks-tab library shows ONE generic row per
 * shared-counter family. This pins what that row actually RENDERS: the
 * pair-derived label, the goal-free subtitle, the counter-opening accessible
 * name, and the absence of any count. A standalone counter is unchanged.
 *
 * iOS twin: `RisoTasksTabSnapshotTests.testLibraryCounterFamilyRow*`.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `TaskConfirmDeleteDialog.test.ts`).
 */

const NOW = '2026-09-18T10:00:00.000Z';

function counter(over: Partial<Task> = {}): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Read 35 pages',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    maxCount: 35,
    currentCount: 12,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function render(task: Task, isFamilyRoot: boolean): string {
  return renderToStaticMarkup(
    React.createElement(TaskRow, {
      task,
      placementCount: 2,
      activePlacementCount: 1,
      usageCountsLoaded: true,
      childCount: 0,
      onClick: () => {},
      isFamilyRoot,
    }),
  );
}

describe('TaskRow — shared-counter family root', () => {
  it('renders the generic label, a goal-free subtitle, and no count at all', () => {
    const html = render(counter(), true);

    // The pair-derived name replaces the stored title.
    expect(html).toContain('Read pages');
    expect(html).not.toContain('Read 35 pages');
    // Goal-free subtitle, in lockstep with iOS `RisoTaskRowView.subtitle`.
    expect(html).toContain('Counter');
    // No count anywhere: not the generated "Read 35 pages" subtitle, and not
    // the `{current} / {max}` status slot.
    expect(html).not.toContain('12 / 35');
    expect(html).not.toContain('35');
    // The accessible name says it opens the COUNTER, not "details" — the tap
    // goes to the Counters hub, so "details" would mislead a screen reader.
    expect(html).toContain('aria-label="Open the Read pages counter"');
    expect(html).not.toContain('details"');
  });

  it('falls back to the stored title when the (action, unit) pair yields nothing', () => {
    const html = render(counter({ action: undefined, unit: undefined, title: 'Legacy row' }), true);
    expect(html).toContain('Legacy row');
    expect(html).toContain('aria-label="Open the Legacy row counter"');
  });

  it('leaves a standalone counter alone — stored title, generated subtitle, its count', () => {
    const html = render(counter(), false);

    expect(html).toContain('Read 35 pages');
    expect(html).toContain('12 / 35');
    expect(html).toContain('aria-label="Open Read 35 pages details"');
    expect(html).not.toContain('Open the Read pages counter');
  });
});
