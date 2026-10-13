import * as fs from 'fs';
import * as path from 'path';
import { isBoardExpiringSoon, type ExpiringBoardFields } from '../../src/algorithms/boardExpiry';

/**
 * boardExpiry.test.ts — the "Expiring" board tag's per-timeframe lead time
 * (owner ruling 2026-10-13), driven by `boardExpiryVectors.json` (the same
 * fixture runs on iOS in BoardExpiryVectorTests.swift).
 */

interface ExpiringVector {
  name: string;
  board: ExpiringBoardFields;
  now: string;
  expected: boolean;
}

const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'boardExpiryVectors.json'), 'utf8'),
) as { expiringSoon: ExpiringVector[] };

describe('isBoardExpiringSoon', () => {
  it('has vectors for every timeframe', () => {
    expect(fixture.expiringSoon.length).toBeGreaterThanOrEqual(15);
  });

  it.each(fixture.expiringSoon.map((v) => [v.name, v] as const))('%s', (_name, v) => {
    expect(isBoardExpiringSoon(v.board, new Date(v.now).getTime())).toBe(v.expected);
  });
});
