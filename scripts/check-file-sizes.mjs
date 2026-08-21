#!/usr/bin/env node
/**
 * check-file-sizes.mjs — drift guardrail against god-file regrowth.
 *
 * Source files must stay under a line ceiling. Known-oversized files are
 * frozen at their current size in scripts/audit/file-size-allowlist.json:
 * they may shrink freely but may not grow past the recorded count, and no
 * NEW file may cross the ceiling. This prevents the god-files the 2026-08
 * audit flagged (ROADMAP Track B6) from growing further and stops new ones
 * from appearing — the mechanical half of "never drift out of spec".
 *
 * Fails (exit 1) and lists offenders when:
 *   - a non-allowlisted source file exceeds CEILING lines, or
 *   - an allowlisted file grew past its frozen count.
 * Emits advisory notes (never fails) when:
 *   - an allowlisted file has shrunk to/under the ceiling (tighten the list), or
 *   - an allowlisted file has shrunk below its frozen count (lower the number).
 *
 * No dependencies. Node >= 20. Run: `node scripts/check-file-sizes.mjs`
 * Optional arg: an alternate repo root (for testing).
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative, join, sep } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = process.argv[2] ? resolve(process.argv[2]) : resolve(__dirname, '..');

const CEILING = 1000;

// Directories to scan and the extensions that count as "source" in each.
const SCAN = [
  { dir: 'apps/web/src', exts: ['.ts', '.tsx'] },
  { dir: 'apps/ios/OYBC', exts: ['.swift'] },
  { dir: 'packages/shared/src', exts: ['.ts'] },
  { dir: 'packages/bingo-core/src', exts: ['.ts'] },
  { dir: 'apps/play/src', exts: ['.ts', '.tsx'] },
];

// Path fragments that are never "source we hold to the ceiling".
const EXCLUDE = [
  '__tests__',
  '__snapshots__',
  '.test.',
  '.spec.',
  'node_modules',
  '/dist/',
  '.d.ts',
];

const allowlistPath = resolve(repoRoot, 'scripts/audit/file-size-allowlist.json');
const allow = JSON.parse(readFileSync(allowlistPath, 'utf8')).limits;

// Count lines the way `wc -l` does (number of newline characters), so the
// allowlist numbers can be seeded/verified with `wc -l`.
function countLines(content) {
  let n = 0;
  for (let i = 0; i < content.length; i++) if (content.charCodeAt(i) === 10) n++;
  return n;
}

function isExcluded(rel) {
  const p = '/' + rel.split(sep).join('/');
  return EXCLUDE.some((frag) => p.includes(frag));
}

function walk(absDir, exts, out) {
  let entries;
  try {
    entries = readdirSync(absDir, { withFileTypes: true });
  } catch {
    return; // directory may not exist (e.g. apps/play not scaffolded)
  }
  for (const e of entries) {
    const abs = join(absDir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'node_modules' || e.name === 'dist') continue;
      walk(abs, exts, out);
    } else if (exts.some((x) => e.name.endsWith(x))) {
      out.push(abs);
    }
  }
}

const files = [];
for (const { dir, exts } of SCAN) walk(resolve(repoRoot, dir), exts, files);

const failures = [];
const notes = [];
const seenAllow = new Set();

for (const abs of files) {
  const rel = relative(repoRoot, abs).split(sep).join('/');
  if (isExcluded(rel)) continue;
  const lines = countLines(readFileSync(abs, 'utf8'));

  if (rel in allow) {
    seenAllow.add(rel);
    const cap = allow[rel];
    if (lines > cap) {
      failures.push(
        `  ${rel}: ${lines} lines > frozen cap ${cap} — an allowlisted god-file grew. ` +
          `Split it (ROADMAP B6) or, if the growth is unavoidable, bump the number in the allowlist deliberately.`,
      );
    } else if (lines <= CEILING) {
      notes.push(`  ${rel}: now ${lines} ≤ ceiling ${CEILING} — remove it from the allowlist.`);
    } else if (lines < cap) {
      notes.push(`  ${rel}: shrank to ${lines} (cap ${cap}) — lower the cap to lock in progress.`);
    }
  } else if (lines > CEILING) {
    failures.push(
      `  ${rel}: ${lines} lines > ceiling ${CEILING} — a new god-file. ` +
        `Split it along its seams; do NOT add it to the allowlist to get green.`,
    );
  }
}

// Stale allowlist entries (file moved/deleted) — surface so the list stays honest.
for (const rel of Object.keys(allow)) {
  if (!seenAllow.has(rel)) {
    notes.push(`  ${rel}: in allowlist but not found on disk — remove the stale entry.`);
  }
}

if (notes.length) {
  console.log('file-size guardrail — advisory notes (not failing):');
  for (const n of notes) console.log(n);
  console.log('');
}

if (failures.length) {
  console.error(`file-size guardrail FAILED — ${failures.length} file(s) over budget:`);
  for (const f of failures) console.error(f);
  console.error(
    `\nCeiling is ${CEILING} lines for source files. Known offenders are frozen in ` +
      `scripts/audit/file-size-allowlist.json (ROADMAP Track B6).`,
  );
  process.exit(1);
}

console.log(`file-size guardrail OK — no source file over budget (ceiling ${CEILING}, ${Object.keys(allow).length} allowlisted).`);
