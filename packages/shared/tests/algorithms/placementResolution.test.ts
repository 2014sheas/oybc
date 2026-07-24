import * as fs from 'fs';
import * as path from 'path';
import type { BoardTask } from '../../src/types';
import {
  comparePlacementPrecedence,
  pickPlacementWinner,
  resolvePlacements,
  computePlacementIntegrityRepair,
} from '../../src/algorithms/placementResolution';

/**
 * Runs the hand-authored cross-platform vector fixture
 * (`tests/fixtures/placementResolutionVectors.json`) through the shared
 * `resolvePlacements` / `computePlacementIntegrityRepair`. The SAME fixture
 * is exercised on the iOS side against the Swift mirrors (Board-integrity
 * PR-2) — both suites passing is what proves the two implementations agree.
 */

interface RawPlacement {
  id: string;
  row: number;
  col: number;
  taskId: string;
  version: number;
  updatedAt: string;
  isDeleted?: boolean;
}

interface ResolvePlacementsVector {
  name: string;
  boardSize: number;
  placements: RawPlacement[];
  expectedSurvivorIds: string[];
}

interface RepairVector {
  name: string;
  boardSize: number;
  livePlacements: RawPlacement[];
  expectedTombstoneIds: string[];
}

interface Fixture {
  resolvePlacementsVectors: ResolvePlacementsVector[];
  repairVectors: RepairVector[];
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/placementResolutionVectors.json');
const IOS_COPY_PATH = path.join(
  __dirname,
  '../../../../apps/ios/OYBCTests/Fixtures/placementResolutionVectors.json',
);
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8')) as Fixture;

/** Fill in the BoardTask fields the vectors omit (irrelevant to the winner rule). */
function toBoardTask(raw: RawPlacement): BoardTask {
  return {
    id: raw.id,
    boardId: 'board-1',
    taskId: raw.taskId,
    row: raw.row,
    col: raw.col,
    isCenter: false,
    createdAt: raw.updatedAt,
    updatedAt: raw.updatedAt,
    version: raw.version,
    isDeleted: raw.isDeleted ?? false,
  };
}

describe('placementResolutionVectors fixture', () => {
  it('is non-empty on both sides', () => {
    expect(fixture.resolvePlacementsVectors.length).toBeGreaterThan(0);
    expect(fixture.repairVectors.length).toBeGreaterThan(0);
  });
});

describe('resolvePlacements — cross-platform vectors', () => {
  it.each(fixture.resolvePlacementsVectors.map((v) => [v.name, v] as const))(
    '%s',
    (_name, vector) => {
      const rows = vector.placements.map(toBoardTask);
      const resolved = resolvePlacements(rows, vector.boardSize);
      expect(resolved.map((bt) => bt.id).sort()).toEqual([...vector.expectedSurvivorIds].sort());
    },
  );

  it('is order-independent (shuffled input resolves to the same survivor set)', () => {
    const vector = fixture.resolvePlacementsVectors.find(
      (v) => v.name === 'three-way-collision-single-winner',
    )!;
    const rows = vector.placements.map(toBoardTask);
    const forward = resolvePlacements(rows, vector.boardSize);
    const reversed = resolvePlacements([...rows].reverse(), vector.boardSize);
    expect(forward.map((bt) => bt.id)).toEqual(reversed.map((bt) => bt.id));
  });

  it('output is sorted by (row, col, id) — matches the iOS ORDER BY row, col, id read ordering', () => {
    const rows: BoardTask[] = [
      toBoardTask({ id: 'bt-z', row: 2, col: 0, taskId: 't1', version: 1, updatedAt: '2026-06-01T00:00:00.000Z' }),
      toBoardTask({ id: 'bt-a', row: 0, col: 1, taskId: 't2', version: 1, updatedAt: '2026-06-01T00:00:00.000Z' }),
      toBoardTask({ id: 'bt-m', row: 0, col: 0, taskId: 't3', version: 1, updatedAt: '2026-06-01T00:00:00.000Z' }),
    ];
    const resolved = resolvePlacements(rows, 3);
    expect(resolved.map((bt) => bt.id)).toEqual(['bt-m', 'bt-a', 'bt-z']);
  });
});

describe('computePlacementIntegrityRepair — cross-platform vectors', () => {
  it.each(fixture.repairVectors.map((v) => [v.name, v] as const))('%s', (_name, vector) => {
    const rows = vector.livePlacements.map(toBoardTask);
    const { toTombstone } = computePlacementIntegrityRepair(rows, vector.boardSize);
    expect(toTombstone.map((bt) => bt.id).sort()).toEqual([...vector.expectedTombstoneIds].sort());
  });

  it('is idempotent — repairing the post-repair survivor set tombstones nothing further', () => {
    for (const vector of fixture.repairVectors) {
      const rows = vector.livePlacements.map(toBoardTask);
      const first = computePlacementIntegrityRepair(rows, vector.boardSize);
      const tombstonedIds = new Set(first.toTombstone.map((bt) => bt.id));
      const survivors = rows.filter((bt) => !tombstonedIds.has(bt.id));
      const second = computePlacementIntegrityRepair(survivors, vector.boardSize);
      expect(second.toTombstone).toEqual([]);
    }
  });

  it('is order-independent (shuffled input tombstones the same losers)', () => {
    const vector = fixture.repairVectors.find(
      (v) => v.name === 'combined-cell-collision-then-task-duplicate-cascades-to-one-survivor',
    )!;
    const rows = vector.livePlacements.map(toBoardTask);
    const forward = computePlacementIntegrityRepair(rows, vector.boardSize);
    const reversed = computePlacementIntegrityRepair([...rows].reverse(), vector.boardSize);
    expect(forward.toTombstone.map((bt) => bt.id).sort()).toEqual(
      reversed.toTombstone.map((bt) => bt.id).sort(),
    );
  });
});

describe('comparePlacementPrecedence / pickPlacementWinner — unit behavior', () => {
  it('a single-row group returns that row as the winner', () => {
    const only = toBoardTask({ id: 'bt-only', row: 0, col: 0, taskId: 't1', version: 1, updatedAt: '2026-06-01T00:00:00.000Z' });
    expect(pickPlacementWinner([only])).toBe(only);
  });

  it('throws on an empty group (caller contract — callers never invoke with zero rows)', () => {
    expect(() => pickPlacementWinner([])).toThrow();
  });

  it('unparseable updatedAt on both sides degrades to the id tie-break rather than throwing', () => {
    const a = toBoardTask({ id: 'bt-a', row: 0, col: 0, taskId: 't1', version: 1, updatedAt: 'not-a-date' });
    const b = toBoardTask({ id: 'bt-b', row: 0, col: 0, taskId: 't2', version: 1, updatedAt: 'also-not-a-date' });
    expect(comparePlacementPrecedence(a, b)).toBeLessThan(0); // 'bt-a' < 'bt-b'
    expect(pickPlacementWinner([b, a]).id).toBe('bt-a');
  });

  it('comparing a row to itself returns 0', () => {
    const a = toBoardTask({ id: 'bt-a', row: 0, col: 0, taskId: 't1', version: 1, updatedAt: '2026-06-01T00:00:00.000Z' });
    expect(comparePlacementPrecedence(a, a)).toBe(0);
  });
});

describe('placementResolutionVectors iOS bundle copy', () => {
  // Same story as lwwVectors.json — xcodegen can't bundle a resource from
  // outside apps/ios, so apps/ios/OYBCTests/Fixtures/placementResolutionVectors.json
  // is a checked-in copy the Swift vector tests read. Hand-authored (not
  // script-generated beyond the copy step) — run
  // `pnpm --filter @oybc/shared run gen:sync-fixtures` after editing vectors.
  it('is byte-identical to tests/fixtures/placementResolutionVectors.json', () => {
    expect(fs.existsSync(IOS_COPY_PATH)).toBe(true);
    const canonical = fs.readFileSync(FIXTURE_PATH, 'utf8');
    const iosCopy = fs.readFileSync(IOS_COPY_PATH, 'utf8');
    expect(iosCopy).toEqual(canonical);
  });
});
