/**
 * Board Sources rework (P1) — vector + unit tests for
 * `algorithms/boardSources.ts` (docs/BOARD_SOURCES.md).
 *
 * The fixture (`tests/fixtures/boardSourceVectors.json`) is the
 * cross-platform contract: the SAME vectors run on iOS in
 * `OYBCTests/BoardSourceVectorTests.swift` against the hand-mirrored
 * `Helpers/BoardSources.swift`, using the identical seeded LCG — both
 * suites passing against byte-identical fixtures is what proves the two
 * implementations agree (the placementResolutionVectors precedent).
 */

import * as fs from 'fs';
import * as path from 'path';
import {
  computeSourceCapacity,
  selectBoardTasks,
  resolveSourceAvailable,
  effectiveSourceMax,
  poolSourceSupplyById,
  sourcesFromMixFields,
  mixFieldsFromSources,
  sourcesForRecord,
  type BoardSource,
  type BoardSourceSupply,
  type Pool,
  type Task,
} from '../../src';
import { TaskType } from '../../src/constants/enums';

/** Cross-platform seeded LCG — twin of bingo-core's tests/seededRng.ts and
 *  the Swift `SeededRng` in the vector suite. Same seed ⇒ same sequence. */
function makeSeededRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

interface FixtureSource extends BoardSource {
  supplyTaskIds: string[];
}
interface Fixture {
  capacityVectors: Array<{
    name: string;
    sources: FixtureSource[];
    manualTaskIds: string[];
    expected: { uniqueCandidateCount: number; cappedBound: number; capacity: number };
  }>;
  selectionVectors: Array<{
    name: string;
    sources: FixtureSource[];
    manualTaskIds: string[];
    cellCount: number;
    rngSeed: number;
    randomize: boolean;
    expected: { ok: true; taskIds: string[] } | { ok: false; shortBy: number };
  }>;
  conversionVectors: Array<{
    name: string;
    record: { poolIds?: string[]; removedTaskIds?: string[]; sources?: BoardSource[] };
    expectedSources: BoardSource[];
    expectedMixFields: { poolIds: string[]; removedTaskIds: string[] };
  }>;
}

const fixture: Fixture = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', 'fixtures', 'boardSourceVectors.json'),
    'utf8',
  ),
);

function toSupply(s: FixtureSource): BoardSourceSupply {
  const { supplyTaskIds, ...source } = s;
  return { source, supplyTaskIds };
}

describe('boardSourceVectors fixture', () => {
  test('fixture is non-empty', () => {
    expect(fixture.capacityVectors.length).toBeGreaterThan(0);
    expect(fixture.selectionVectors.length).toBeGreaterThan(0);
    expect(fixture.conversionVectors.length).toBeGreaterThan(0);
  });

  test.each(fixture.capacityVectors.map((v) => [v.name, v] as const))(
    'capacity: %s',
    (_name, v) => {
      expect(
        computeSourceCapacity(v.sources.map(toSupply), v.manualTaskIds),
      ).toEqual(v.expected);
    },
  );

  test.each(fixture.selectionVectors.map((v) => [v.name, v] as const))(
    'selection: %s',
    (_name, v) => {
      expect(
        selectBoardTasks({
          supplies: v.sources.map(toSupply),
          manualTaskIds: v.manualTaskIds,
          cellCount: v.cellCount,
          randomize: v.randomize,
          rng: makeSeededRng(v.rngSeed),
        }),
      ).toEqual(v.expected);
    },
  );

  test.each(fixture.conversionVectors.map((v) => [v.name, v] as const))(
    'conversion: %s',
    (_name, v) => {
      const sources = sourcesForRecord(v.record);
      expect(sources).toEqual(v.expectedSources);
      expect(mixFieldsFromSources(sources)).toEqual(v.expectedMixFields);
    },
  );
});

describe('resolveSourceAvailable / effectiveSourceMax', () => {
  const src = (over: Partial<BoardSource>): BoardSource => ({
    sourceId: 'pool-1',
    kind: 'pool',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
    ...over,
  });

  test('dedupes a supply that repeats an id', () => {
    expect(
      resolveSourceAvailable({ source: src({}), supplyTaskIds: ['a', 'b', 'a'] }),
    ).toEqual(['a', 'b']);
  });

  test('null max latches to the live available count', () => {
    expect(effectiveSourceMax(src({}), 7)).toBe(7);
    expect(effectiveSourceMax(src({ max: 3 }), 7)).toBe(3);
    expect(effectiveSourceMax(src({ max: 9 }), 7)).toBe(7);
  });
});

describe('selectBoardTasks invariants across seeds', () => {
  // Property-style: for a handful of seeds, every result respects the
  // membership ranges, contains no duplicates, and exactly fills.
  const supplies: BoardSourceSupply[] = [
    {
      source: { sourceId: 'pool-1', kind: 'pool', min: 2, max: 3, excludedTaskIds: ['x'], filter: 'all' },
      supplyTaskIds: ['a', 'b', 'c', 'd', 'x'],
    },
    {
      source: { sourceId: 'board-1', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'todo' },
      supplyTaskIds: ['c', 'e', 'f', 'g'],
    },
  ];
  const manual = ['m1', 'a'];

  test.each([1, 2, 3, 17, 999])('seed %d respects ranges + fills exactly', (seed) => {
    const result = selectBoardTasks({
      supplies,
      manualTaskIds: manual,
      cellCount: 6,
      rng: makeSeededRng(seed),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const ids = result.taskIds;
    expect(ids).toHaveLength(6);
    expect(new Set(ids).size).toBe(6);
    expect(ids).not.toContain('x'); // excluded
    const inPool1 = ids.filter((id) => ['a', 'b', 'c', 'd'].includes(id)).length;
    expect(inPool1).toBeGreaterThanOrEqual(2); // min
    expect(inPool1).toBeLessThanOrEqual(3); // max (binds the manual 'a' too)
  });
});

describe('poolSourceSupplyById', () => {
  const task = (id: string, isDeleted = false): Task =>
    ({
      id,
      userId: 'u1',
      title: id,
      type: TaskType.NORMAL,
      isDeleted,
    } as unknown as Task);
  const pool = (id: string, taskIds: string[], isDeleted = false): Pool =>
    ({
      id,
      userId: 'u1',
      name: id,
      taskIds,
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
      version: 1,
      isDeleted,
    } as Pool);

  const tasksById = {
    a: task('a'),
    b: task('b', true),
  };

  test('filters deleted and missing tasks, keeps pool order', () => {
    expect(
      poolSourceSupplyById('p1', { p1: pool('p1', ['a', 'b', 'ghost']) }, tasksById),
    ).toEqual(['a']);
  });

  test('missing or soft-deleted pool supplies nothing', () => {
    expect(poolSourceSupplyById('nope', {}, tasksById)).toEqual([]);
    expect(
      poolSourceSupplyById('p1', { p1: pool('p1', ['a'], true) }, tasksById),
    ).toEqual([]);
  });
});

describe('behavior-identity with the legacy resolveMix shapes', () => {
  // A migrated record ([0,all] sources carrying flat removals) must yield
  // exactly the old mix's candidate set — the P1 no-behavior-change claim.
  test('sourcesFromMixFields + capacity equals the flat mix size', () => {
    const record = { poolIds: ['p1', 'p2'], removedTaskIds: ['y'] };
    const sources = sourcesFromMixFields(record);
    const poolSupplies: Record<string, string[]> = {
      p1: ['x', 'y'],
      p2: ['y', 'z'],
    };
    const supplies = sources.map((source) => ({
      source,
      supplyTaskIds: poolSupplies[source.sourceId],
    }));
    // Old mix: ({x,y,z} − {y}) + {w} = {x,z,w}
    const { capacity } = computeSourceCapacity(supplies, ['w']);
    expect(capacity).toBe(3);
    const result = selectBoardTasks({
      supplies,
      manualTaskIds: ['w'],
      cellCount: 3,
      rng: makeSeededRng(1),
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(new Set(result.taskIds)).toEqual(new Set(['x', 'z', 'w']));
  });

  test('manual wins over a removal, matching resolveMix', () => {
    // Old rule: a task in BOTH manualTaskIds and removedTaskIds is IN the
    // mix. New shape: the exclude suppresses the SOURCE supply, but the
    // manual layer contributes the id independently.
    const sources = sourcesFromMixFields({ poolIds: ['p1'], removedTaskIds: ['y'] });
    const supplies = sources.map((source) => ({ source, supplyTaskIds: ['x', 'y'] }));
    const { capacity } = computeSourceCapacity(supplies, ['y']);
    expect(capacity).toBe(2); // x from the pool, y via manual
    const result = selectBoardTasks({
      supplies,
      manualTaskIds: ['y'],
      cellCount: 2,
      rng: makeSeededRng(1),
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(new Set(result.taskIds)).toEqual(new Set(['x', 'y']));
  });
});
