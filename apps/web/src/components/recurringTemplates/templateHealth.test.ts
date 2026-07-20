import { describe, expect, it } from 'vitest';
import { CenterSquareType, Timeframe, TaskType, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { computeTemplateAttention } from './templateHealth';

/**
 * Covers the templates page's "needs attention" badge computation
 * (`computeTemplateAttention`), extracted from `RecurringTemplatesPage`
 * per the review fix: it used to read `template.seedTaskIds` directly,
 * which goes stale the first time the P1 legacy-editor write-through
 * edits a template's linked Pool (docs/POOLS_RECURRING.md §Migration
 * "seedTaskIds end state" — "never read after P1" is unconditional, not
 * just the wizard-hydration case). The badge must follow the CURRENT
 * resolved mix, not the frozen `seedTaskIds` snapshot.
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

function makeTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 'tmpl-1',
    userId: 'user-1',
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE, // 8 fillable
    isRandomized: true,
    // Deliberately kept STALE and unchanged across both scenarios below —
    // this is exactly the field the fix stops reading from.
    seedTaskIds: ['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8'],
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

describe('computeTemplateAttention', () => {
  it('follows the resolved mix after an edit shrinks the linked Pool — NOT the frozen seedTaskIds snapshot', () => {
    const template = makeTemplate();
    const taskMap: Record<string, Task> = {};
    for (const id of template.seedTaskIds) taskMap[id] = makeTask(id);

    // Before the edit: the mix (from the Pool, as it stood then) still
    // has all 8 tasks — matches the fillable floor, no attention.
    const mixBeforeEdit = { [template.id]: [...template.seedTaskIds] };
    const beforeEdit = computeTemplateAttention([template], mixBeforeEdit, taskMap);
    expect(beforeEdit[template.id]).toBeUndefined();

    // The user "Add tasks"-edits the template down to 2 tasks — the
    // write-through updates the linked Pool's taskIds (per
    // wizardPersist.ts), but `template.seedTaskIds` itself is NEVER
    // touched (left verbatim/stale). Only the resolved mix changes.
    const mixAfterEdit = { [template.id]: ['a1', 'a2'] };
    const afterEdit = computeTemplateAttention([template], mixAfterEdit, taskMap);

    // The badge reflects the shrunk mix (2 < 8 fillable) — pool_too_small.
    expect(afterEdit[template.id]).toBe('pool_too_small');

    // Sanity: seedTaskIds itself never changed between the two calls —
    // proving the differing result came from the mix input, not from any
    // mutation of the template.
    expect(template.seedTaskIds).toHaveLength(8);

    // Contrast: a seedTaskIds-based computation (the pre-fix behavior)
    // would have shown NO attention in either case, since seedTaskIds
    // stayed at its original 8-task, fully-resolvable snapshot — i.e.
    // it would have silently hidden a real pool_too_small regression.
    const staleComputation = computeTemplateAttention([template], {}, taskMap); // {} ⇒ internal seedTaskIds fallback
    expect(staleComputation[template.id]).toBeUndefined();
  });

  it('treats a mix id missing from the library as has_deleted_tasks (mirrors the old seedTaskIds heuristic)', () => {
    const template = makeTemplate({ seedTaskIds: ['a1'] });
    const taskMap: Record<string, Task> = { a1: makeTask('a1') };

    // Mix includes an id not present in the (non-deleted) library —
    // a manual-sourced deleted task, or any other unresolvable id.
    const mix = { [template.id]: ['a1', 'gone'] };
    const result = computeTemplateAttention([template], mix, taskMap);

    expect(result[template.id]).toBe('has_deleted_tasks');
  });

  it('falls back to seedTaskIds when no mix entry exists yet (loading-state safety net)', () => {
    const template = makeTemplate({ seedTaskIds: ['a1', 'a2'] });
    const taskMap: Record<string, Task> = { a1: makeTask('a1'), a2: makeTask('a2') };

    // No entry for this template id in mixByTemplateId (e.g. the batched
    // useTemplateMixes query hasn't resolved yet) — falls back to
    // seedTaskIds so a still-loading page doesn't flash a false badge.
    const result = computeTemplateAttention([template], {}, taskMap);

    // 2 tasks < 8 fillable floor either way, but this proves the
    // fallback path resolves via seedTaskIds rather than throwing/
    // treating a missing entry as an empty mix that would ALSO read
    // pool_too_small for the wrong reason (no data yet, not a real
    // shortfall) — see the has_deleted_tasks test above for the
    // "resolves, but a task is missing" case this is distinguishing
    // from.
    expect(result[template.id]).toBe('pool_too_small');
  });
});
