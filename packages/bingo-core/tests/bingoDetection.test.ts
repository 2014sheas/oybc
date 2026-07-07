import * as fs from 'fs';
import * as path from 'path';
import {
  detectBingos,
  formatBingoMessage,
  getHighlightedSquares,
  BingoDetectionResult,
} from '../src/bingoDetection';
import type { BoardSize } from '../src/constants';

/**
 * C1 (issue #267): the fixed-input/fixed-output vector cases are now
 * fixture-driven from `tests/fixtures/bingoDetectionVectors.json` — the
 * SAME file `apps/ios/OYBCTests/BingoDetectionVectorTests.swift` runs
 * through the Swift mirror `BingoDetection` in `Services/BingoDetection.swift`.
 * This REPLACES every pre-C1 `it` block in the `detectBingos` / error-handling
 * / line-ID-format / `formatBingoMessage` / `getHighlightedSquares` describe
 * blocks. The `uncomplete cascade scenarios` describe block (4 `it` blocks)
 * is KEPT hand-written below — those tests call `detectBingos` TWICE (before
 * + after a square is un-completed) and diff the results, so they exercise
 * caller-side orchestration logic, not a single detectBingos input/output pair.
 *
 * Pre-C1: 61 `it` blocks total — 15 (5x5) + 7 (3x3) + 6 (4x4) detectBingos
 * cases, 3 error-handling, 3 line-ID-format, 5 formatBingoMessage, 8
 * getHighlightedSquares, 9 "auto-completed center" detectBingos cases, and
 * 4 uncomplete-cascade cases (kept). Post-C1: 40 detectBingos vectors
 * (31 base-grid + 9 center-autofill) + 3 error + 5 formatBingoMessage + 10
 * getHighlightedSquares = 58 fixture vectors + 4 hand-written cascade tests
 * + 4 "fixture is non-empty" guards = 66 total `it` blocks — a net increase
 * over the pre-C1 61.
 */

const FIXTURE_PATH = path.join(__dirname, 'fixtures/bingoDetectionVectors.json');

interface DetectVector {
  name: string;
  gridSize: number;
  completedIndices: number[];
  expected: BingoDetectionResult;
}

interface ErrorVector {
  name: string;
  completionGrid: boolean[];
  gridSize: number;
  expectedError: string;
}

interface FormatMessageVector {
  name: string;
  result: BingoDetectionResult;
  expected: string | null;
}

interface HighlightVector {
  name: string;
  completedLines: string[];
  gridSize: number;
  expected: number[];
}

interface Fixture {
  detectBingos: DetectVector[];
  errorHandling: ErrorVector[];
  formatBingoMessage: FormatMessageVector[];
  getHighlightedSquares: HighlightVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

function makeGrid(size: number, completed: number[]): boolean[] {
  const grid = new Array(size * size).fill(false);
  for (const i of completed) grid[i] = true;
  return grid;
}

describe('detectBingos (fixture-driven, tests/fixtures/bingoDetectionVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.detectBingos.length).toBeGreaterThan(0);
  });

  for (const v of fixture.detectBingos) {
    it(v.name, () => {
      const grid = makeGrid(v.gridSize, v.completedIndices);
      const result = detectBingos(grid, v.gridSize as BoardSize);
      expect(result).toEqual(v.expected);
    });
  }
});

describe('detectBingos error handling (fixture-driven)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.errorHandling.length).toBeGreaterThan(0);
  });

  for (const v of fixture.errorHandling) {
    it(v.name, () => {
      expect(() => detectBingos(v.completionGrid, v.gridSize as BoardSize)).toThrow(v.expectedError);
    });
  }
});

describe('formatBingoMessage (fixture-driven)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.formatBingoMessage.length).toBeGreaterThan(0);
  });

  for (const v of fixture.formatBingoMessage) {
    it(v.name, () => {
      const result = formatBingoMessage(v.result);
      if (v.expected === null) {
        expect(result).toBeNull();
      } else {
        expect(result).toBe(v.expected);
      }
    });
  }
});

describe('getHighlightedSquares (fixture-driven)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.getHighlightedSquares.length).toBeGreaterThan(0);
  });

  for (const v of fixture.getHighlightedSquares) {
    it(v.name, () => {
      const result = getHighlightedSquares(v.completedLines, v.gridSize as BoardSize);
      expect([...result].sort((a, b) => a - b)).toEqual(v.expected);
    });
  }
});

// ── Uncomplete Cascade Scenarios (kept hand-written — see file header) ──────
describe('uncomplete cascade scenarios', () => {
  const size = 3;
  const total = 9;

  function makeGridLocal(completedIndices: number[]): boolean[] {
    const grid = new Array(total).fill(false);
    for (const i of completedIndices) {
      grid[i] = true;
    }
    return grid;
  }

  it('complete a row then uncomplete one square — bingo disappears', () => {
    const gridBefore = makeGridLocal([0, 1, 2]);
    const before = detectBingos(gridBefore, size);
    expect(before.completedLines).toContain('row_0');

    const gridAfter = makeGridLocal([0, 2]);
    const after = detectBingos(gridAfter, size);
    expect(after.completedLines).not.toContain('row_0');

    const currentLines = new Set(after.completedLines);
    const lostBingos = before.completedLines.filter((l) => !currentLines.has(l));
    expect(lostBingos).toEqual(['row_0']);
  });

  it('complete greenlog then uncomplete one square — isGreenlog becomes false', () => {
    const gridBefore = new Array(total).fill(true);
    const before = detectBingos(gridBefore, size);
    expect(before.isGreenlog).toBe(true);
    expect(before.completedLines.length).toBe(8);

    const gridAfter = makeGridLocal([1, 2, 3, 4, 5, 6, 7, 8]);
    const after = detectBingos(gridAfter, size);
    expect(after.isGreenlog).toBe(false);
    expect(after.completedLines.length).toBeLessThan(before.completedLines.length);
  });

  it('uncomplete a square that affects multiple bingos — both lost', () => {
    const gridBefore = makeGridLocal([1, 3, 4, 5, 7]);
    const before = detectBingos(gridBefore, size);
    expect(before.completedLines).toContain('row_1');
    expect(before.completedLines).toContain('col_1');

    const gridAfter = makeGridLocal([1, 3, 5, 7]);
    const after = detectBingos(gridAfter, size);
    expect(after.completedLines).not.toContain('row_1');
    expect(after.completedLines).not.toContain('col_1');

    const currentLines = new Set(after.completedLines);
    const lostBingos = before.completedLines.filter((l) => !currentLines.has(l));
    expect(lostBingos).toContain('row_1');
    expect(lostBingos).toContain('col_1');
    expect(lostBingos.length).toBe(2);
  });

  it('uncomplete a non-bingo square — no bingos lost', () => {
    const gridBefore = makeGridLocal([0, 1, 2, 3, 5, 8]);
    const before = detectBingos(gridBefore, size);
    expect(before.completedLines).toContain('row_0');
    expect(before.completedLines).toContain('col_2');

    const gridAfter = makeGridLocal([0, 1, 2, 5, 8]);
    const after = detectBingos(gridAfter, size);

    const currentLines = new Set(after.completedLines);
    const lostBingos = before.completedLines.filter((l) => !currentLines.has(l));
    expect(lostBingos).toEqual([]);
    expect(after.completedLines).toContain('row_0');
    expect(after.completedLines).toContain('col_2');
  });
});
