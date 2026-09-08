import { describe, expect, it } from 'vitest';
import { TaskType, type BoardSource, type Pool, type Task } from '@oybc/shared';
import {
  algorithmSupplies,
  availableCountForSource,
  clampAllSourceRanges,
  clampSourceRange,
  excludeFromEverySupplier,
  isDefaultRange,
  poolSupplyEntry,
  selectionUnion,
  sourceCapacity,
  sourceRangeLine,
  toggleExcludeInSource,
  type SupplyInfoMap,
} from '../wizardSources';

/**
 * Board Sources P4 (docs/BOARD_SOURCES.md) — unit coverage for the
 * wizard's pure sources helpers, the web port of iOS
 * `BoardWizardViewModel+Sources.swift`'s testable core. Locks the worked
 * example from the design doc: deselect-excludes-from-every-supplier,
 * manual-wins-on-reselect, capacity = Σ effective maxes + manual
 * (deduped), and the frame-5b range-line copy.
 */

const NOW = '2026-09-01T00:00:00.000Z';

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

describe('algorithmSupplies', () => {
  it('applies the board "todo" filter to the raw supply; pools pass through', () => {
    const sources = [
      makeSource({ sourceId: 'p1' }),
      makeSource({ sourceId: 'b1', kind: 'board', filter: 'todo' }),
    ];
    const info: SupplyInfoMap = {
      p1: supplyEntry('Pool', ['x', 'y']),
      b1: supplyEntry('Board', ['a', 'b', 'c'], ['b']),
    };
    const supplies = algorithmSupplies(sources, info);
    expect(supplies[0].supplyTaskIds).toEqual(['x', 'y']);
    expect(supplies[1].supplyTaskIds).toEqual(['a', 'c']);
  });

  it('an unresolvable source contributes an empty supply, never throws', () => {
    const sources = [makeSource({ sourceId: 'gone' })];
    expect(algorithmSupplies(sources, {})[0].supplyTaskIds).toEqual([]);
  });
});

describe('selectionUnion + sourceCapacity', () => {
  it('unions available across sources with manual, deduped; capacity counts a shared task once', () => {
    const sources = [makeSource({ sourceId: 'p1' }), makeSource({ sourceId: 'p2' })];
    const info: SupplyInfoMap = {
      p1: supplyEntry('One', ['x', 'y']),
      p2: supplyEntry('Two', ['y', 'z']),
    };
    const union = selectionUnion(sources, info, new Set(['m']));
    expect([...union].sort()).toEqual(['m', 'x', 'y', 'z']);
    // Capacity = unique candidates (4) here — both sources are [0, all].
    expect(sourceCapacity(sources, info, new Set(['m']))).toBe(4);
  });

  it('a numeric max caps what a source can contribute to capacity', () => {
    const sources = [makeSource({ sourceId: 'p1', max: 2 })];
    const info: SupplyInfoMap = { p1: supplyEntry('One', ['a', 'b', 'c', 'd']) };
    expect(sourceCapacity(sources, info, new Set())).toBe(2);
  });

  it('excludes shrink both the union and the capacity', () => {
    const sources = [makeSource({ sourceId: 'p1', excludedTaskIds: ['b'] })];
    const info: SupplyInfoMap = { p1: supplyEntry('One', ['a', 'b', 'c']) };
    expect([...selectionUnion(sources, info, new Set())].sort()).toEqual(['a', 'c']);
    expect(sourceCapacity(sources, info, new Set())).toBe(2);
  });
});

describe('excludeFromEverySupplier (library-sheet deselect)', () => {
  it('excludes the task from EVERY source that supplies it — the old flat-removal semantics', () => {
    const sources = [makeSource({ sourceId: 'p1' }), makeSource({ sourceId: 'p2' })];
    const info: SupplyInfoMap = {
      p1: supplyEntry('One', ['x', 'y']),
      p2: supplyEntry('Two', ['y', 'z']),
    };
    const next = excludeFromEverySupplier(sources, info, 'y', 8);
    expect(next[0].excludedTaskIds).toEqual(['y']);
    expect(next[1].excludedTaskIds).toEqual(['y']);
    // Manual wins on reselect: the union with y hand-added includes it
    // again even though both excludes persist.
    expect(selectionUnion(next, info, new Set(['y'])).has('y')).toBe(true);
    // …and removing the hand-add re-suppresses it.
    expect(selectionUnion(next, info, new Set()).has('y')).toBe(false);
  });

  it('leaves sources that never supplied the task untouched', () => {
    const sources = [makeSource({ sourceId: 'p1' }), makeSource({ sourceId: 'p2' })];
    const info: SupplyInfoMap = {
      p1: supplyEntry('One', ['x']),
      p2: supplyEntry('Two', ['y']),
    };
    const next = excludeFromEverySupplier(sources, info, 'y', 8);
    expect(next[0].excludedTaskIds).toEqual([]);
    expect(next[1].excludedTaskIds).toEqual(['y']);
  });
});

describe('toggleExcludeInSource', () => {
  it('round-trips one member inside ONE source (the panel ✕ / UNDO)', () => {
    const sources = [makeSource({ sourceId: 'p1' }), makeSource({ sourceId: 'p2' })];
    const info: SupplyInfoMap = {
      p1: supplyEntry('One', ['y']),
      p2: supplyEntry('Two', ['y']),
    };
    const excluded = toggleExcludeInSource(sources, info, 'p1', 'y', 8);
    expect(excluded[0].excludedTaskIds).toEqual(['y']);
    expect(excluded[1].excludedTaskIds).toEqual([]);
    const restored = toggleExcludeInSource(excluded, info, 'p1', 'y', 8);
    expect(restored[0].excludedTaskIds).toEqual([]);
  });
});

describe('clampSourceRange / clampAllSourceRanges', () => {
  it('clamps min to min(available, tasksRequired); a numeric max never drops below min', () => {
    const source = makeSource({ sourceId: 'p1', min: 10, max: 12 });
    const clamped = clampSourceRange(source, 6, 8);
    expect(clamped.min).toBe(6);
    expect(clamped.max).toBe(12);
    const boardCap = clampSourceRange(makeSource({ sourceId: 'p1', min: 30 }), 40, 24);
    expect(boardCap.min).toBe(24);
  });

  it('re-clamps every source after an exclude shrinks a supply', () => {
    const sources = [makeSource({ sourceId: 'p1', min: 3, excludedTaskIds: ['a', 'b'] })];
    const info: SupplyInfoMap = { p1: supplyEntry('One', ['a', 'b', 'c', 'd']) };
    const next = clampAllSourceRanges(sources, info, 8);
    // Available = 2 (post-exclude) → min clamps from 3 to 2.
    expect(next[0].min).toBe(2);
  });

  it('returns the same object when nothing changes (identity for memo hygiene)', () => {
    const source = makeSource({ sourceId: 'p1', min: 1, max: 3 });
    expect(clampSourceRange(source, 5, 8)).toBe(source);
  });
});

describe('availableCountForSource', () => {
  it('is post-exclude, post-filter', () => {
    const sources = [
      makeSource({
        sourceId: 'b1',
        kind: 'board',
        filter: 'todo',
        excludedTaskIds: ['c'],
      }),
    ];
    const info: SupplyInfoMap = { b1: supplyEntry('Board', ['a', 'b', 'c'], ['a']) };
    // 3 raw − 1 done (filter) − 1 excluded = 1.
    expect(availableCountForSource(sources, info, 'b1')).toBe(1);
  });
});

describe('sourceRangeLine (frame 5b)', () => {
  it('renders "up to N" / "n–m" / "n" / the board "not done ·" prefix', () => {
    expect(sourceRangeLine(makeSource({ sourceId: 'p' }), 7)).toBe('up to 7');
    expect(sourceRangeLine(makeSource({ sourceId: 'p', min: 3, max: 5 }), 7)).toBe('3–5');
    expect(sourceRangeLine(makeSource({ sourceId: 'p', min: 4, max: 4 }), 7)).toBe('4');
    expect(
      sourceRangeLine(
        makeSource({ sourceId: 'b', kind: 'board', filter: 'todo', max: 2 }),
        6,
      ),
    ).toBe('not done · up to 2');
  });
});

describe('poolSupplyEntry + isDefaultRange', () => {
  it('resolves a pool supply from live lookups, skipping deleted tasks', () => {
    const task = (id: string, isDeleted = false): Task => ({
      id,
      userId: 'u',
      title: id,
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted,
    });
    const pool: Pool = {
      id: 'p1',
      userId: 'u',
      name: 'Morning',
      taskIds: ['a', 'dead', 'b'],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    const entry = poolSupplyEntry(pool, {
      a: task('a'),
      dead: task('dead', true),
      b: task('b'),
    });
    expect(entry.displayName).toBe('Morning');
    expect(entry.rawSupplyTaskIds).toEqual(['a', 'b']);
    expect(entry.doneTaskIds.size).toBe(0);
  });

  it('isDefaultRange is true only for [0, all]', () => {
    expect(isDefaultRange(makeSource({ sourceId: 'p' }))).toBe(true);
    expect(isDefaultRange(makeSource({ sourceId: 'p', min: 1 }))).toBe(false);
    expect(isDefaultRange(makeSource({ sourceId: 'p', max: 5 }))).toBe(false);
  });
});
