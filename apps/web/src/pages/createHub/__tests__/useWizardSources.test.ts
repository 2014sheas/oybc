import { describe, expect, it } from 'vitest';
import { Timeframe, type BoardSource } from '@oybc/shared';
import {
  appendSource,
  boardSupplyEntry,
  droppedSelectionIds,
  removeSourceById,
  toggleIdInSet,
  withResetSourceRange,
  withSourceFilter,
  withSourceRange,
} from '../wizardSourcesLogic';
import { availableCountForSource, selectionUnion, type SupplyInfoMap } from '../wizardSources';

/**
 * `useWizardSources` extraction (B3 Task 3, commit 1) — the nine source
 * actions moved out of `useBoardWizard` unchanged, each delegating to a pure
 * transition in `wizardSourcesLogic.ts`. This repo's Vitest harness is
 * `environment: 'node'` with no hook renderer (see `vitest.config.ts`), so
 * the hook itself is a thin shell and THESE are the behavioural assertions:
 * every case below is the pre-extraction behaviour of the corresponding
 * action, read off `useBoardWizard`'s callbacks.
 */

function makeSource(overrides: Partial<BoardSource> & { sourceId: string }): BoardSource {
  return {
    kind: 'pool',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
    ...overrides,
  };
}

function supplyEntry(
  displayName: string,
  ids: string[],
  doneIds: string[] = [],
): SupplyInfoMap[string] {
  return { displayName, rawSupplyTaskIds: ids, doneTaskIds: new Set(doneIds) };
}

describe('appendSource (pullPool / pullBoard)', () => {
  it('appends a pool row with the default [0, all] range and "all" filter', () => {
    const next = appendSource([], 'pool-1', 'pool');
    expect(next).toEqual([
      {
        sourceId: 'pool-1',
        kind: 'pool',
        min: 0,
        max: null,
        excludedTaskIds: [],
        filter: 'all',
      },
    ]);
  });

  it('appends a board row with kind "board"', () => {
    expect(appendSource([], 'board-1', 'board')[0].kind).toBe('board');
  });

  it('is a no-op (same identity) when the id is already pulled — a re-tap never resets a range', () => {
    const sources = [makeSource({ sourceId: 'pool-1', min: 2, max: 4 })];
    expect(appendSource(sources, 'pool-1', 'pool')).toBe(sources);
  });

  it('appends at the END, preserving row order', () => {
    const sources = [makeSource({ sourceId: 'a' })];
    expect(appendSource(sources, 'b', 'board').map((s) => s.sourceId)).toEqual(['a', 'b']);
  });
});

describe('removeSourceById (removeSource)', () => {
  it('drops only the named row', () => {
    const sources = [makeSource({ sourceId: 'a' }), makeSource({ sourceId: 'b' })];
    expect(removeSourceById(sources, 'a').map((s) => s.sourceId)).toEqual(['b']);
  });

  it('is harmless for an id that was never pulled', () => {
    const sources = [makeSource({ sourceId: 'a' })];
    expect(removeSourceById(sources, 'ghost').map((s) => s.sourceId)).toEqual(['a']);
  });
});

describe('withSourceRange (setSourceRange)', () => {
  const info: SupplyInfoMap = { p1: supplyEntry('Pool', ['x', 'y', 'z']) };

  it('sets min/max on the named row only', () => {
    const sources = [makeSource({ sourceId: 'p1' }), makeSource({ sourceId: 'p2' })];
    const next = withSourceRange(sources, info, 'p1', 1, 2, 8);
    expect(next[0]).toMatchObject({ min: 1, max: 2 });
    expect(next[1]).toMatchObject({ min: 0, max: null });
  });

  it('re-clamps min to min(available, tasksRequired) — defense in depth', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    // available = 3, tasksRequired = 2 → min caps at 2.
    expect(withSourceRange(sources, info, 'p1', 9, null, 2)[0].min).toBe(2);
  });

  it('never lets a numeric max drop below the clamped min', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    expect(withSourceRange(sources, info, 'p1', 3, 1, 8)[0]).toMatchObject({ min: 3, max: 3 });
  });

  it('latches max to "all" as null', () => {
    const sources = [makeSource({ sourceId: 'p1', max: 2 })];
    expect(withSourceRange(sources, info, 'p1', 0, null, 8)[0].max).toBeNull();
  });
});

describe('withResetSourceRange (resetSourceRange / "Use all")', () => {
  it('resets only the named row to [0, all], leaving excludes + filter alone', () => {
    const sources = [
      makeSource({ sourceId: 'p1', min: 2, max: 3, excludedTaskIds: ['x'] }),
      makeSource({ sourceId: 'p2', min: 1, max: 1 }),
    ];
    const next = withResetSourceRange(sources, 'p1');
    expect(next[0]).toMatchObject({ min: 0, max: null, excludedTaskIds: ['x'] });
    expect(next[1]).toMatchObject({ min: 1, max: 1 });
  });
});

describe('withSourceFilter (setSourceFilter)', () => {
  const info: SupplyInfoMap = {
    b1: supplyEntry('Board', ['a', 'b', 'c'], ['b', 'c']),
    p1: supplyEntry('Pool', ['x', 'y']),
  };

  it('flips a BOARD row’s done-filter', () => {
    const sources = [makeSource({ sourceId: 'b1', kind: 'board' })];
    expect(withSourceFilter(sources, info, 'b1', 'todo', 8)[0].filter).toBe('todo');
  });

  it('leaves a POOL row alone (pools carry the field but ignore it)', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    expect(withSourceFilter(sources, info, 'p1', 'todo', 8)[0].filter).toBe('all');
  });

  it('re-clamps every row against the narrowed available count', () => {
    // b1 has 3 squares, 2 done → "todo" leaves 1 available, so min 3 → 1.
    const sources = [makeSource({ sourceId: 'b1', kind: 'board', min: 3 })];
    expect(withSourceFilter(sources, info, 'b1', 'todo', 8)[0].min).toBe(1);
    expect(availableCountForSource(withSourceFilter(sources, info, 'b1', 'todo', 8), info, 'b1')).toBe(1);
  });
});

describe('toggleIdInSet (toggleExpandedSource)', () => {
  it('adds then removes, always returning a NEW set', () => {
    const empty = new Set<string>();
    const opened = toggleIdInSet(empty, 'p1');
    expect(opened.has('p1')).toBe(true);
    expect(opened).not.toBe(empty);
    expect(toggleIdInSet(opened, 'p1').has('p1')).toBe(false);
  });
});

describe('droppedSelectionIds (the commitSources purge diff)', () => {
  it('names the selected ids the next sources array no longer supplies', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    const info: SupplyInfoMap = { p1: supplyEntry('Pool', ['x', 'y']) };
    const selected = selectionUnion(sources, info, new Set(['m']));
    const nextUnion = selectionUnion(removeSourceById(sources, 'p1'), info, new Set(['m']));
    expect(droppedSelectionIds(selected, nextUnion).sort()).toEqual(['x', 'y']);
  });

  it('is empty when nothing left the selection', () => {
    const selected = new Set(['a', 'b']);
    expect(droppedSelectionIds(selected, new Set(['a', 'b', 'c']))).toEqual([]);
  });
});

describe('boardSupplyEntry (the async board-supply effect mapping)', () => {
  it('maps a resolved read onto the cache entry, never pending', () => {
    const entry = boardSupplyEntry({
      displayName: 'Monday',
      supplyTaskIds: ['a', 'b'],
      doneTaskIds: new Set(['b']),
      windowCountByTaskId: { a: 3 },
      sourceWindow: { timeframe: Timeframe.WEEKLY, startDate: '2026-09-14', endDate: null },
    });
    expect(entry).toMatchObject({ displayName: 'Monday', rawSupplyTaskIds: ['a', 'b'] });
    expect(entry.isPending).toBeUndefined();
    // §Member rules (B3) — the windowed counts + source window ride along.
    expect(entry.windowCountByTaskId).toEqual({ a: 3 });
    expect(entry.sourceWindow?.timeframe).toBe(Timeframe.WEEKLY);
  });

  it('maps a null read to an explicit "Deleted board" — resolved, NOT pending', () => {
    const entry = boardSupplyEntry(null);
    expect(entry.displayName).toBe('Deleted board');
    expect(entry.rawSupplyTaskIds).toEqual([]);
    expect(entry.isPending).toBeUndefined();
    expect(entry.sourceWindow).toBeUndefined();
  });
});
