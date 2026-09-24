import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  OperatorType,
  TaskType,
  compoundChildPickerCandidates,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { CompoundFields } from '../CompoundFields';
import { ExistingTaskPicker } from '../ExistingTaskPicker';
import {
  emptyPatch,
  keptChildTaskIds,
  type ChildPatch,
  type TaskEditPatch,
} from '../../../db/taskEditPatch';

/**
 * CompoundFields is the rule + sub-task editor shared by the wizard's inline
 * pool-row editor and the Task Detail edit sheet. Rendered with
 * `react-dom/server` (no jsdom/RTL harness in this repo), so this pins the
 * markup: sub-task cards, the operator picker, both add buttons, and the
 * "at least N" stepper's bounds.
 */

function child(id: string, title: string, over: Partial<ChildPatch> = {}): ChildPatch {
  return {
    id,
    childTaskId: id,
    title,
    isCounting: false,
    action: '',
    goal: '',
    unit: '',
    markedDeleted: false,
    ...over,
  };
}

function render(draft: TaskEditPatch): string {
  return renderToStaticMarkup(
    React.createElement(CompoundFields, {
      draft,
      onDraftChange: () => {},
      parentId: 'P',
      libraryTasks: [],
      allLinks: [],
    }),
  );
}

const TWO_CHILD_AND: TaskEditPatch = {
  ...emptyPatch('Morning routine'),
  operator: OperatorType.AND,
  children: [child('c-1', 'Stretch'), child('c-2', 'Read', { isCounting: true, action: 'Read', goal: '10', unit: 'pages' })],
};

describe('CompoundFields', () => {
  it('renders each sub-task, the operator picker and all three add buttons', () => {
    const html = render(TWO_CHILD_AND);
    expect(html).toContain('value="Stretch"');
    expect(html).toContain('value="Read"');
    expect(html).toContain('aria-label="Sub-task 1 title"');
    expect(html).toContain('aria-label="Sub-task 2 unit"');
    expect(html).toContain('All of');
    expect(html).toContain('Any of');
    expect(html).toContain('At least N of');
    expect(html).toContain('+ Normal sub-task');
    expect(html).toContain('+ Counting sub-task');
    expect(html).toContain('+ Existing task…');
    // The picker is closed until the button is pressed.
    expect(html).not.toContain('role="dialog"');
  });

  it('shows no threshold stepper for All of', () => {
    expect(render(TWO_CHILD_AND)).not.toContain('of 2 sub-tasks');
  });

  it('bounds the "at least N" stepper by the live sub-task count', () => {
    const html = render({ ...TWO_CHILD_AND, operator: OperatorType.M_OF_N, threshold: 2 });
    expect(html).toContain('of 2 sub-tasks');
    // value 2 == max 2 → the "+" button is disabled; "−" (min 1) is not.
    const minus = html.match(/<button[^>]*>−<\/button>/)?.[0] ?? '';
    const plus = html.match(/<button[^>]*>\+<\/button>/)?.[0] ?? '';
    expect(plus).toContain('disabled');
    expect(minus).not.toBe('');
    expect(minus).not.toContain('disabled');
  });

  it('counts only live (non-blank, non-deleted) sub-tasks in the stepper label', () => {
    const html = render({
      ...TWO_CHILD_AND,
      operator: OperatorType.M_OF_N,
      threshold: 1,
      children: [...TWO_CHILD_AND.children, child('c-3', '   ')],
    });
    expect(html).toContain('of 2 sub-tasks');
    expect(html).not.toContain('of 3 sub-tasks');
  });
});

function task(id: string, title: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u',
    title,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-09-24T00:00:00.000Z',
    updatedAt: '2026-09-24T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function link(parent: string, childId: string): CompoundChild {
  return {
    id: `${parent}->${childId}`,
    compoundTaskId: parent,
    childTaskId: childId,
    childIndex: 0,
    createdAt: '2026-09-24T00:00:00.000Z',
    updatedAt: '2026-09-24T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

describe('ExistingTaskPicker', () => {
  // P is being edited and already holds c-1 ("Stretch"); Q contains P.
  const library: Task[] = [
    task('c-1', 'Stretch'),
    task('P', 'Morning routine', { type: TaskType.COMPOUND }),
    task('Q', 'Whole day', { type: TaskType.COMPOUND }),
    task('ach', 'Greenlog week', { type: TaskType.ACHIEVEMENT }),
    task('nu', 'Read 10', { type: TaskType.COUNTING, action: 'Read', maxCount: 10 }),
    task('ng', 'Swim', { type: TaskType.COUNTING, action: 'Swim', unit: 'laps' }),
    task('ok-c', 'Run 5 km', { type: TaskType.COUNTING, action: 'Run', maxCount: 5, unit: 'km' }),
    task('ok-n', 'Journal'),
  ];
  const links = [link('P', 'c-1'), link('Q', 'P')];

  function renderPicker(): string {
    const draft: TaskEditPatch = { ...TWO_CHILD_AND, children: [child('c-1', 'Stretch')] };
    const tasks = compoundChildPickerCandidates('P', library, links, keptChildTaskIds(draft));
    return renderToStaticMarkup(
      React.createElement(ExistingTaskPicker, { tasks, onPick: () => {}, onCancel: () => {} }),
    );
  }

  it('is a labelled modal dialog with a search field', () => {
    const html = renderPicker();
    expect(html).toMatch(/<div[^>]*role="dialog"[^>]*aria-label="Add an existing task"[^>]*aria-modal="true"/);
    expect(html).toContain('aria-label="Search tasks"');
  });

  it('lists only eligible tasks — no self, current child, loop, achievement, or incomplete counter', () => {
    const html = renderPicker();
    const rows = [...html.matchAll(/<button[^>]*aria-label="Add ([^"]+)"/g)].map((m) => m[1]);
    expect(rows).toEqual(['Journal', 'Run 5 km']);
    // Counting without a unit ("Read 10") and without a goal ("Swim") are hidden.
    expect(html).not.toContain('Read 10');
    expect(html).not.toContain('Swim');
  });

  it('says so when nothing can be added', () => {
    const html = renderToStaticMarkup(
      React.createElement(ExistingTaskPicker, { tasks: [], onPick: () => {}, onCancel: () => {} }),
    );
    expect(html).toContain('No tasks can be added to this compound.');
  });
});
