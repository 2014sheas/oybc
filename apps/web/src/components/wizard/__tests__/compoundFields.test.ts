import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  OperatorType,
  TaskType,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { CompoundFields, type LibraryInputsState } from '../CompoundFields';
import { selectQuickAddMatches } from '../../pools/poolEditSheetSelectors';
import { WizardQuickAddRow } from '../WizardQuickAddRow';
import {
  appendPickedChild,
  appendTypedChild,
  emptyPatch,
  isNewChild,
  subtaskQuickAddCandidates,
  liveChildren,
  type ChildPatch,
  type TaskEditPatch,
} from '../../../db/taskEditPatch';

/**
 * CompoundFields is the rule + sub-task editor shared by the wizard's inline
 * pool-row editor and the Task Detail edit sheet. Rendered with
 * `react-dom/server` (no jsdom/RTL harness in this repo), so this pins the
 * markup: sub-task cards, the operator picker, the wizard's quick-add row
 * (+ New sub: Normal / Counting chips), and the "at least N" stepper's
 * bounds; the two append paths are pure helpers pinned directly.
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
    childType: over.childType ?? (over.isCounting ? TaskType.COUNTING : TaskType.NORMAL),
  };
}

function render(draft: TaskEditPatch, libraryInputsState?: LibraryInputsState): string {
  return renderToStaticMarkup(
    React.createElement(CompoundFields, {
      draft,
      onDraftChange: () => {},
      parentId: 'P',
      libraryTasks: [],
      allLinks: [],
      libraryInputsState,
    }),
  );
}

const TWO_CHILD_AND: TaskEditPatch = {
  ...emptyPatch('Morning routine'),
  operator: OperatorType.AND,
  children: [child('c-1', 'Stretch'), child('c-2', 'Read', { isCounting: true, action: 'Read', goal: '10', unit: 'pages' })],
};

describe('CompoundFields', () => {
  it('renders each sub-task, the operator picker and the quick-add row with the New sub chips', () => {
    const html = render(TWO_CHILD_AND);
    expect(html).toContain('value="Stretch"');
    expect(html).toContain('value="Read"');
    expect(html).toContain('aria-label="Sub-task 1 title"');
    expect(html).toContain('aria-label="Sub-task 2 unit"');
    expect(html).toContain('All of');
    expect(html).toContain('Any of');
    expect(html).toContain('At least N of');
    // The wizard's own quick-add row: same field, placeholder and Add button.
    expect(html).toContain('aria-label="New normal task title"');
    expect(html).toContain('placeholder="e.g. Meditate 10 min"');
    expect(html).toMatch(/<button[^>]*aria-label="Add task"[^>]*>Add<\/button>/);
    // New sub: Normal (default, pressed) / Counting chips.
    expect(html).toContain('New sub:');
    expect(html).toMatch(/aria-pressed="true"[^>]*>Normal</);
    expect(html).toMatch(/aria-pressed="false"[^>]*>Counting</);
    // Task 7's buttons and picker dialog are gone.
    expect(html).not.toContain('+ Normal sub-task');
    expect(html).not.toContain('+ Counting sub-task');
    expect(html).not.toContain('+ Existing task…');
    expect(html).not.toContain('role="dialog"');
  });

  it('renders the quick-add row byte-identically to the wizard row', () => {
    const row = renderToStaticMarkup(
      React.createElement(WizardQuickAddRow, {
        userId: '',
        onTaskCreated: () => {},
        libraryTasks: [],
        onExistingTaskPicked: () => {},
      }),
    );
    expect(render(TWO_CHILD_AND)).toContain(row);
  });

  it('disables the row and says so while the library loads; flags a failed load', () => {
    const loading = render(TWO_CHILD_AND, 'loading');
    expect(loading).toMatch(/<input[^>]*aria-label="New normal task title"[^>]*disabled=""/);
    expect(loading).toContain('Loading your tasks…');
    const failed = render(TWO_CHILD_AND, 'failed');
    expect(failed).not.toMatch(/<input[^>]*aria-label="New normal task title"[^>]*disabled=""/);
    expect(failed).toContain('role="alert"');
    const loaded = render(TWO_CHILD_AND);
    expect(loaded).not.toContain('Loading your tasks…');
    expect(loaded).not.toContain('role="alert"');
  });

  it('badges each card by its own type — N / # / C — with a matching accessible name', () => {
    const html = render({
      ...TWO_CHILD_AND,
      children: [...TWO_CHILD_AND.children, child('c-3', 'Evening routine', { childType: TaskType.COMPOUND })],
    });
    expect(html).toMatch(/role="img" aria-label="Normal sub-task"[^>]*>N</);
    expect(html).toMatch(/role="img" aria-label="Counting sub-task"[^>]*>#</);
    expect(html).toMatch(/role="img" aria-label="Compound sub-task"[^>]*>C</);
    // A nested compound edits only its title (plus ✕ unlink): no counting fields.
    expect(html).toContain('aria-label="Sub-task 3 title"');
    expect(html).not.toContain('aria-label="Sub-task 3 action"');
    expect(html).not.toContain('aria-label="Sub-task 3 goal"');
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

describe('CompoundFields append paths', () => {
  it('a picked match is appended as a LINKED sub-task (its own id and type)', () => {
    const next = appendPickedChild(TWO_CHILD_AND, task('ok-c', 'Run 5 km', { type: TaskType.COUNTING, action: 'Run', maxCount: 5, unit: 'km' }));
    expect(next.children).toHaveLength(3);
    expect(next.children[2]).toMatchObject({
      id: 'ok-c',
      childTaskId: 'ok-c',
      title: 'Run 5 km',
      isCounting: true,
      childType: TaskType.COUNTING,
      goal: '5',
      unit: 'km',
    });
    // The input draft is untouched (pure).
    expect(TWO_CHILD_AND.children).toHaveLength(2);
  });

  it('Enter appends a NEW Normal sub-task titled with the text', () => {
    const next = appendTypedChild(TWO_CHILD_AND, 'Third', false);
    const added = next.children[2];
    expect(isNewChild(added)).toBe(true);
    expect(added).toMatchObject({ title: 'Third', isCounting: false, childType: TaskType.NORMAL, action: '' });
    expect(liveChildren(next)).toHaveLength(3);
  });

  it('with the Counting chip on, Enter appends a NEW Counting sub-task whose action is the text', () => {
    const next = appendTypedChild(TWO_CHILD_AND, 'Swim', true);
    const added = next.children[2];
    expect(isNewChild(added)).toBe(true);
    expect(added).toMatchObject({ title: 'Swim', action: 'Swim', isCounting: true, childType: TaskType.COUNTING, goal: '', unit: '' });
    // Live (non-blank title) — the card then asks for its Goal / Unit.
    expect(liveChildren(next)).toHaveLength(3);
  });
});

describe('CompoundFields quick-add candidates', () => {
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

  const draft: TaskEditPatch = { ...TWO_CHILD_AND, children: [child('c-1', 'Stretch')] };

  it('offers only eligible tasks — no self, current child, loop, achievement, or incomplete counter', () => {
    const titles = subtaskQuickAddCandidates('P', library, links, draft).map((t) => t.title);
    expect(titles).toEqual(['Journal', 'Run 5 km']);
  });

  it('the row matches typed text against those candidates only', () => {
    const candidates = subtaskQuickAddCandidates('P', library, links, draft);
    // "r" hits Journal / Run 5 km / Read 10 / Morning routine / Stretch in the raw
    // library — only the eligible two survive.
    expect(selectQuickAddMatches(candidates, new Set(), 'r').map((t) => t.title)).toEqual(['Journal', 'Run 5 km']);
    expect(selectQuickAddMatches(candidates, new Set(), 'stret')).toEqual([]);
  });
});
