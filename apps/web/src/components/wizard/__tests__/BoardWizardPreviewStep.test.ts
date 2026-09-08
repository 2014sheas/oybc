import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type BoardSource,
  type Task,
} from '@oybc/shared';
import { BoardWizardPreviewStep } from '../BoardWizardPreviewStep';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../../pages/createPage/useTaskLibrary';

/**
 * A repeating board re-randomizes its cell layout every window, so the
 * Preview step shows a SUMMARY CARD (Board Sources P4, handoff frame 5b:
 * name, cadence, one row per source with its range line, the hand-added
 * rows, and the SQUARES total) instead of the arrangeable `ArrangeGrid` +
 * Preview/Rearrange toggle + Shuffle. One-off boards keep the existing
 * ArrangeGrid behavior unchanged.
 *
 * The footer still diverges per mode (Board Creation Split, web PR C+D):
 * one-off has a RED "Activate Board"; recurring a BLUE "Create Board",
 * with "Save as Draft" only for a FRESH recurring session (omitted when
 * `editingTemplateId` is set — an edit has no "draft" concept).
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
    poolOrder: [],
    sources: [] as BoardSource[],
    manualTaskIds: new Set<string>(),
    supplyInfoBySourceId: {},
    expandedSourceIds: new Set<string>(),
    pulledPoolIds: [],
    removedTaskIds: new Set<string>(),
    capacity: 8,
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

describe('BoardWizardPreviewStep — repeating-board summary-card view (frame 5b)', () => {
  it('shows the summary card (source range lines + hand-added rows + Squares total), and hides ArrangeGrid/Preview⇄Rearrange/Shuffle, when isRecurring', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const pool1Source: BoardSource = {
      sourceId: 'pool-1',
      kind: 'pool',
      min: 3,
      max: 5,
      excludedTaskIds: [],
      filter: 'all',
    };
    const controller = makeController({
      isRecurring: true,
      sources: [pool1Source],
      supplyInfoBySourceId: {
        'pool-1': {
          displayName: 'Morning Kickstart',
          rawSupplyTaskIds: ['p1', 'p2', 'p3', 'p4', 'p5', 'p6'],
          doneTaskIds: new Set<string>(),
        },
      },
      poolOrder: ['t1', 't2'],
      manualTaskIds: new Set(['t1', 't2']),
      selectedTaskIds: new Set(['t1', 't2', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6']),
      capacity: 7,
      tasksRequired: 8,
    });

    const html = renderPreview(controller, tasks);

    // Summary card: source row with its right-aligned range line, every
    // hand-added task as its own row, and the SQUARES total.
    expect(html).toContain('Morning Kickstart');
    expect(html).toContain('3–5');
    expect(html).toContain('Task t1');
    expect(html).toContain('Task t2');
    expect(html).toContain('Squares');
    expect(html).toContain('7');
    expect(html).toContain('/8');

    // No arrangeable-grid affordances for a repeating board, no
    // provenance subtitles (the design's copy rule).
    expect(html).not.toContain('Shuffle');
    expect(html).not.toContain('Rearrange');
    expect(html).not.toContain('added by hand');
  });

  it('shows a "Create Board" primary AND "Save as Draft" for a fresh recurring session (web PR D)', () => {
    const tasks = [makeTask('t1'), makeTask('t2')];
    const controller = makeController({
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      selectedTaskIds: new Set(['t1', 't2']),
      editingTemplateId: null,
    });

    const html = renderPreview(controller, tasks);

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

    expect(html).not.toContain('Squares');
    expect(html).toContain('Rearrange');
    expect(html).toContain('Activate Board');
    expect(html).toContain('Save as Draft');
  });
});
