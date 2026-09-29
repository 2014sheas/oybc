import * as fs from 'fs';
import * as path from 'path';
import {
  hasExplicitCoreBoardSetup,
  resolveCoreBoardSetupDefaults,
} from '../../src/algorithms/coreBoardSetupDefaults';
import { CenterSquareType } from '../../src/constants/enums';
import type { BoardSize } from '../../src/constants';
import type { CoreBoardDefault } from '../../src/types/coreBoardDefault';
import type { DefaultCenterSquareType } from '../../src/types/user';

/**
 * coreBoardSetupDefaults.test.ts — per-timeframe size + centre resolution
 * (docs/POOLS_RECURRING.md §Per-timeframe size + centre, 2026-09-29).
 *
 * Fully fixture-driven from `tests/fixtures/coreBoardSetupDefaultsVectors.json`
 * — the SAME file `apps/ios/OYBCTests/CoreBoardSetupDefaultsVectorTests.swift`
 * runs through the Swift mirror in `Helpers/CoreBoardSetupDefaults.swift`.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/coreBoardSetupDefaultsVectors.json');

interface OverridePair {
  defaultBoardSize?: BoardSize | null;
  defaultCenterType?: DefaultCenterSquareType | null;
}

interface Vector {
  name: string;
  coreDefault?: OverridePair | null;
  prefs: { defaultBoardSize: BoardSize; defaultCenterType: DefaultCenterSquareType };
  expected: { boardSize: BoardSize; centerType: CenterSquareType; hasExplicitSetup: boolean };
}

interface Fixture {
  vectors: Vector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

/**
 * A JSON `null` field is not a legal value on the TS row type (`?:` only),
 * but a Swift `nil` covers both absent and null — so the fixture carries a
 * null-fields vector and the TS side maps null → absent here, exactly as
 * the ops layer stores a clear.
 */
function toCoreDefault(pair: OverridePair | null | undefined): Pick<CoreBoardDefault, 'defaultBoardSize' | 'defaultCenterType'> | null | undefined {
  if (pair === undefined) return undefined;
  if (pair === null) return null;
  const row: Pick<CoreBoardDefault, 'defaultBoardSize' | 'defaultCenterType'> = {};
  if (pair.defaultBoardSize != null) row.defaultBoardSize = pair.defaultBoardSize;
  if (pair.defaultCenterType != null) row.defaultCenterType = pair.defaultCenterType;
  return row;
}

describe('resolveCoreBoardSetupDefaults (fixture vectors)', () => {
  it('fixture has vectors', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const coreDefault = toCoreDefault(v.coreDefault);
      expect(resolveCoreBoardSetupDefaults(coreDefault, v.prefs)).toEqual({
        boardSize: v.expected.boardSize,
        centerType: v.expected.centerType,
      });
      expect(hasExplicitCoreBoardSetup(coreDefault)).toBe(v.expected.hasExplicitSetup);
    });
  }

  it('covers the even-size coercion, both inherit paths, and the null-vs-undefined distinction', () => {
    const names = new Set(fixture.vectors.map((v) => v.name));
    expect(names.has('no-row-inherits-both')).toBe(true);
    expect(names.has('null-row-inherits-both')).toBe(true);
    expect(names.has('override-size-only-keeps-prefs-centre')).toBe(true);
    expect(names.has('override-centre-only-keeps-prefs-size')).toBe(true);
    expect(names.has('override-both')).toBe(true);
    expect(names.has('even-size-override-with-free-override-coerces-to-none')).toBe(true);
  });
});

describe('resolveCoreBoardSetupDefaults (direct)', () => {
  const prefs = { defaultBoardSize: 5 as BoardSize, defaultCenterType: CenterSquareType.FREE as DefaultCenterSquareType };

  it('never returns CHOSEN — the centre is always FREE or NONE', () => {
    const out = resolveCoreBoardSetupDefaults({ defaultBoardSize: 3, defaultCenterType: CenterSquareType.FREE }, prefs);
    expect([CenterSquareType.FREE, CenterSquareType.NONE]).toContain(out.centerType);
  });

  it('does not read any other row field (a full row with extra keys resolves the same as the pair)', () => {
    const full = {
      id: 'x', userId: 'u', timeframe: 'daily', corePoolIds: ['p'], coreDefaultTaskIds: [],
      defaultBoardSize: 3 as BoardSize, createdAt: 't', updatedAt: 't', version: 1, isDeleted: false,
    } as unknown as CoreBoardDefault;
    expect(resolveCoreBoardSetupDefaults(full, prefs)).toEqual({ boardSize: 3, centerType: CenterSquareType.FREE });
    expect(hasExplicitCoreBoardSetup(full)).toBe(true);
  });
});
