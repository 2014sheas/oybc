import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CenterSquareType, Timeframe, TaskType, type Task } from '@oybc/shared';
import { BoardWizardPreviewStep } from '../BoardWizardPreviewStep';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../../pages/createPage/useTaskLibrary';

/**
 * A repeating board re-randomizes its cell layout every window, so the
 * Preview step shows the resolved pool (task list) instead of the
 * arrangeable `ArrangeGrid` + Preview/Rearrange toggle + Shuffle. One-off
 * boards keep the existing ArrangeGrid behavior unchanged.
 *
 * Board Creation Split (web PR C) also diverges the footer + summary
 * card per mode: one-off has NO summary card and a RED "Activate Board";
 * recurring has a 3-row Repeats/Size/Pool summary card and a BLUE
 * "Create Board". Web PR D added recurring's own "Save as Draft" (neutral,
 * same as one-off's) for a FRESH recurring session — omitted only when
 * `editingTemplateId` is set (editing an existing repeating board has no
 * "draft" concept; footer is Back / "Save Changes" only).
 *
 * See `BoardSetupForm.test.ts`'s docstring for why this uses
 * `react-dom/server`'s `renderToStaticMarkup` (no jsdom/RTL harness in
 * this repo) rather than a component-interaction test.
 */

const NOW = '2026-07-19T00:00:00.000Z';

function makeTask(id: string): Task {
  return {
    id,
    userId: 'user-1',
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

function makeController(overrides: Partial<BoardWizardController> = {}): BoardWizardController {
  return {
    name: 'Daily Workout',
    size: 3,
    timeframe: Timeframe.DAILY,
    customStartDate: '',
    customEndDate: '',
    centerType: CenterSquareType.FREE,
    isRandomized: true,
    weekStartDay: 'monday',
    isRecurring: true,
    selectedTaskIds: new Set<string>(),
    centerTaskId: null,
    pulledPoolIds: [],
    manualTaskIds: new Set<string>(),
    removedTaskIds: new Set<string>(),
    pendingTasks: new Map(),
    currentStep: 3,
    draftBoardId: null,
    editingTemplateId: null,
    isCore: false,
    targetWindowDate: null,
    tasksRequired: 8,
    centerMode: false,
    isStep1Valid: true,
    isStep2Valid: true,
    step1ValidationMessage: null,
    step2ValidationMessage: null,
    isPristine: false,
    taskProvenance: new Map<string, string>(),
    goToStep: () => {},
    ...overrides,
  } as unknown as BoardWizardController;
}

function makeLibrary(tasks: Task[]): TaskLibrary {
  const taskMap: Record<string, Task> = {};
  for (const t of tasks) taskMap[t.id] = t;
  return {
    allTasks: tasks,
    allCompoundChildren: [],
    taskMap,
    compoundChildrenByCompound: {},
    childTaskIds: new Set<string>(),
    childToParents: {},
  };
}

function renderPreview(controller: BoardWizardController, tasks: Task[]): string {
  return renderToStaticMarkup(
    React.createElement(BoardWizardPreviewStep, {
      controller,
      library: makeLibrary(tasks),
      userId: 'user-1',
      onBack: () => {},
      onComplete: () => {},
    }),
  );
}

describe('BoardWizardPreviewStep — repeating-board pool-list view', () => {
  it('shows the "On your board" pool header + task list, and hides ArrangeGrid/Preview⇄Rearrange/Shuffle, when isRecurring', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: true,
      selectedTaskIds: new Set(['t1', 't2']),
      taskProvenance: new Map([
        ['t1', 'added by hand'],
        ['t2', 'added by hand'],
      ]),
    });

    const html = renderPreview(controller, tasks);

    // Pool-list header (no health-note line — Board Creation Split, web
    // PR C — straight from name/meta to the list) + both rows.
    expect(html).toContain('On your board');
    expect(html).toContain('Task t1');
    expect(html).toContain('Task t2');
    expect(html).toContain('added by hand');

    // No arrangeable-grid affordances for a repeating board.
    expect(html).not.toContain('Shuffle');
    expect(html).not.toContain('Rearrange');
    expect(html).not.toContain('Preview ⇄ Rearrange');
  });

  it('shows the recurring 3-row summary card (Repeats/Size/Pool), a "Create Board" primary, AND "Save as Draft" for a fresh recurring session (web PR D)', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      selectedTaskIds: new Set(['t1', 't2']),
      editingTemplateId: null,
    });

    const html = renderPreview(controller, tasks);

    expect(html).toContain('Repeats');
    expect(html).toContain('Size');
    expect(html).toContain('Pool');
    expect(html).toContain('Create Board');
    expect(html).toContain('Save as Draft');
    expect(html).not.toContain('Save Changes');
    expect(html).not.toContain('template');
    expect(html).not.toContain('spawn');
  });

  it('omits "Save as Draft" when editing an existing repeating board, showing "Save Changes" instead (no "draft" concept for an edit)', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      selectedTaskIds: new Set(['t1', 't2']),
      editingTemplateId: 'tmpl-1',
    });

    const html = renderPreview(controller, tasks);

    expect(html).toContain('Save Changes');
    expect(html).not.toContain('Save as Draft');
    expect(html).not.toContain('Create Board');
  });

  it('keeps the existing ArrangeGrid / Preview⇄Rearrange behavior for a one-off board, with no summary card', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: false,
      selectedTaskIds: new Set(['t1', 't2']),
    });

    const html = renderPreview(controller, tasks);

    expect(html).not.toContain('On your board');
    expect(html).toContain('Rearrange');
    expect(html).toContain('Activate Board');
    expect(html).toContain('Save as Draft');
    // No Repeats/Size/Pool summary card for a one-off board.
    expect(html).not.toContain('>Repeats<');
  });
});
