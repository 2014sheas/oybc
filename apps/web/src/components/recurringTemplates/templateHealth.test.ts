import { describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type BoardSource,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import type { TemplateSupplyResolution } from '../../db/operations/boardSources';
import { computeRosterHealth } from './templateHealth';

/**
 * Covers the Board-settings roster's sources-native health computation
 * (`computeRosterHealth`, loose-ends sweep 2026-09-09), which supersedes
 * the legacy-trio `computeTemplateAttention` + `computeTemplateMixes`
 * pair. The load-bearing regressions locked here: a board-source-only
 * template is HEALTHY (the legacy path resolved it to an empty mix and
 * badged it), a dead board source badges `source_board_missing`
 * statically (the spawn ask's twin), and counts respect ranges + the
 * counter-family rule.
 */

const NOW = '2026-09-09T00:00:00.000Z';

function makeTask(id: string, overrides: Partial<Task> = {}): Task {
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
    ...overrides,
  };
}

function makeTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'tpl-1',
    userId: 'u1',
    name: 'Roster Board',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.NONE, // 9 fillable cells
    isRandomized: true,
    seedTaskIds: [],
    poolIds: [],
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

function boardSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
}

function poolSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
}

function tasksById(ids: string[], overrides: Record<string, Partial<Task>> = {}): Record<string, Task> {
  const out: Record<string, Task> = {};
  for (const id of ids) out[id] = makeTask(id, overrides[id]);
  return out;
}

const nine = ['s1', 's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9'];

describe('computeRosterHealth', () => {
  it('a board-source-only template is healthy with its squares counted (THE legacy-path regression)', () => {
    const t = makeTemplate({ sources: [boardSource('b1')] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: {
        supplies: [{ source: boardSource('b1'), supplyTaskIds: nine }],
        deadBoardSourceIds: [],
        manualTaskIds: [],
        childrenByCompoundId: {},
      },
    };
    const health = computeRosterHealth([t], resolution, tasksById(nine));
    expect(health.attentionByTemplateId[t.id]).toBeUndefined();
    expect(health.mixByTemplateId[t.id]).toHaveLength(9);
  });

  it('a dead board source badges source_board_missing — the spawn ask, statically', () => {
    const t = makeTemplate({ sources: [boardSource('b-gone'), poolSource('p1')] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: {
        supplies: [
          { source: boardSource('b-gone'), supplyTaskIds: [] },
          { source: poolSource('p1'), supplyTaskIds: nine },
        ],
        deadBoardSourceIds: ['b-gone'],
        manualTaskIds: [],
        childrenByCompoundId: {},
      },
    };
    const health = computeRosterHealth([t], resolution, tasksById(nine));
    expect(health.attentionByTemplateId[t.id]).toBe('source_board_missing');
  });

  it('a deleted hand-added task badges has_deleted_tasks and stays out of the count', () => {
    const t = makeTemplate({ manualTaskIds: [...nine, 'dead'] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: [...nine, 'dead'], childrenByCompoundId: {} },
    };
    const health = computeRosterHealth(
      [t],
      resolution,
      tasksById([...nine, 'dead'], { dead: { isDeleted: true } }),
    );
    expect(health.attentionByTemplateId[t.id]).toBe('has_deleted_tasks');
    expect(health.mixByTemplateId[t.id]).toHaveLength(9);
    expect(health.mixByTemplateId[t.id]).not.toContain('dead');
  });

  it('a numeric range makes pool_too_small honest — raw union ≥ cells but achievable < cells', () => {
    const t = makeTemplate({ sources: [poolSource('p1', { max: 4 })] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: {
        supplies: [{ source: poolSource('p1', { max: 4 }), supplyTaskIds: nine }],
        deadBoardSourceIds: [],
        manualTaskIds: [],
        childrenByCompoundId: {},
      },
    };
    const health = computeRosterHealth([t], resolution, tasksById(nine));
    expect(health.mixByTemplateId[t.id]).toHaveLength(4);
    expect(health.attentionByTemplateId[t.id]).toBe('pool_too_small');
  });

  it('a shared-counter family counts once in the roster mix', () => {
    const ids = ['r20', 'r50', ...nine.slice(0, 8)];
    const t = makeTemplate({ manualTaskIds: ids });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: ids, childrenByCompoundId: {} },
    };
    const health = computeRosterHealth([t], resolution, tasksById(ids, {
      r20: { type: TaskType.COUNTING, maxCount: 20, sharedCounterId: 'r50', baseline: 0 },
      r50: { type: TaskType.COUNTING, maxCount: 50 },
    }));
    const mix = health.mixByTemplateId[t.id];
    expect(mix.filter((id) => id === 'r20' || id === 'r50')).toHaveLength(1);
    expect(mix).toHaveLength(9);
    expect(health.attentionByTemplateId[t.id]).toBeUndefined();
  });

  it('an empty template badges no_pool_tasks_resolved', () => {
    const t = makeTemplate();
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: [], childrenByCompoundId: {} },
    };
    const health = computeRosterHealth([t], resolution, {});
    expect(health.attentionByTemplateId[t.id]).toBe('no_pool_tasks_resolved');
  });

  it('a missing resolution entry falls back to seedTaskIds with no badge (loading safety net)', () => {
    const t = makeTemplate({ seedTaskIds: nine });
    const health = computeRosterHealth([t], {}, {});
    expect(health.mixByTemplateId[t.id]).toEqual(nine);
    expect(health.attentionByTemplateId[t.id]).toBeUndefined();
  });
  it('a Split-up member rule expands the compound into its parts before the count (B2 §Member rules step 1)', () => {
    // The roster count must be the honest one: a compound member the user
    // set to "Split up" contributes its parts, so a 1-member pool with a
    // 3-part compound is 3 squares, not 1 — the same expansion a new
    // window's assembly performs.
    const source = poolSource('p1', { memberRules: { c1: { split: true } } });
    const t = makeTemplate({ sources: [source] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: {
        supplies: [{ source, supplyTaskIds: ['c1', ...nine.slice(0, 6)] }],
        deadBoardSourceIds: [],
        manualTaskIds: [],
        childrenByCompoundId: {
          c1: [
            { id: 'l1', compoundTaskId: 'c1', childTaskId: 'k1', childIndex: 0 },
            { id: 'l2', compoundTaskId: 'c1', childTaskId: 'k2', childIndex: 1 },
            { id: 'l3', compoundTaskId: 'c1', childTaskId: 'k3', childIndex: 2 },
          ] as TemplateSupplyResolution['childrenByCompoundId'][string],
        },
      },
    };
    const tasks = tasksById(['c1', 'k1', 'k2', 'k3', ...nine.slice(0, 6)], {
      c1: { type: TaskType.COMPOUND },
    });

    const health = computeRosterHealth([t], resolution, tasks);

    const mix = health.mixByTemplateId[t.id];
    expect(mix).not.toContain('c1');
    expect(mix).toEqual(expect.arrayContaining(['k1', 'k2', 'k3']));
    expect(mix).toHaveLength(9); // 3 parts + 6 plain members = a full 3x3.
    expect(health.attentionByTemplateId[t.id]).toBeUndefined();
  });
});
