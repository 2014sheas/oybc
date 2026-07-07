import * as fs from 'fs';
import * as path from 'path';
import {
  SYNC_COLLECTIONS,
  USER_SCOPED_SYNC_COLLECTIONS,
  LEGACY_PULL_SKIP_COLLECTIONS,
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
