#!/usr/bin/env node
// Guardrail: a Getting Started lesson must never reach the app database on its
// own. The lessons run over tutorial-owned facsimile screens fed by in-memory
// fixtures; the one real write path (lesson 1's two task adds) goes through the
// database the coordinator was handed. So no file in the tutorial module may
// name `AppDatabase.shared` (default parameters `= .shared` are the injection
// seam and are fine). Fails on any non-comment mention.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = new URL('../../', import.meta.url).pathname;
const ios = join(root, 'apps/ios/OYBC');
const TREES = ['Views/BoardsTab/Tutorial'];
const FILES = ['Services/TutorialCoordinator.swift'];

function* swiftFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* swiftFiles(full);
    else if (name.endsWith('.swift')) yield full;
  }
}

const hits = [];
const files = [...TREES.flatMap((tree) => [...swiftFiles(join(ios, tree))]), ...FILES.map((f) => join(ios, f))];
for (const file of files) {
  const rel = relative(ios, file);
  readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
    if (/^\s*\/\//.test(line)) return;
    if (/^\s*\/\/\//.test(line)) return;
    const code = line.replace(/\/\/.*$/, '');
    if (code.includes('AppDatabase.shared') && !code.includes('= .shared')) hits.push(`${rel}:${i + 1}: ${line.trim()}`);
  });
}

if (hits.length) {
  console.error('tutorial database guardrail FAILED — AppDatabase.shared inside the tutorial module:\n' + hits.join('\n'));
  console.error('\nThe lessons run on fixtures; a real write goes through the coordinator\'s injected database.');
  process.exit(1);
}
console.log('tutorial database guardrail OK — no AppDatabase.shared inside the tutorial module.');
