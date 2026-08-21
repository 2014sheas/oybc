import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CenterSquareType, Timeframe, TaskType, type Task } from '@oybc/shared';
import { BoardWizardPreviewStep } from '../BoardWizardPreviewStep';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../../pages/createPage/useTaskLibrary';

/**
 * P4 (Task Pools + Recurring Boards Rework) — a repeating board
 * re-randomizes its cell layout every window, so the Preview step shows
 * the resolved deck (pool of tasks) instead of the arrangeable
 * `ArrangeGrid` + Preview/Rearrange toggle + Shuffle. One-off boards keep
 * the existing ArrangeGrid behavior unchanged.
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

describe('BoardWizardPreviewStep — repeating-board deck view (P4)', () => {
  it('shows the deck header + task list, and hides ArrangeGrid/Preview⇄Rearrange/Shuffle, when isRecurring', () => {
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

    // Deck header (the shared `formatDeckPreview` copy) + both deck rows.
    expect(html).toContain('in the deck');
    expect(html).toContain('Task t1');
    expect(html).toContain('Task t2');
    expect(html).toContain('added by hand');

    // No arrangeable-grid affordances for a repeating board.
    expect(html).not.toContain('Shuffle');
    expect(html).not.toContain('Rearrange');
    expect(html).not.toContain('Preview ⇄ Rearrange');
  });

  it('keeps the existing ArrangeGrid / Preview⇄Rearrange behavior for a one-off board', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: false,
      selectedTaskIds: new Set(['t1', 't2']),
    });

    const html = renderPreview(controller, tasks);

    expect(html).not.toContain('in the deck');
    expect(html).toContain('Rearrange');
  });
});
