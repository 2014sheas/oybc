import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  CenterSquareType,
  TaskType,
  Timeframe,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { PoolPickerSheet } from '../PoolPickerSheet';

/**
 * PoolPickerSheet — same first-paint gate as `PoolsBrowse` (2026-09 audit
 * T2 final wave): the rows' "Short on N boards" note is fed by the page's
 * asynchronously-resolved roster map, so the rows are held behind a
 * loading line until that map covers every template.
 *
 * Rendered with `react-dom/server` (no jsdom/RTL harness in this repo).
 */

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

const TASKS = [buildTask('t0'), buildTask('t1')];
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
  sources: [{ sourceId: 'pA', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all' }],
  lastSpawnedWindowKey: null,
  isActive: true,
  createdAt: NOW,
  updatedAt: NOW,
  version: 1,
  isDeleted: false,
};

function render(achievable: Record<string, string[]> | undefined): string {
  return renderToStaticMarkup(
    React.createElement(PoolPickerSheet, {
      userId: 'u1',
      pools: [POOL],
      templates: [TEMPLATE],
      achievableTaskIdsByTemplateId: achievable,
      tasksById: Object.fromEntries(TASKS.map((t) => [t.id, t])),
      browsableTasks: TASKS,
      selectedPoolIds: [],
      onTogglePool: () => {},
      onPoolCreated: () => {},
      onClose: () => {},
    }),
  );
}

describe('PoolPickerSheet first paint', () => {
  it('holds the rows behind a loading line while the roster map is undefined', () => {
    const html = render(undefined);
    expect(html).toContain('data-testid="pool-picker-loading"');
    expect(html).not.toContain('Chores');
  });

  it('renders the row WITH its warning once the map covers the roster', () => {
    const html = render({ tpl: TASKS.map((t) => t.id) });
    expect(html).not.toContain('data-testid="pool-picker-loading"');
    expect(html).toContain('Chores');
    expect(html).toContain('Short on 1 board');
  });
});
