#!/usr/bin/env node
// Guardrail: a Getting Started sandbox lesson must never reach the app
// database. Lessons 2-3 run the real create-board / play-board screens against a
// throwaway AppDatabase injected from outside, so code on those screens' path
// may not name `AppDatabase.shared` (default parameters `= .shared` are the
// injection seam and are fine). Fails on any non-comment mention.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = new URL('../../', import.meta.url).pathname;
const ios = join(root, 'apps/ios/OYBC');
// Lesson-path trees; BoardListView (the Boards tab, never inside a lesson) is exempt.
const TREES = ['Views/CreateTab', 'Views/BoardsTab'];
const EXEMPT = new Set(['Views/BoardsTab/BoardListView.swift']);

function* swiftFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* swiftFiles(full);
    else if (name.endsWith('.swift')) yield full;
  }
}

const hits = [];
for (const tree of TREES) {
  for (const file of swiftFiles(join(ios, tree))) {
    const rel = relative(ios, file);
    if (EXEMPT.has(rel)) continue;
    readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*\/\//.test(line)) return;
      if (line.includes('AppDatabase.shared')) hits.push(`${rel}:${i + 1}: ${line.trim()}`);
    });
  }
}

if (hits.length) {
  console.error('tutorial sandbox guardrail FAILED — AppDatabase.shared on a lesson path:\n' + hits.join('\n'));
  console.error('\nThread the injected database (a `database:` parameter or the `\\.appDatabase` environment value) instead.');
  process.exit(1);
}
console.log('tutorial sandbox guardrail OK — no AppDatabase.shared on the lesson path.');
