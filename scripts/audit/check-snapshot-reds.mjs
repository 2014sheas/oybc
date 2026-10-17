#!/usr/bin/env node
/**
 * check-snapshot-reds.mjs — iOS snapshot CI gate (2026-10 CI audit).
 *
 * CI renders snapshots on the runner's iOS 26.2 simulator while baselines are
 * recorded locally on iOS 26.3.1 (CLAUDE.md §iOS snapshot tests). A fixed set
 * of grid-bearing views lays out differently there — a real layout shift, not
 * anti-aliasing, so a pixel tolerance cannot absorb it. That set was identical
 * across the last 8 runs before this gate shipped. Instead of an advisory step
 * nobody reads, this freezes that set and fails only on a red OUTSIDE it.
 *
 * Reads an `xcodebuild test -scheme OYBCSnapshotTests` log and:
 *   - fails if the OYBCSnapshotTests suite never reported finishing (a build
 *     error or a crash that killed the run — no result to trust);
 *   - fails if xcodebuild reported failures but no failing case was parsed
 *     (the log format changed). Its "with N failures" counts ASSERTIONS, not
 *     cases — one test can fail several — so a mere mismatch only prints a
 *     note; the per-case lines are what the gate trusts;
 *   - fails on any failing test not in scripts/audit/snapshot-ci-known-reds.json;
 *   - prints a note for a known red that now passes (shrink the list).
 *
 * Shrink the list as reds are fixed; never grow it to dodge a regression. When
 * the runner image ships the local runtime, the list should go to empty.
 *
 * Exit 0 clean, 1 on a new red or an untrustworthy log. No dependencies.
 * Run: node scripts/audit/check-snapshot-reds.mjs <xcodebuild.log> | --self-test
 */
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const KNOWN_PATH = join(root, 'scripts', 'audit', 'snapshot-ci-known-reds.json');

const CASE_FAILED =
  /Test Case '-\[OYBCSnapshotTests\.([A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]' failed/;
const SUITE_DONE = /Test Suite 'OYBCSnapshotTests\.xctest' (passed|failed) at/;
const EXECUTED = /Executed (\d+) tests?, with (\d+) failures?/;

/**
 * Parse an xcodebuild snapshot-test log.
 *
 * @param {string} log - Full xcodebuild output.
 * @returns {{finished: boolean, reported: number|null, failed: string[]}}
 *   `finished`: the suite-end line appeared; `reported`: xcodebuild's last
 *   "with N failures" total (null if absent); `failed`: sorted unique
 *   `"Class testName"` entries.
 */
export function parseLog(log) {
  const failed = new Set();
  let finished = false;
  let reported = null;
  for (const line of log.split('\n')) {
    const c = line.match(CASE_FAILED);
    if (c) failed.add(`${c[1]} ${c[2]}`);
    if (SUITE_DONE.test(line)) finished = true;
    const e = line.match(EXECUTED);
    if (e) reported = Number(e[2]);
  }
  return { finished, reported, failed: [...failed].sort() };
}

/**
 * Compare a parsed log with the known-red list.
 *
 * @param {{finished: boolean, reported: number|null, failed: string[]}} parsed
 * @param {string[]} known - Frozen `"Class testName"` entries.
 * @returns {{errors: string[], notes: string[]}} errors fail the gate.
 */
export function evaluate(parsed, known) {
  const errors = [];
  const notes = [];
  if (!parsed.finished) {
    errors.push(
      'OYBCSnapshotTests never reported finishing — a build error or crash ended the run. Read the xcodebuild output above.',
    );
    return { errors, notes };
  }
  if (parsed.reported !== null && parsed.reported > 0 && parsed.failed.length === 0) {
    errors.push(
      `xcodebuild reported ${parsed.reported} failures but no failing test case was parsed — the log format changed; fix the parser before trusting this gate.`,
    );
  } else if (parsed.reported !== null && parsed.reported !== parsed.failed.length) {
    notes.push(
      `xcodebuild counted ${parsed.reported} failed assertions across ${parsed.failed.length} failing cases (a test can fail more than one assertion).`,
    );
  }
  const knownSet = new Set(known);
  for (const t of parsed.failed) {
    if (!knownSet.has(t)) errors.push(`NEW snapshot red: ${t}`);
  }
  const failedSet = new Set(parsed.failed);
  for (const t of known) {
    if (!failedSet.has(t)) {
      notes.push(`known red now passes on CI — remove it from snapshot-ci-known-reds.json: ${t}`);
    }
  }
  return { errors, notes };
}

/** Inline fixtures so the parser can't silently rot. */
function selfTest() {
  const line = (cls, t, r) => `Test Case '-[OYBCSnapshotTests.${cls} ${t}]' ${r} (0.3 seconds).`;
  const done = "Test Suite 'OYBCSnapshotTests.xctest' failed at 2026-10-17 01:55:52.792.";
  const cases = [
    {
      name: 'known reds only → clean',
      log: [line('A', 'testOne', 'failed'), line('B', 'testTwo', 'passed'), done, '\t Executed 2 tests, with 1 failure (0 unexpected) in 1.0 (1.0) seconds'].join('\n'),
      known: ['A testOne'],
      errors: 0,
      notes: 0,
    },
    {
      name: 'new red → error',
      log: [line('A', 'testOne', 'failed'), line('C', 'testNew', 'failed'), done, 'Executed 3 tests, with 2 failures'].join('\n'),
      known: ['A testOne'],
      errors: 1,
      notes: 0,
    },
    {
      name: 'fixed red → note',
      log: [line('A', 'testOne', 'passed'), done, 'Executed 1 test, with 0 failures'].join('\n'),
      known: ['A testOne'],
      errors: 0,
      notes: 1,
    },
    {
      name: 'no suite end → error',
      log: ['** BUILD FAILED **'].join('\n'),
      known: [],
      errors: 1,
      notes: 0,
    },
    {
      name: 'more assertions than cases → note only',
      log: [line('A', 'testOne', 'failed'), done, 'Executed 5 tests, with 3 failures'].join('\n'),
      known: ['A testOne'],
      errors: 0,
      notes: 1,
    },
    {
      name: 'failures reported, none parsed → error',
      log: [done, 'Executed 5 tests, with 3 failures'].join('\n'),
      known: [],
      errors: 1,
      notes: 0,
    },
  ];
  let bad = 0;
  for (const c of cases) {
    const { errors, notes } = evaluate(parseLog(c.log), c.known);
    if (errors.length !== c.errors || notes.length !== c.notes) {
      console.error(`self-test FAILED: ${c.name} (errors ${errors.length}/${c.errors}, notes ${notes.length}/${c.notes})`);
      bad++;
    }
  }
  if (bad) process.exit(1);
  console.log(`check-snapshot-reds self-test: ${cases.length} cases passed`);
}

function main() {
  const arg = process.argv[2];
  if (arg === '--self-test') return selfTest();
  if (!arg) {
    console.error('usage: check-snapshot-reds.mjs <xcodebuild.log> | --self-test');
    process.exit(2);
  }
  const known = JSON.parse(readFileSync(KNOWN_PATH, 'utf8')).entries;
  const parsed = parseLog(readFileSync(arg, 'utf8'));
  const { errors, notes } = evaluate(parsed, known);
  for (const n of notes) console.log(`note: ${n}`);
  if (errors.length) {
    for (const e of errors) console.error(`::error::${e}`);
    process.exit(1);
  }
  console.log(
    `snapshot gate clean: ${parsed.failed.length} failing, all in the ${known.length}-entry known-red list.`,
  );
}

main();
