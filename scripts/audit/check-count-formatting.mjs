#!/usr/bin/env node
/**
 * check-count-formatting.mjs — counter kinds drift guard (docs/COUNTER_KINDS.md §5).
 *
 * Every count on screen goes through formatCount / formatCountTotal (and
 * friends) with the task's REAL kind. This fails on a NEW line that:
 *   - passes a hard-coded discrete kind to a formatCount* helper
 *     (Swift `kind: .discrete`, TS a literal `'discrete'` kind argument), or
 *   - formats a counting value with the platform's kind-blind formatter
 *     (Swift `.formatted()`, TS `.toLocaleString()`) — lifetime totals keep
 *     their grouping through formatCountTotal (R7).
 *
 * Only identifiers that name counting values are matched (COUNT_NAMES), so
 * board sizes, versions and dates never trip it. Known-intentional sites live
 * in scripts/audit/count-formatting-allowlist.json as "path::trimmed line" —
 * a moved line still matches, an edited line re-flags. Shrink it, never grow
 * it to dodge a fix.
 *
 * LIMITS — this is a single-line, name-keyed heuristic, not proof of
 * kind-awareness. It reads one line at a time and only the identifiers in
 * COUNT_NAMES, so it misses: a call split across lines, a kind smuggled in
 * as `'discrete' as CountKind` (or any variable holding 'discrete'), a value
 * named outside COUNT_NAMES, and raw JSX / template-literal interpolation of
 * a count (`{current} / {max}`, `${count}`) that never calls a formatter at
 * all. A green run means "no NEW line matches these patterns" — review still
 * owns the rest.
 *
 * Exit 0 clean (stale allow-list entries print a note), 1 on a new offender.
 * No dependencies. Node >= 20.
 * Run: node scripts/audit/check-count-formatting.mjs [--self-test]
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

/** Identifiers that hold a counting value (a count, goal, total or amount). */
const COUNT_NAMES =
  '(?:lifetime|logged|goal|currentCount|maxCount|remaining|todayTotal|over|next|previewCount|amount|selectedAmount|baseline|defaultLogAmount)';
/** `name`, `name ?? 0`, optionally closed by the `(…)` it was wrapped in. */
const COUNT_EXPR = `\\b${COUNT_NAMES}(?:\\s*\\?\\?\\s*\\d+(?:\\.\\d+)?)?\\)?`;

const RULES = [
  { ext: '.swift', re: /formatCount\w*\(.*\bkind:\s*\.discrete\s*[,)]/ },
  { ext: '.swift', re: new RegExp(`${COUNT_EXPR}\\.formatted\\(\\)`) },
  { ext: '.ts', re: /formatCount\w*\(.*,\s*'discrete'\s*[,)]/ },
  { ext: '.ts', re: new RegExp(`${COUNT_EXPR}\\.toLocaleString\\(`) },
];

/**
 * The offending lines of one file.
 *
 * @param {string} path - Repo-relative path (its extension picks the rules).
 * @param {string} text - The file's contents.
 * @returns {string[]} `"path::trimmed line"` per offending line.
 */
export function offenders(path, text) {
  const ext = path.endsWith('.swift') ? '.swift' : '.ts';
  return text.split('\n').flatMap((line) =>
    RULES.some((r) => r.ext === ext && r.re.test(line)) ? [`${path}::${line.trim()}`] : [],
  );
}

/**
 * Production source files under `dir` (tests and fixtures skipped).
 *
 * @param {string} dir - Directory to walk.
 * @param {string[]} out - Accumulator.
 * @returns {string[]} Absolute file paths.
 */
function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (!['node_modules', '__tests__', 'Fixtures'].includes(name)) walk(p, out);
    } else if (/\.(swift|ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name)) {
      out.push(p);
    }
  }
  return out;
}

function selfTest() {
  const bad = [
    ...offenders('x.swift', [
      'Text(formatCount(v, kind: .discrete))',
      'Text(group.lifetime.formatted())',
      'Text("\\(source.lifetime.formatted()) \\(source.unit)")',
      '"+ \\(formatCountWithUnit(a, kind: .discrete, unit: u))"',
    ].join('\n')),
    ...offenders('x.tsx', [
      "formatCount(v, 'discrete')",
      '{(sourceTask.currentCount ?? 0).toLocaleString()} {sourceTask.unit}',
      'const s = group.lifetime.toLocaleString();',
    ].join('\n')),
  ];
  const good = [
    ...offenders('x.swift', [
      'formatCount(v, kind: kind)',
      'formatCount(v, kind: task.countKind ?? .discrete)',
      'Text(Date().formatted())',
      'Text("\\(board.size.formatted())")',
      'kind == .discrete ? "a" : formatCount(v, kind: kind)',
    ].join('\n')),
    ...offenders('x.ts', [
      'formatCount(v, kind)',
      "formatCount(v, sq.countKind ?? 'discrete')",
      'const n = (12).toFixed(2)',
      'version.toLocaleString()',
      'new Date(board.endDate).toLocaleString()',
    ].join('\n')),
  ];
  if (bad.length !== 7 || good.length !== 0) {
    console.error('check-count-formatting self-test FAILED', { bad, good });
    process.exit(1);
  }
  console.log('check-count-formatting self-test OK');
  process.exit(0);
}

if (process.argv.includes('--self-test')) selfTest();

const allowPath = join(root, 'scripts/audit/count-formatting-allowlist.json');
const allow = new Set(JSON.parse(readFileSync(allowPath, 'utf8')).entries);
const found = [join(root, 'apps/ios/OYBC'), join(root, 'apps/web/src')]
  .flatMap((d) => walk(d))
  .flatMap((p) => offenders(relative(root, p).split(sep).join('/'), readFileSync(p, 'utf8')));
const fresh = found.filter((f) => !allow.has(f));
const stale = [...allow].filter((a) => !found.includes(a));
for (const s of stale) console.log(`note: stale allow-list entry (shrink it): ${s}`);
if (fresh.length) {
  console.error(
    'Counts must render through formatCount / formatCountTotal with the task kind ' +
      '(docs/COUNTER_KINDS.md §5):\n' +
      fresh.map((f) => `  ${f}`).join('\n'),
  );
  process.exit(1);
}
console.log(`check-count-formatting OK (${found.length} allow-listed)`);
