#!/usr/bin/env node
/**
 * check-knip.mjs — drift guardrail against NEW dead code in apps/web.
 *
 * Runs knip and fails on drift beyond a frozen baseline:
 *   - NEW unused exports/types (not in scripts/audit/knip-baseline.json) → FAIL.
 *     The 2026-08 audit found dead exports by hand; knip finds them mechanically.
 *   - ANY unused file / dependency / unlisted / unresolved / duplicate → FAIL
 *     immediately (there are none today, so these are never baselined).
 * Advisory (never fails):
 *   - a baselined export that knip no longer reports → remove it from the
 *     baseline to lock in the cleanup (keeps the debt list honest).
 *
 * The baseline is accepted debt to shrink over time (same freeze-and-shrink
 * philosophy as scripts/audit/file-size-allowlist.json). Do NOT add new entries
 * to green a PR — delete the dead export instead.
 *
 * Node >= 20. Run from repo root: `node scripts/check-knip.mjs`
 * (spawns knip in apps/web via its local install).
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const webDir = resolve(repoRoot, 'apps/web');
const knipBin = resolve(webDir, 'node_modules/.bin/knip');

const baseline = JSON.parse(
  readFileSync(resolve(repoRoot, 'scripts/audit/knip-baseline.json'), 'utf8'),
);
const baselineSet = new Set(baseline.unusedExports);

// knip exits non-zero when it finds issues; capture stdout regardless.
let raw;
try {
  raw = execFileSync(knipBin, ['--reporter', 'json'], { cwd: webDir, encoding: 'utf8' });
} catch (e) {
  raw = e.stdout; // issues found → non-zero exit, JSON still on stdout
}
if (!raw) {
  console.error('check-knip: knip produced no output — is it installed in apps/web?');
  process.exit(2);
}

const report = JSON.parse(raw);
const currentKeys = new Set();
const hardIssues = []; // categories that must always be empty

for (const it of report.issues) {
  for (const e of it.exports || []) currentKeys.add(`${it.file}::${e.name}`);
  for (const t of it.types || []) currentKeys.add(`${it.file}::${t.name}`);
  for (const f of it.files || []) hardIssues.push(`unused file: ${typeof f === 'string' ? f : it.file}`);
  for (const d of it.dependencies || []) hardIssues.push(`unused dependency: ${it.file} → ${d.name || d}`);
  for (const d of it.devDependencies || []) hardIssues.push(`unused devDependency: ${it.file} → ${d.name || d}`);
  for (const u of it.unlisted || []) hardIssues.push(`unlisted dependency: ${it.file} → ${u.name || u}`);
  for (const u of it.unresolved || []) hardIssues.push(`unresolved import: ${it.file} → ${u.name || u}`);
}

const newDrift = [...currentKeys].filter((k) => !baselineSet.has(k)).sort();
const resolved = [...baselineSet].filter((k) => !currentKeys.has(k)).sort();

if (resolved.length) {
  console.log('knip guardrail — cleaned up since baseline (remove these from knip-baseline.json):');
  for (const r of resolved) console.log(`  ${r}`);
  console.log('');
}

if (hardIssues.length || newDrift.length) {
  console.error('knip guardrail FAILED:');
  for (const h of hardIssues) console.error(`  ${h}`);
  for (const k of newDrift) console.error(`  new unused export/type: ${k}`);
  console.error(
    '\nDelete the dead export (or wire up the intended consumer). Do NOT add it to ' +
      'scripts/audit/knip-baseline.json to get green. Unused files/dependencies are never baselined.',
  );
  process.exit(1);
}

console.log(`knip guardrail OK — no new dead code (${baselineSet.size} exports baselined as known debt).`);
