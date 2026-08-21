#!/usr/bin/env node
/**
 * check-sync-contract-rules.mjs — drift guardrail between the sync contract
 * (packages/shared) and firestore.rules.
 *
 * The 2026-08 audit found retired collections (taskSteps / compositeTasks /
 * compositeNodes) still whitelisted in firestore.rules after they'd been
 * dropped from the sync contract (fixed in #435). This locks the invariant so
 * the two can never diverge again:
 *
 *   SYNC_COLLECTIONS            (TS)  ==  isKnownCollection()   (rules)
 *   USER_SCOPED_SYNC_COLLECTIONS(TS)  ==  requiresUserIdField() (rules)
 *
 * A mismatch is a real security/sync bug: a collection the client syncs but
 * the rules don't allow (writes silently rejected), a collection the rules
 * allow but nothing syncs (dead, over-broad surface), or a user-scoped
 * collection missing its payload-userId enforcement.
 *
 * No dependencies. Node >= 20. Run: `node scripts/check-sync-contract-rules.mjs`
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = process.argv[2] ? resolve(process.argv[2]) : resolve(__dirname, '..');

const contractSrc = readFileSync(
  resolve(repoRoot, 'packages/shared/src/constants/syncContract.ts'),
  'utf8',
);
const rulesSrc = readFileSync(resolve(repoRoot, 'firestore.rules'), 'utf8');

/**
 * From `text`, find `startMarker`, then collect every single-quoted string up
 * to the first `]` that follows it. Line comments (`// …`) are stripped first
 * so a collection name mentioned in a comment can't leak into the set.
 */
function quotedAfter(text, startMarker, label) {
  const start = text.indexOf(startMarker);
  if (start === -1) throw new Error(`could not find ${label} (marker: ${startMarker})`);
  const close = text.indexOf(']', start);
  if (close === -1) throw new Error(`could not find closing ] for ${label}`);
  const block = text
    .slice(start, close)
    .split('\n')
    .map((line) => line.replace(/\/\/.*$/, '')) // strip line comments
    .join('\n');
  const names = [...block.matchAll(/'([^']+)'/g)].map((m) => m[1]);
  if (names.length === 0) throw new Error(`${label} parsed to an empty set — parser drift?`);
  return new Set(names);
}

function diff(aSet, bSet) {
  const onlyA = [...aSet].filter((x) => !bSet.has(x));
  const onlyB = [...bSet].filter((x) => !aSet.has(x));
  return { onlyA, onlyB };
}

const checks = [
  {
    name: 'SYNC_COLLECTIONS ↔ firestore.rules isKnownCollection()',
    ts: quotedAfter(contractSrc, 'SYNC_COLLECTIONS = [', 'SYNC_COLLECTIONS'),
    rules: quotedAfter(rulesSrc, 'function isKnownCollection()', 'isKnownCollection()'),
    tsLabel: 'SYNC_COLLECTIONS (contract)',
    rulesLabel: 'isKnownCollection() (rules)',
  },
  {
    name: 'USER_SCOPED_SYNC_COLLECTIONS ↔ firestore.rules requiresUserIdField()',
    ts: quotedAfter(contractSrc, 'USER_SCOPED_SYNC_COLLECTIONS = [', 'USER_SCOPED_SYNC_COLLECTIONS'),
    rules: quotedAfter(rulesSrc, 'function requiresUserIdField()', 'requiresUserIdField()'),
    tsLabel: 'USER_SCOPED_SYNC_COLLECTIONS (contract)',
    rulesLabel: 'requiresUserIdField() (rules)',
  },
];

let failed = false;
for (const c of checks) {
  const { onlyA, onlyB } = diff(c.ts, c.rules);
  if (onlyA.length || onlyB.length) {
    failed = true;
    console.error(`sync-contract guardrail FAILED — ${c.name}:`);
    if (onlyA.length) console.error(`  in ${c.tsLabel} but NOT in ${c.rulesLabel}: ${onlyA.join(', ')}`);
    if (onlyB.length) console.error(`  in ${c.rulesLabel} but NOT in ${c.tsLabel}: ${onlyB.join(', ')}`);
  } else {
    console.log(`OK — ${c.name} (${c.ts.size} collections)`);
  }
}

if (failed) {
  console.error(
    '\nThe sync contract (packages/shared/src/constants/syncContract.ts) and ' +
      'firestore.rules must list the same collections. Add/remove on BOTH sides in the same PR.',
  );
  process.exit(1);
}
console.log('sync-contract guardrail OK.');
