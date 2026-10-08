import * as fs from 'fs';
import * as path from 'path';
import { boardDerivedStateChanged, type BoardDerivedState } from '../../src/algorithms/boardDerivedState';
import { boardDerivedStateChanged as fromBarrel } from '../../src';

interface Fixture {
  cases: Array<{ name: string; before: BoardDerivedState; after: BoardDerivedState; expected: boolean }>;
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/boardDerivedStateVectors.json');
const vectors: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

describe('boardDerivedStateChanged vectors', () => {
  it.each(vectors.cases)('$name', ({ before, after, expected }) => {
    expect(boardDerivedStateChanged(before, after)).toBe(expected);
  });

  it.each(vectors.cases)('is symmetric: $name', ({ before, after, expected }) => {
    expect(boardDerivedStateChanged(after, before)).toBe(expected);
  });

  it('ignores sync metadata (version / updatedAt) on full Board-shaped inputs', () => {
    const before = { completedTasks: 1, totalTasks: 9, linesCompleted: 0, status: 'active', version: 4, updatedAt: 'a' };
    const after = { ...before, version: 5, updatedAt: 'b' };
    expect(boardDerivedStateChanged(before as BoardDerivedState, after as BoardDerivedState)).toBe(false);
  });

  it('is exported from the package barrel', () => {
    expect(fromBarrel).toBe(boardDerivedStateChanged);
  });
});
