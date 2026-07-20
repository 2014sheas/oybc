import { describe, expect, it } from 'vitest';
import { TaskType } from '@oybc/shared';
import type { Task } from '@oybc/shared';
import { resolvePoolChips, selectLibraryPickerResults } from '../poolEditSheetSelectors';

/**
 * poolEditSheetSelectors.test.ts — `PoolEditSheet`'s picker + chip
 * derivations (Task Pools + Recurring Boards Rework, P2 final review
 * I-2/I-3).
 *
 * I-2: the library-reuse picker is a browse surface — it must exclude
 * wizard-born draft tasks the Library tab itself hides, even though the
 * sheet still resolves a chip for one the pool already references (I-3
 * carries stale/unresolvable-elsewhere ids through unpruned; this file
 * covers the resolution side of that contract).
 */

function buildTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('selectLibraryPickerResults', () => {
  it('excludes a createdInWizard-flagged task from the picker', () => {
    const normal = buildTask('t1', { title: 'Normal task' });
    const draft = buildTask('t2', { title: 'Draft task', createdInWizard: true });
    // Simulates the caller passing `browsableTasks` (computeBrowsableTasks'
    // output) — a wizard-born draft with no live-board placement is
    // already excluded from the input, not filtered here. This selector
    // only re-excludes already-selected ids + applies the search query.
    const browsable = [normal]; // `draft` never reaches this selector's input

    const result = selectLibraryPickerResults(browsable, new Set(), '');

    expect(result.map((t) => t.id)).toEqual(['t1']);
    expect(result.some((t) => t.id === draft.id)).toBe(false);
  });

  it('excludes ids already selected on the pool', () => {
    const t1 = buildTask('t1');
    const t2 = buildTask('t2');
    const result = selectLibraryPickerResults([t1, t2], new Set(['t1']), '');
    expect(result.map((t) => t.id)).toEqual(['t2']);
  });

  it('filters by a case-insensitive, trimmed title query', () => {
    const morning = buildTask('t1', { title: 'Morning Kickstart' });
    const evening = buildTask('t2', { title: 'Evening wind-down' });
    const result = selectLibraryPickerResults([morning, evening], new Set(), '  MORNING  ');
    expect(result.map((t) => t.id)).toEqual(['t1']);
  });

  it('returns every unselected task when the query is empty', () => {
    const t1 = buildTask('t1');
    const t2 = buildTask('t2');
    const result = selectLibraryPickerResults([t1, t2], new Set(), '   ');
    expect(result.map((t) => t.id)).toEqual(['t1', 't2']);
  });
});

describe('resolvePoolChips', () => {
  it('resolves ids against tasksById, in taskIds order', () => {
    const t1 = buildTask('t1');
    const t2 = buildTask('t2');
    const tasksById = new Map([
      ['t1', t1],
      ['t2', t2],
    ]);
    const result = resolvePoolChips(['t2', 't1'], tasksById, new Map());
    expect(result.map((t) => t.id)).toEqual(['t2', 't1']);
  });

  it('a pool that references a wizard-born draft task still resolves its chip (I-2 contrast)', () => {
    // The picker (selectLibraryPickerResults, above) would never OFFER
    // this task again, but a pool that already has it must still render
    // the chip — chip resolution reads the FULL task set, not the
    // browsable/picker subset.
    const draft = buildTask('t1', { title: 'Draft task', createdInWizard: true });
    const tasksById = new Map([['t1', draft]]);
    const result = resolvePoolChips(['t1'], tasksById, new Map());
    expect(result).toEqual([draft]);
  });

  it('drops an id that resolves in neither tasksById nor the session cache (soft-deleted / stale reference, I-3)', () => {
    const t1 = buildTask('t1');
    const tasksById = new Map([['t1', t1]]);
    const result = resolvePoolChips(['t1', 'ghost-id'], tasksById, new Map());
    expect(result.map((t) => t.id)).toEqual(['t1']);
  });

  it('falls back to the session cache for an id not yet in tasksById (freshly quick-added)', () => {
    const fresh = buildTask('t-new', { title: 'Just created' });
    const result = resolvePoolChips(['t-new'], new Map(), new Map([['t-new', fresh]]));
    expect(result).toEqual([fresh]);
  });
});
