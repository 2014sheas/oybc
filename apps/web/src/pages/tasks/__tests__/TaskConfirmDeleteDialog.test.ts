import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, type Task } from '@oybc/shared';
import type { TaskDeletionImpact } from '../../../db/operations/tasks';
import { TaskConfirmDeleteDialog } from '../TaskConfirmDeleteDialog';

/**
 * §Member rules (B3, RC12) — deleting a task also RETIRES every
 * window-stamped derived counter minted from it, plus their placements.
 * Those rows sit on OTHER boards, so they move neither `affectedBoards` nor
 * the compound link counts: without the warning line the dialog would print
 * "No other rows affected." immediately before an irreversible cascade.
 * iOS twin: `TaskDeleteConfirmView`'s `hasNoImpact` + `RisoImpactNote`.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `components/counters/__tests__/CounterDeleteConfirmDialog.test.ts`).
 */

const NOW = '2026-09-18T10:00:00.000Z';

const TASK: Task = {
  id: 't1',
  userId: 'u1',
  title: 'Run 5 km',
  type: TaskType.COUNTING,
  action: 'Run',
  unit: 'km',
  maxCount: 5,
  currentCount: 0,
  isCompleted: false,
  totalCompletions: 0,
  totalInstances: 0,
  createdAt: NOW,
  updatedAt: NOW,
  version: 1,
  isDeleted: false,
} as Task;

function impact(over: Partial<TaskDeletionImpact> = {}): TaskDeletionImpact {
  return {
    boardTaskCount: 0,
    affectedBoardIds: [],
    affectedBoards: [],
    childLinkCount: 0,
    parentLinkCount: 0,
    counterMemberCount: 0,
    counterMembers: [],
    countsTowardCounter: null,
    unitTaskCount: 0,
    ...over,
  };
}

function render(over: Partial<TaskDeletionImpact> = {}): string {
  return renderToStaticMarkup(
    React.createElement(TaskConfirmDeleteDialog, {
      task: TASK,
      impact: impact(over),
      onConfirm: () => {},
      onCancel: () => {},
    }),
  );
}

describe('TaskConfirmDeleteDialog — impact lines', () => {
  it('says "No other rows affected." when nothing at all is affected', () => {
    const html = render();
    expect(html).toContain('No other rows affected.');
    expect(html).not.toContain('made from this one will be removed.');
  });
});
