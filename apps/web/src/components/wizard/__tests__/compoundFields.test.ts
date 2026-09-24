import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { OperatorType } from '@oybc/shared';
import { CompoundFields } from '../CompoundFields';
import { emptyPatch, type ChildPatch, type TaskEditPatch } from '../../../db/taskEditPatch';

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
  return renderToStaticMarkup(React.createElement(CompoundFields, { draft, onDraftChange: () => {} }));
}

const TWO_CHILD_AND: TaskEditPatch = {
  ...emptyPatch('Morning routine'),
  operator: OperatorType.AND,
  children: [child('c-1', 'Stretch'), child('c-2', 'Read', { isCounting: true, action: 'Read', goal: '10', unit: 'pages' })],
};

describe('CompoundFields', () => {
  it('renders each sub-task, the operator picker and both add buttons', () => {
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
