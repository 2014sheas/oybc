import * as fs from 'fs';
import * as path from 'path';

/**
 * Cross-platform fixture-twin sync guard (workstream C1 / issue #267).
 *
 * Generalizes the per-file byte-identity check C4 (`syncContract.test.ts`)
 * hand-wrote for its two fixtures into ONE test that walks every JSON
 * fixture under `packages/shared/tests/fixtures/` and
 * `packages/bingo-core/tests/fixtures/` and asserts its checked-in iOS
 * bundle copy (`apps/ios/OYBCTests/Fixtures/<name>.json`) is byte-identical.
 *
 * xcodegen cannot bundle a resource from outside the iOS project root
 * (`apps/ios/`) — a path escaping that root is silently dropped — so every
 * fixture that drives an XCTest vector suite needs a real checked-in copy
 * there. Regenerate all copies in one step with:
 *   pnpm --filter @oybc/shared run gen:sync-fixtures
 *
 * This test does NOT regenerate anything — it only catches an un-synced
 * copy (hand-edited one side without re-running the sync script).
 */

const SOURCE_DIRS = [
  { label: 'packages/shared/tests/fixtures', dir: path.join(__dirname) },
  {
    label: 'packages/bingo-core/tests/fixtures',
    dir: path.join(__dirname, '../../../bingo-core/tests/fixtures'),
  },
];
const IOS_FIXTURES_DIR = path.join(__dirname, '../../../../apps/ios/OYBCTests/Fixtures');
const REGEN_HINT =
  'Run `pnpm --filter @oybc/shared run gen:sync-fixtures` to regenerate the iOS copies, then commit the result.';

describe('fixture twin sync (iOS bundle copies)', () => {
  it('apps/ios/OYBCTests/Fixtures exists', () => {
    expect(fs.existsSync(IOS_FIXTURES_DIR)).toBe(true);
  });

  const allCanonicalFiles: Array<{ label: string; name: string; canonicalPath: string }> = [];
  for (const { label, dir } of SOURCE_DIRS) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      allCanonicalFiles.push({ label, name, canonicalPath: path.join(dir, name) });
    }
  }

  it('found at least one canonical fixture to check', () => {
    expect(allCanonicalFiles.length).toBeGreaterThan(0);
  });

  for (const { label, name, canonicalPath } of allCanonicalFiles) {
    it(`${name} (from ${label}) is byte-identical to its apps/ios/OYBCTests/Fixtures copy (${REGEN_HINT})`, () => {
      const iosCopyPath = path.join(IOS_FIXTURES_DIR, name);
      expect(fs.existsSync(iosCopyPath)).toBe(true);
      const canonical = fs.readFileSync(canonicalPath, 'utf8');
      const iosCopy = fs.readFileSync(iosCopyPath, 'utf8');
      expect(iosCopy).toEqual(canonical);
    });
  }
});
