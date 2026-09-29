import * as fs from 'fs';
import * as path from 'path';
import {
  SYNC_COLLECTIONS,
  USER_SCOPED_SYNC_COLLECTIONS,
  LEGACY_PULL_SKIP_COLLECTIONS,
  CLEARABLE_BOARD_FIELDS,
  CLEARABLE_FIELDS_BY_COLLECTION,
  clearableFieldsFor,
} from '../../src/constants';

/**
 * This test does NOT generate the fixture — it only asserts that the
 * checked-in `tests/fixtures/syncContract.json` still matches the live
 * TS constants in `src/constants/syncContract.ts`.
 *
 * iOS can't import TypeScript, so `apps/ios/OYBCTests/SyncContractTests.swift`
 * asserts its own `SyncService.swift` lists against this same JSON file
 * (bundled as a test resource). That makes this fixture the cross-platform
 * enforcement surface: if you edit the TS constants without regenerating
 * the fixture, THIS test fails on the shared-package side; if the iOS
 * lists then drift out of step with the (correctly regenerated) fixture,
 * the iOS suite fails on that side. Either way, drift becomes a test
 * failure instead of a silent divergence.
 *
 * Regenerate with: `pnpm --filter @oybc/shared run gen:sync-contract`
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/syncContract.json');
const IOS_COPY_PATH = path.join(
  __dirname,
  '../../../../apps/ios/OYBCTests/Fixtures/syncContract.json',
);
const REGENERATE_HINT =
  'Fixture out of sync with src/constants/syncContract.ts. ' +
  'Run `pnpm --filter @oybc/shared run gen:sync-contract` to regenerate ' +
  'tests/fixtures/syncContract.json, then commit the result.';

describe('syncContract fixture', () => {
  it('exists (generate it before running this test)', () => {
    expect(fs.existsSync(FIXTURE_PATH)).toBe(true);
  });

  const raw = fs.existsSync(FIXTURE_PATH) ? fs.readFileSync(FIXTURE_PATH, 'utf8') : '{}';
  const fixture = JSON.parse(raw) as {
    syncCollections?: string[];
    userScopedSyncCollections?: string[];
    legacyPullSkipCollections?: string[];
    clearableBoardFields?: string[];
    clearableFieldsByCollection?: Record<string, string[]>;
  };

  it(`syncCollections matches SYNC_COLLECTIONS (${REGENERATE_HINT})`, () => {
    expect(fixture.syncCollections).toEqual([...SYNC_COLLECTIONS]);
  });

  it(`userScopedSyncCollections matches USER_SCOPED_SYNC_COLLECTIONS (${REGENERATE_HINT})`, () => {
    expect(fixture.userScopedSyncCollections).toEqual([...USER_SCOPED_SYNC_COLLECTIONS]);
  });

  it(`legacyPullSkipCollections matches LEGACY_PULL_SKIP_COLLECTIONS (${REGENERATE_HINT})`, () => {
    expect(fixture.legacyPullSkipCollections).toEqual([...LEGACY_PULL_SKIP_COLLECTIONS]);
  });

  it(`clearableBoardFields matches CLEARABLE_BOARD_FIELDS (${REGENERATE_HINT})`, () => {
    expect(fixture.clearableBoardFields).toEqual([...CLEARABLE_BOARD_FIELDS]);
  });

  it('CLEARABLE_BOARD_FIELDS keeps the two pre-slice-4 fields and adds the seal pair (D2)', () => {
    expect([...CLEARABLE_BOARD_FIELDS]).toEqual([
      'endDate',
      'completedAt',
      'sealedAt',
      'sealedCompletedCells',
    ]);
  });

  it(`clearableFieldsByCollection matches CLEARABLE_FIELDS_BY_COLLECTION (${REGENERATE_HINT})`, () => {
    expect(fixture.clearableFieldsByCollection).toEqual(
      Object.fromEntries(
        Object.entries(CLEARABLE_FIELDS_BY_COLLECTION).map(([k, v]) => [k, [...v]]),
      ),
    );
  });

  it('CLEARABLE_BOARD_FIELDS is the boards entry of the per-collection map', () => {
    expect(CLEARABLE_BOARD_FIELDS).toBe(CLEARABLE_FIELDS_BY_COLLECTION.boards);
  });

  it('coreBoardDefaults clears its per-timeframe size + centre overrides (2026-09-29)', () => {
    expect([...CLEARABLE_FIELDS_BY_COLLECTION.coreBoardDefaults]).toEqual([
      'defaultBoardSize',
      'defaultCenterType',
    ]);
  });

  it('every clearable collection is a real sync collection', () => {
    for (const name of Object.keys(CLEARABLE_FIELDS_BY_COLLECTION)) {
      expect([...SYNC_COLLECTIONS]).toContain(name);
    }
  });

  it('clearableFieldsFor returns the map entry, and [] for a collection with none', () => {
    expect(clearableFieldsFor('boards')).toEqual([...CLEARABLE_BOARD_FIELDS]);
    expect(clearableFieldsFor('coreBoardDefaults')).toEqual(['defaultBoardSize', 'defaultCenterType']);
    expect(clearableFieldsFor('tasks')).toEqual([]);
    expect(clearableFieldsFor('not-a-collection')).toEqual([]);
  });
});

describe('syncContract iOS bundle copy', () => {
  // xcodegen cannot bundle a resource from outside apps/ios (a path
  // escaping the project root is silently dropped), so
  // apps/ios/OYBCTests/Fixtures/syncContract.json is a checked-in copy
  // that `SyncContractTests.swift` reads from the test bundle. This test
  // is the guard against that copy going stale: `gen:sync-contract`
  // writes both locations in one run, so if they ever diverge, someone
  // hand-edited one without regenerating.
  const IOS_COPY_HINT =
    'apps/ios/OYBCTests/Fixtures/syncContract.json has drifted from ' +
    'tests/fixtures/syncContract.json. Run ' +
    '`pnpm --filter @oybc/shared run gen:sync-contract` to regenerate both, ' +
    'then commit the result.';

  it(`is byte-identical to tests/fixtures/syncContract.json (${IOS_COPY_HINT})`, () => {
    expect(fs.existsSync(IOS_COPY_PATH)).toBe(true);
    const canonical = fs.readFileSync(FIXTURE_PATH, 'utf8');
    const iosCopy = fs.readFileSync(IOS_COPY_PATH, 'utf8');
    expect(iosCopy).toEqual(canonical);
  });
});
