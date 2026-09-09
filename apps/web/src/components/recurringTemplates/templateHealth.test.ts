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
      },
    };
    const health = computeRosterHealth([t], resolution, tasksById(nine));
    expect(health.attentionByTemplateId[t.id]).toBe('source_board_missing');
  });

  it('a deleted hand-added task badges has_deleted_tasks and stays out of the count', () => {
    const t = makeTemplate({ manualTaskIds: [...nine, 'dead'] });
    const resolution: Record<string, TemplateSupplyResolution> = {
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: [...nine, 'dead'] },
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
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: ids },
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
      [t.id]: { supplies: [], deadBoardSourceIds: [], manualTaskIds: [] },
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
});
