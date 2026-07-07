#!/usr/bin/env node
/**
 * Copies every hand-authored cross-platform test-vector fixture into the iOS
 * test bundle's checked-in copy folder.
 *
 * Generalizes the fixture-twin mechanism introduced by workstream C4 (issue
 * #261 — `packages/shared/tests/fixtures/lwwVectors.json` /
 * `syncContract.json` + `apps/ios/OYBCTests/Fixtures/*.json`) to workstream
 * C1 (issue #267): every JSON test-vector fixture under
 * `packages/shared/tests/fixtures/` and `packages/bingo-core/tests/fixtures/`
 * gets an identical copy under `apps/ios/OYBCTests/Fixtures/`, so one JSON
 * file drives both the Jest suite (reads the canonical copy directly) and
 * the XCTest suite (reads the iOS bundle copy — xcodegen cannot bundle a
 * resource from outside the iOS project root, so a real file must live
 * there).
 *
 * `packages/shared/tests/fixtures/fixtureSync.test.ts` asserts every iOS
 * copy stays byte-identical to its canonical source — an un-synced copy
 * fails the Jest run, not just the iOS one.
 *
 * `syncContract.json` is a special case — its canonical source is actually
 * `src/constants/syncContract.ts`, and `generate-sync-contract.js` already
 * regenerates + copies it in one step. Running this script afterwards is a
 * harmless no-op re-copy for that one file.
 *
 * Run after adding or editing a hand-authored fixture:
 *   pnpm --filter @oybc/shared run gen:sync-fixtures
 */
const fs = require('fs');
const path = require('path');

const SOURCES = [
  path.join(__dirname, '..', 'tests', 'fixtures'),
  path.join(__dirname, '..', '..', 'bingo-core', 'tests', 'fixtures'),
];
const IOS_FIXTURES_DIR = path.join(
  __dirname,
  '..',
  '..',
  '..',
  'apps',
  'ios',
  'OYBCTests',
  'Fixtures',
);

function main() {
  fs.mkdirSync(IOS_FIXTURES_DIR, { recursive: true });

  let copied = 0;
  for (const dir of SOURCES) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json')) continue;
      const src = path.join(dir, name);
      const dest = path.join(IOS_FIXTURES_DIR, name);
      fs.copyFileSync(src, dest);
      console.log(`Copied ${path.relative(process.cwd(), src)} -> ${path.relative(process.cwd(), dest)}`);
      copied += 1;
    }
  }

  if (copied === 0) {
    throw new Error('No fixture .json files found to copy — check SOURCES paths.');
  }
}

main();
