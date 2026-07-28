#!/usr/bin/env node
/**
 * Regenerates `tests/fixtures/syncContract.json` from
 * `src/constants/syncContract.ts`.
 *
 * The fixture is what iOS asserts against in
 * `apps/ios/OYBCTests/SyncContractTests.swift` — iOS can't import
 * TypeScript, so this JSON is the cross-platform enforcement surface.
 * `tests/constants/syncContract.test.ts` asserts the checked-in fixture
 * still matches the TS constants; if you edit
 * `src/constants/syncContract.ts` without re-running this script, that
 * Jest test fails.
 *
 * xcodegen cannot add bundle resources from outside the iOS project root
 * (`apps/ios/`) — a path escaping that root is silently dropped with no
 * warning — so this script ALSO writes an identical copy into
 * `apps/ios/OYBCTests/Fixtures/syncContract.json`, which project.yml
 * bundles into the OYBCTests target. `tests/constants/syncContract.test.ts`
 * asserts the two copies are byte-identical, so an un-synced iOS copy
 * fails on the Jest side too.
 *
 * Run after editing the TS source:
 *   pnpm --filter @oybc/shared run gen:sync-contract
 *
 * Uses the TypeScript compiler API (already a devDependency) to
 * transpile the single source file in-memory rather than requiring a
 * full `pnpm build` first or hand-duplicating the arrays here — this
 * script has no independent copy of the data to drift from the TS
 * source.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const ts = require('typescript');

const SRC_PATH = path.join(__dirname, '..', 'src', 'constants', 'syncContract.ts');
const OUT_PATH = path.join(__dirname, '..', 'tests', 'fixtures', 'syncContract.json');
const IOS_COPY_PATH = path.join(
  __dirname,
  '..',
  '..',
  '..',
  'apps',
  'ios',
  'OYBCTests',
  'Fixtures',
  'syncContract.json',
);

/**
 * Transpiles `src/constants/syncContract.ts` to a temporary CommonJS file
 * and `require()`s it — avoids `new Function`/`eval` (flagged by security
 * scanners as code-injection-shaped even though the input here is our own
 * repo-controlled source, not untrusted data) in favor of Node's normal
 * module loader.
 */
function loadConstants() {
  const source = fs.readFileSync(SRC_PATH, 'utf8');
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2019,
    },
    fileName: SRC_PATH,
  });

  const tmpFile = path.join(
    os.tmpdir(),
    `oybc-sync-contract-${process.pid}-${Date.now()}.js`,
  );
  fs.writeFileSync(tmpFile, outputText);
  try {
    delete require.cache[require.resolve(tmpFile)];
    return require(tmpFile);
  } finally {
    fs.unlinkSync(tmpFile);
  }
}

function main() {
  const {
    SYNC_COLLECTIONS,
    USER_SCOPED_SYNC_COLLECTIONS,
    LEGACY_PULL_SKIP_COLLECTIONS,
  } = loadConstants();

  if (!Array.isArray(SYNC_COLLECTIONS) || SYNC_COLLECTIONS.length === 0) {
    throw new Error('SYNC_COLLECTIONS did not transpile to a non-empty array — aborting.');
  }

  const fixture = {
    _generatedBy:
      'packages/shared/scripts/generate-sync-contract.js — DO NOT hand edit. ' +
      'Regenerate with `pnpm --filter @oybc/shared run gen:sync-contract` ' +
      'after changing src/constants/syncContract.ts.',
    syncCollections: SYNC_COLLECTIONS,
    userScopedSyncCollections: USER_SCOPED_SYNC_COLLECTIONS,
    legacyPullSkipCollections: LEGACY_PULL_SKIP_COLLECTIONS,
  };

  const json = JSON.stringify(fixture, null, 2) + '\n';
  fs.writeFileSync(OUT_PATH, json);
  console.log(`Wrote ${path.relative(process.cwd(), OUT_PATH)}`);

  fs.mkdirSync(path.dirname(IOS_COPY_PATH), { recursive: true });
  fs.writeFileSync(IOS_COPY_PATH, json);
  console.log(`Wrote ${path.relative(process.cwd(), IOS_COPY_PATH)}`);
}

main();
