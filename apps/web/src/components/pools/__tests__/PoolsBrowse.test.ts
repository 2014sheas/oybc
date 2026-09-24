import { beforeEach, describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  CenterSquareType,
  TaskType,
  Timeframe,
  type BoardSource,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import type { RosterHealth } from '../../recurringTemplates/templateHealth';

/**
 * PoolsBrowse — first paint is final paint (2026-09 audit T2 final wave).
 *
 * The "Short on N boards" line comes from the roster's achievable picks
 * (`useTemplateRosterHealth`), which resolve asynchronously. The surface
 * used to paint warning-less cards while they loaded and then add the
 * line — a late mutation. These render the REAL component with the two
 * live-query hooks stubbed to each loading state, and assert the cards
 * are held behind a loading line until every template's pick is in.
 *
 * Rendered with `react-dom/server` (no jsdom/RTL harness in this repo).
 */

const hookState: {
  templates: RecurringBoardTemplate[] | undefined;
  roster: RosterHealth | undefined;
} = { templates: undefined, roster: undefined };

vi.mock('../../../hooks', () => ({
  useRecurringBoardTemplatesQuery: () => hookState.templates,
  // The collapsing variant (`[]` while loading) — stubbed too so the test
  // also runs against a PoolsBrowse that still reads it.
  useRecurringBoardTemplates: () => hookState.templates ?? [],
  useTemplateRosterHealth: () => hookState.roster,
}));

// Imported after the mock is registered (vi.mock is hoisted anyway).
const { PoolsBrowse } = await import('../PoolsBrowse');

const NOW = '2026-09-23T00:00:00.000Z';

function buildTask(id: string): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

function poolSource(sourceId: string): BoardSource {
  return { sourceId, kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all' };
}

const TASKS = [buildTask('t0'), buildTask('t1'), buildTask('t2')];
const POOL: Pool = {
  id: 'pA',
  userId: 'u1',
  name: 'Chores',
  taskIds: TASKS.map((t) => t.id),
  createdAt: NOW,
  updatedAt: NOW,
  version: 1,
  isDeleted: false,
};
// A 3×3 FREE weekly needs 8; this one can only ever deal the pool's 3.
const TEMPLATE: RecurringBoardTemplate = {
  id: 'tpl',
  userId: 'u1',
  name: 'Weekly chores',
  timeframe: Timeframe.WEEKLY,
  boardSize: 3,
  centerSquareType: CenterSquareType.FREE,
  isRandomized: false,
  seedTaskIds: [],
  poolIds: [],
  manualTaskIds: [],
  removedTaskIds: [],
  sources: [poolSource('pA')],
  lastSpawnedWindowKey: null,
  isActive: true,
  createdAt: NOW,
  updatedAt: NOW,
  version: 1,
  isDeleted: false,
};

function render(): string {
  return renderToStaticMarkup(
    React.createElement(PoolsBrowse, {
      userId: 'u1',
      pools: [POOL],
      allTasks: TASKS,
      browsableTasks: TASKS,
    }),
  );
}

describe('PoolsBrowse first paint', () => {
  beforeEach(() => {
    hookState.templates = undefined;
    hookState.roster = undefined;
  });

  it('holds the cards behind a loading line while the roster health is undefined', () => {
    hookState.templates = [TEMPLATE];
    hookState.roster = undefined;
    const html = render();
    expect(html).toContain('data-testid="pools-browse-loading"');
    // No warning-less card list painted ahead of its warning.
    expect(html).not.toContain('Chores');
    expect(html).not.toContain('Short on');
  });

  it('holds the cards while the templates query itself is still loading', () => {
    // A resolved-but-empty roster for a not-yet-read template list would
    // otherwise read as "no consumers" and paint the card with no warning.
    hookState.templates = undefined;
    hookState.roster = { mixByTemplateId: {}, attentionByTemplateId: {} };
    const html = render();
    expect(html).toContain('data-testid="pools-browse-loading"');
    expect(html).not.toContain('Chores');
  });

  it('holds the cards while the roster map is stale (computed before this template landed)', () => {
    hookState.templates = [TEMPLATE];
    hookState.roster = { mixByTemplateId: {}, attentionByTemplateId: {} };
    const html = render();
    expect(html).toContain('data-testid="pools-browse-loading"');
    expect(html).not.toContain('Chores');
  });

  it('paints the card WITH its warning on the first paint once the map covers the roster', () => {
    hookState.templates = [TEMPLATE];
    hookState.roster = {
      mixByTemplateId: { tpl: TASKS.map((t) => t.id) },
      attentionByTemplateId: {},
    };
    const html = render();
    expect(html).not.toContain('data-testid="pools-browse-loading"');
    expect(html).toContain('Chores');
    expect(html).toContain('Short on 1 board');
  });

  it('paints a healthy card with no warning when the resolved supply fills the board', () => {
    hookState.templates = [TEMPLATE];
    hookState.roster = {
      mixByTemplateId: { tpl: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'] },
      attentionByTemplateId: {},
    };
    const html = render();
    expect(html).toContain('Chores');
    expect(html).not.toContain('Short on');
    expect(html).not.toContain('data-testid="pools-browse-loading"');
  });
});
