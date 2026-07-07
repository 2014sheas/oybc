import * as fs from 'fs';
import * as path from 'path';
import { additiveMergeCount, needsAdditiveMerge } from '../../src/algorithms/sharedCounterMerge';

/**
 * Tests for `additiveMergeCount` and `needsAdditiveMerge` — Phase 4 conflict
 * resolution for shared-counter source tasks.
 *
 * C1 (issue #267): every case in the pre-C1 file was a pure input/output
 * vector, so this file is now FULLY fixture-driven from
 * `tests/fixtures/sharedCounterMergeVectors.json` — the SAME file
 * `apps/ios/OYBCTests/SharedCounterMergeVectorTests.swift` runs through the
 * Swift mirror. Pre-C1: 17 `additiveMergeCount` `it` blocks + 6
 * `needsAdditiveMerge` `it` blocks = 23 assertions across 2 fields each.
 * Post-C1: 15 + 5 = 20 fixture vectors (a few near-duplicate pre-C1 cases —
 * e.g. the two "mergeApplied" spot-checks that just re-asserted an existing
 * vector's flag — collapsed into the vectors that already covered them; no
 * unique input/output pair was dropped).
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/sharedCounterMergeVectors.json');

interface MergeVector {
  name: string;
  localCount: number;
  remoteCount: number;
  lastSyncedCount: number | null;
  merged: number;
  mergeApplied: boolean;
}

interface NeedsMergeVector {
  name: string;
  localCount: number;
  remoteCount: number;
  lastSyncedCount: number | null;
  expected: boolean;
}

interface Fixture {
  additiveMergeCount: MergeVector[];
  needsAdditiveMerge: NeedsMergeVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

describe('additiveMergeCount (fixture-driven, tests/fixtures/sharedCounterMergeVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.additiveMergeCount.length).toBeGreaterThan(0);
  });

  for (const v of fixture.additiveMergeCount) {
    it(v.name, () => {
      const result = additiveMergeCount(v.localCount, v.remoteCount, v.lastSyncedCount);
      expect(result.merged).toBe(v.merged);
      expect(result.mergeApplied).toBe(v.mergeApplied);
    });
  }

  it('result has merged (number) and mergeApplied (boolean)', () => {
    const result = additiveMergeCount(15, 13, 10);
    expect(typeof result.merged).toBe('number');
    expect(typeof result.mergeApplied).toBe('boolean');
  });
});

describe('needsAdditiveMerge (fixture-driven, tests/fixtures/sharedCounterMergeVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.needsAdditiveMerge.length).toBeGreaterThan(0);
  });

  for (const v of fixture.needsAdditiveMerge) {
    it(v.name, () => {
      expect(needsAdditiveMerge(v.localCount, v.remoteCount, v.lastSyncedCount)).toBe(v.expected);
    });
  }
});
