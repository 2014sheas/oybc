import { describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { computeTemplateMixes } from '../useTemplateMixes';

/**
 * Pure-function coverage for `computeTemplateMixes` — the batched,
 * per-template mix resolver `useTemplateMixes` delegates to (see that
 * hook's docstring: this repo's Vitest harness is `environment: 'node'`,
 * so a `useLiveQuery`-based hook can't be exercised directly; splitting
 * out the pure resolution logic keeps it testable, mirroring
 * `wizardTimeframeSeed.ts`'s precedent for `useBoardWizard`).
 */

const NOW = '2026-07-19T00:00:00.000Z';

function makeTask(id: string): Task {
  return {
    id,
    userId: 'user-1',
    title: id,
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

function makePool(id: string, taskIds: string[]): Pool {
  return {
    id,
    userId: 'user-1',
    name: id,
    taskIds,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

function makeTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'tmpl-1',
    userId: 'user-1',
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: ['stale-1', 'stale-2'],
    poolIds: ['pool-1'],
    manualTaskIds: [],
    removedTaskIds: [],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('computeTemplateMixes', () => {
  it('resolves a migrated template through poolsById/tasksById, ignoring seedTaskIds', () => {
    const template = makeTemplate({ poolIds: ['pool-1'] });
    const poolsById = { 'pool-1': makePool('pool-1', ['a1', 'a2', 'a3']) };
    const tasksById = { a1: makeTask('a1'), a2: makeTask('a2'), a3: makeTask('a3') };

    const result = computeTemplateMixes([template], poolsById, tasksById);

    expect(result[template.id]).toEqual(['a1', 'a2', 'a3']);
  });

  it('reflects a pool edit — same template id, new poolsById snapshot, new result (not the frozen seedTaskIds)', () => {
    const template = makeTemplate({ poolIds: ['pool-1'] });
    const tasksById = {
      a1: makeTask('a1'),
      a2: makeTask('a2'),
      a3: makeTask('a3'),
      b1: makeTask('b1'),
    };

    const beforeEdit = computeTemplateMixes(
      [template],
      { 'pool-1': makePool('pool-1', ['a1', 'a2', 'a3']) },
      tasksById,
    );
    expect(beforeEdit[template.id]).toEqual(['a1', 'a2', 'a3']);

    // The user edited the template ("Add tasks") — the linked Pool's
    // taskIds changed (write-through, per wizardPersist.ts). The
    // template object itself (incl. its stale seedTaskIds) is UNCHANGED.
    const afterEdit = computeTemplateMixes(
      [template],
      { 'pool-1': makePool('pool-1', ['b1']) },
      tasksById,
    );
    expect(afterEdit[template.id]).toEqual(['b1']);
    expect(afterEdit[template.id]).not.toEqual(beforeEdit[template.id]);
    expect(template.seedTaskIds).toEqual(['stale-1', 'stale-2']); // never touched
  });

  it('falls back to seedTaskIds when poolIds is undefined (genuinely un-migrated)', () => {
    const template = makeTemplate({ poolIds: undefined, manualTaskIds: undefined, removedTaskIds: undefined });

    const result = computeTemplateMixes([template], {}, {});

    expect(result[template.id]).toEqual(template.seedTaskIds);
  });

  it('falls back to seedTaskIds when poolIds is an empty array (the "no pool yet" edge, matching wizardPersist)', () => {
    const template = makeTemplate({ poolIds: [], manualTaskIds: [], removedTaskIds: [] });

    const result = computeTemplateMixes([template], {}, {});

    expect(result[template.id]).toEqual(template.seedTaskIds);
  });

  it('batches multiple templates independently in one call', () => {
    const t1 = makeTemplate({ id: 'tmpl-1', poolIds: ['pool-1'], seedTaskIds: ['x'] });
    const t2 = makeTemplate({ id: 'tmpl-2', poolIds: ['pool-2'], seedTaskIds: ['y'] });
    const poolsById = {
      'pool-1': makePool('pool-1', ['a1']),
      'pool-2': makePool('pool-2', ['a2']),
    };
    const tasksById = { a1: makeTask('a1'), a2: makeTask('a2') };

    const result = computeTemplateMixes([t1, t2], poolsById, tasksById);

    expect(result['tmpl-1']).toEqual(['a1']);
    expect(result['tmpl-2']).toEqual(['a2']);
  });
});
