import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, Timeframe, type BoardSource, type BoardWindow, type Task } from '@oybc/shared';
import { SourceRow } from '../SourceRow';
import { findNestedInteractives } from '../../__tests__/nestedInteractive';
import type { WizardSourceSupply } from '../../../pages/createHub/wizardSources';

/**
 * Two things this pins, both from B3 Plan A / RC2:
 *
 * 1. The per-member ⋯ menu (#471 — "Derive smaller version…" / "Add
 *    subtask") is GONE. Per-member control is the rule row now; a
 *    re-introduced ⋯ would be a second, competing entry point.
 * 2. The exclude/UNDO affordance survived the move into `MemberRuleRow` —
 *    the member rows are no longer rendered by this file, so a regression
 *    here would be silent.
 *
 * Rendered with `react-dom/server` (no jsdom/RTL harness in this repo).
 */

const NOW = '2026-09-18T00:00:00.000Z';

const WIZARD_WINDOW: BoardWindow = {
  timeframe: Timeframe.DAILY,
  startDate: '2026-09-18',
  endDate: '2026-09-18',
};

function makeTask(id: string, title: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title,
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

function render(
  source: BoardSource,
  tasks: Task[],
  isExpanded = true,
  supplyOver: Partial<WizardSourceSupply> = {},
): string {
  const taskById: Record<string, Task> = {};
  for (const t of tasks) taskById[t.id] = t;
  const supply: WizardSourceSupply = {
    displayName: 'Morning Kickstart',
    rawSupplyTaskIds: tasks.map((t) => t.id),
    doneTaskIds: new Set<string>(),
    ...supplyOver,
  };
  return renderToStaticMarkup(
    React.createElement(SourceRow, {
      source,
      supply,
      availableCount: tasks.length,
      isExpanded,
      taskById,
      onToggleExpanded: () => {},
      onRemove: () => {},
      onSetFilter: () => {},
      onSetRange: () => {},
      onToggleExclude: () => {},
      compoundChildrenByCompound: {},
      mode: 'oneOff',
      wizardWindow: WIZARD_WINDOW,
      onSetMemberTarget: () => {},
      onSetMemberVary: () => {},
      onSetMemberSplit: () => {},
      onSetPartExcluded: () => {},
      onSetPartTarget: () => {},
      onSetPartVary: () => {},
    }),
  );
}

const POOL_SOURCE: BoardSource = {
  sourceId: 'pool-1',
  kind: 'pool',
  min: 0,
  max: null,
  excludedTaskIds: [],
  filter: 'all',
};

describe('SourceRow', () => {
  it('offers no per-member ⋯ menu (#471 removed)', () => {
    const counting = makeTask('t-read', 'Read', {
      type: TaskType.COUNTING,
      action: 'Read',
      unit: 'pages',
      maxCount: 35,
    });
    const compound = makeTask('t-circuit', 'Circuit', { type: TaskType.COMPOUND });
    const html = render(POOL_SOURCE, [counting, compound]);

    expect(html).not.toContain('⋯');
    expect(html).not.toContain('memberMore');
    expect(html).not.toContain('More actions for');
    expect(html).not.toContain('Derive smaller version');
    expect(html).not.toContain('Add all subtasks to board');
  });

  it('still strikes an excluded member through with an UNDO pill', () => {
    const html = render(
      { ...POOL_SOURCE, excludedTaskIds: ['t-plain'] },
      [makeTask('t-plain', 'Make the bed')],
    );
    expect(html).toContain('Make the bed');
    expect(html).toContain('aria-label="Undo excluding Make the bed"');
    expect(html).toContain('UNDO');
    expect(html).toMatch(/class="[^"]*_struck_/);
  });

  // 2026-09 audit (T1 Task 2): the ✕ used to be a <button> inside the
  // header's `role="button"` div, whose Enter/Space handler cancelled it.
  it.each([
    ['collapsed', false],
    ['expanded', true],
  ])('nests no control inside another (%s)', (_label, isExpanded) => {
    const counting = makeTask('t-read', 'Read', {
      type: TaskType.COUNTING,
      action: 'Read',
      unit: 'pages',
      maxCount: 35,
    });
    const html = render(POOL_SOURCE, [counting, makeTask('t-plain', 'Make the bed')], isExpanded);

    // Non-vacuous: the header's two controls are really in this markup.
    expect(html).toContain('aria-label="Remove Morning Kickstart"');
    expect(html).toMatch(/<button[^>]*aria-expanded="(true|false)"[^>]*aria-label="Morning Kickstart, /);
    expect(findNestedInteractives(html)).toEqual([]);
  });

  // Owner ruling 2026-09-24 — ended boards are never sources: a board source
  // with no board for the window being built says so in its subtitle slot.
  describe('no board for this window', () => {
    const BOARD_SOURCE: BoardSource = {
      sourceId: 'board-1',
      kind: 'board',
      min: 0,
      max: null,
      excludedTaskIds: [],
      filter: 'todo',
    };

    it('shows "No board for this window yet" when the supply resolved to no board', () => {
      const html = render(BOARD_SOURCE, [], false, {
        displayName: 'Week of Sep 14 – 20, 2026',
        noBoardForWindow: true,
      });
      expect(html).toContain('Week of Sep 14 – 20, 2026');
      expect(html).toContain('No board for this window yet');
      expect(html).not.toContain('not done');
    });

    it('keeps the normal subtitle for an empty board that DOES exist for the window', () => {
      const html = render(BOARD_SOURCE, [], false, { displayName: 'Empty board' });
      expect(html).toContain('0 not done');
      expect(html).not.toContain('No board for this window yet');
    });
  });
});
