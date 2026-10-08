import * as fs from 'fs';
import * as path from 'path';
import {
  comparePullWatermarks,
  nextPullWatermark,
  type PullWatermark,
} from '../../src/algorithms/pullWatermark';
import { nextPullWatermark as fromBarrel } from '../../src';

interface Fixture {
  cases: Array<{
    name: string;
    prev: PullWatermark | null;
    syncedAts: Array<PullWatermark | null>;
    expected: PullWatermark | null;
  }>;
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/pullWatermarkVectors.json');
const vectors: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

describe('nextPullWatermark vectors', () => {
  it.each(vectors.cases)('$name', ({ prev, syncedAts, expected }) => {
    expect(nextPullWatermark(prev, syncedAts)).toEqual(expected);
  });

  it('treats an undefined prev and undefined entries like null', () => {
    expect(nextPullWatermark(undefined, [undefined, { seconds: 3, nanoseconds: 0 }])).toEqual({
      seconds: 3,
      nanoseconds: 0,
    });
  });

  it('is exported from the package barrel', () => {
    expect(fromBarrel).toBe(nextPullWatermark);
  });
});

describe('comparePullWatermarks', () => {
  it('orders by seconds, then nanoseconds', () => {
    expect(comparePullWatermarks({ seconds: 1, nanoseconds: 9 }, { seconds: 2, nanoseconds: 0 })).toBeLessThan(0);
    expect(comparePullWatermarks({ seconds: 2, nanoseconds: 1 }, { seconds: 2, nanoseconds: 0 })).toBeGreaterThan(0);
    expect(comparePullWatermarks({ seconds: 2, nanoseconds: 0 }, { seconds: 2, nanoseconds: 0 })).toBe(0);
  });
});
