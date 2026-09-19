import { describe, expect, it } from 'vitest';
import { TaskType, type BoardSource, type Pool, type Task } from '@oybc/shared';
import {
  algorithmSupplies,
  availableCountForSource,
  buildSupplyInfoMap,
  clampAllSourceRanges,
  clampSourceRange,
  computeCounterClashes,
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

describe('Split-up expansion (§Member rules B3, RC7)', () => {
  const compound = { id: 'c1', type: TaskType.COMPOUND };
  const children = {
    c1: [
      { childTaskId: 'k1', childIndex: 0 },
      { childTaskId: 'k2', childIndex: 1 },
      { childTaskId: 'k3', childIndex: 2 },
    ],
  };
  const info: SupplyInfoMap = { b1: supplyEntry('Board', ['c1', 'x']) };

  function splitSource(parts?: Record<string, { excluded?: boolean }>): BoardSource {
    return makeSource({
      sourceId: 'b1',
      kind: 'board',
      memberRules: { c1: { split: true, ...(parts ? { parts } : {}) } },
    });
  }

  it('a split compound supplies its parts instead of itself, in childIndex order', () => {
    const supplies = algorithmSupplies([splitSource()], info, children, { c1: compound });
    expect(supplies[0].supplyTaskIds).toEqual(['k1', 'k2', 'k3', 'x']);
    expect(supplies[0].partOf).toEqual({ k1: 'c1', k2: 'c1', k3: 'c1' });
  });

  it('available count grows by parts − 1 − excluded parts', () => {
    const sources = [splitSource()];
    // Un-split: 2 members (c1, x).
    expect(availableCountForSource([makeSource({ sourceId: 'b1', kind: 'board' })], info, 'b1'))
      .toBe(2);
    // Split into 3 parts: 2 + (3 − 1) = 4.
    expect(availableCountForSource(sources, info, 'b1', children, { c1: compound })).toBe(4);
    // One part excluded: 4 − 1 = 3.
    const oneOut = [splitSource({ k2: { excluded: true } })];
    expect(availableCountForSource(oneOut, info, 'b1', children, { c1: compound })).toBe(3);
  });

  it('capacity and the selection union see the parts, not the compound', () => {
    const sources = [splitSource()];
    expect(sourceCapacity(sources, info, new Set(), undefined, undefined, children, { c1: compound }))
      .toBe(4);
    const union = selectionUnion(sources, info, new Set(), children, { c1: compound });
    expect([...union].sort()).toEqual(['k1', 'k2', 'k3', 'x']);
  });

  it('excluding the compound removes its parts too (excludes apply before expansion)', () => {
    const sources = [
      makeSource({
        sourceId: 'b1',
        kind: 'board',
        excludedTaskIds: ['c1'],
        memberRules: { c1: { split: true } },
      }),
    ];
    expect(availableCountForSource(sources, info, 'b1', children, { c1: compound })).toBe(1);
  });

  it('omitting the children/tasks maps leaves every split rule stale-inert', () => {
    expect(availableCountForSource([splitSource()], info, 'b1')).toBe(2);
  });

  it('a split rule on a childless or non-compound member does nothing', () => {
    const sources = [
      makeSource({ sourceId: 'b1', kind: 'board', memberRules: { x: { split: true } } }),
    ];
    expect(availableCountForSource(sources, info, 'b1', children, { c1: compound })).toBe(2);
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

describe('counter-family exclusivity in the wizard math (2026-09-08)', () => {
  const fam = { r20: 'root', r50: 'root' };

  it('sourceCapacity counts a family once — the honest number before any deal', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    const info: SupplyInfoMap = { p1: supplyEntry('One', ['r20', 'r50', 'a']) };
    expect(sourceCapacity(sources, info, new Set(), fam)).toBe(2);
    // Without the family map the same shape counted 3.
    expect(sourceCapacity(sources, info, new Set())).toBe(3);
  });

  it('a hand-added family member still counts once against a source-supplied mate', () => {
    const sources = [makeSource({ sourceId: 'p1' })];
    const info: SupplyInfoMap = { p1: supplyEntry('One', ['r50', 'a']) };
    expect(sourceCapacity(sources, info, new Set(['r20']), fam)).toBe(2);
  });

  it('computeCounterClashes maps each colliding member to the OTHER title', () => {
    const task = (id: string, title: string): Task =>
      ({
        id,
        userId: 'u',
        title,
        type: TaskType.COUNTING,
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      }) as Task;
    const clashes = computeCounterClashes(
      ['r20', 'r50', 'a'],
      fam,
      { r20: task('r20', 'Read 20 pages'), r50: task('r50', 'Read 50 pages') },
    );
    expect(clashes.get('r20')).toBe('Read 50 pages');
    expect(clashes.get('r50')).toBe('Read 20 pages');
    expect(clashes.has('a')).toBe(false);
  });

  it('a lone family member is never flagged as a clash', () => {
    expect(computeCounterClashes(['r20', 'a'], fam, {}).size).toBe(0);
  });
});

describe('buildSupplyInfoMap — pending vs deleted (late-mutation audit, shape B)', () => {
  const poolSource: BoardSource = {
    sourceId: 'p1', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all',
  };
  const boardSource: BoardSource = {
    sourceId: 'b1', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all',
  };

  it('an unresolved pool is PENDING, never "Deleted pool"', () => {
    // THE regression: before the pools query resolved, the row read
    // "Deleted pool · 0 squares", capacity went 0, the red gate lit and
    // Next was disabled — then it all corrected.
    const pending = buildSupplyInfoMap([poolSource], {}, false, {}, {});
    expect(pending.p1.isPending).toBe(true);
    expect(pending.p1.displayName).not.toBe('Deleted pool');
  });

  it('a pool that is genuinely gone AFTER load reads as deleted', () => {
    const loaded = buildSupplyInfoMap([poolSource], {}, true, {}, {});
    expect(loaded.p1.isPending).toBeUndefined();
    expect(loaded.p1.displayName).toBe('Deleted pool');
  });

  it('a resolved pool reads its real name and supply', () => {
    const pool = {
      id: 'p1', userId: 'u1', name: 'Morning', taskIds: ['t1'],
      createdAt: 'x', updatedAt: 'x', version: 1, isDeleted: false,
    } as Pool;
    const task = { id: 't1', userId: 'u1', title: 'T', type: TaskType.NORMAL, isDeleted: false } as Task;
    const map = buildSupplyInfoMap([poolSource], { p1: pool }, true, { t1: task }, {});
    expect(map.p1.isPending).toBeUndefined();
    expect(map.p1.displayName).toBe('Morning');
    expect(map.p1.rawSupplyTaskIds).toEqual(['t1']);
  });

  it('a board source is PENDING until its async fetch writes an entry', () => {
    const pending = buildSupplyInfoMap([boardSource], {}, true, {}, {});
    expect(pending.b1.isPending).toBe(true);

    const resolved = buildSupplyInfoMap([boardSource], {}, true, {}, {
      b1: { displayName: 'Deleted board', rawSupplyTaskIds: [], doneTaskIds: new Set() },
    });
    expect(resolved.b1.isPending).toBeUndefined();
    expect(resolved.b1.displayName).toBe('Deleted board');
  });
});

describe('pending supply keeps capacity honest for the GATE (review-caught Critical)', () => {
  // The first attempt at this fix wired the pending flag into an
  // effectively-unused validation message while the REAL Next gate
  // (`capacity >= tasksRequired` in BoardWizardTasksStep) kept blocking.
  // These assert the inputs that gate consumes.
  const poolSource: BoardSource = {
    sourceId: 'p1', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all',
  };

  it('a pending source contributes 0 capacity — so the gate MUST consult isPending, not capacity alone', () => {
    const pending = buildSupplyInfoMap([poolSource], {}, false, {}, {});
    expect(sourceCapacity([poolSource], pending, new Set())).toBe(0);
    // ...which is exactly why `suppliesPending` has to reach the gate:
    // capacity 0 here means "unknown", not "you're short".
    expect(pending.p1.isPending).toBe(true);
  });

  it('once resolved, the same source reports real capacity', () => {
    const pool = {
      id: 'p1', userId: 'u1', name: 'Morning', taskIds: ['t1', 't2'],
      createdAt: 'x', updatedAt: 'x', version: 1, isDeleted: false,
    } as Pool;
    const tasks: Record<string, Task> = {
      t1: { id: 't1', userId: 'u1', title: 'A', type: TaskType.NORMAL, isDeleted: false } as Task,
      t2: { id: 't2', userId: 'u1', title: 'B', type: TaskType.NORMAL, isDeleted: false } as Task,
    };
    const loaded = buildSupplyInfoMap([poolSource], { p1: pool }, true, tasks, {});
    expect(loaded.p1.isPending).toBeUndefined();
    expect(sourceCapacity([poolSource], loaded, new Set())).toBe(2);
  });
});
