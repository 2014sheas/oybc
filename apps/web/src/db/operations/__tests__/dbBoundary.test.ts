import { readFileSync, readdirSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * DB layering boundary test (B3, issue #284).
 *
 * The raw Dexie singleton lives in `db/internal.ts` and is INTERNAL to the
 * data layer. Only files under `db/`, `hooks/`, `firebase/`, and test files
 * may import it; everything else must go through an operations function or a
 * hook. This is enforced structurally (`db/database.ts` no longer exports the
 * instance) and by `no-restricted-imports` in `eslint.config.js` — this test
 * is the belt-and-suspenders check that runs in the normal Vitest suite (and
 * catches a regression even if lint is skipped).
 */

// Load every source file's raw text from disk (the suite runs in vitest's
// `node` environment). Deliberately NOT `import.meta.glob(…, { query: '?raw' })`:
// knip's Vite plugin ignores glob options, so a `?raw` glob makes every file
// look imported and silently defeats knip's unused-file check (knip #2016).
// Keys are project-root-relative paths, e.g. `/src/pages/Playground.tsx`.
const webRoot = fileURLToPath(new URL('../../../../', import.meta.url));
const srcDir = join(webRoot, 'src');
const sources: Record<string, string> = Object.fromEntries(
  readdirSync(srcDir, { recursive: true, encoding: 'utf8' })
    .filter((rel) => /\.tsx?$/.test(rel))
    .map((rel) => {
      const abs = join(srcDir, rel);
      const key = '/' + relative(webRoot, abs).split(sep).join('/');
      return [key, readFileSync(abs, 'utf8')] as const;
    }),
);

/** Dirs whose files ARE the data layer (allowed to import `db/internal`). */
const ALLOWED_PREFIXES = ['/src/db/', '/src/hooks/', '/src/firebase/'];

/** Matches a relative import of the raw instance module, e.g.
 *  `from '../db/internal'`, `from '../../internal'`. */
const INTERNAL_IMPORT = /from\s+['"][^'"]*\/internal['"]/;

describe('db/internal import boundary', () => {
  it('is only imported by the data layer (db/hooks/firebase) or tests', () => {
    const offenders: string[] = [];
    for (const [file, source] of Object.entries(sources)) {
      const isAllowedDir = ALLOWED_PREFIXES.some((p) => file.startsWith(p));
      const isTest = file.includes('/__tests__/') || /\.test\.tsx?$/.test(file);
      if (isAllowedDir || isTest) continue;
      if (INTERNAL_IMPORT.test(source)) offenders.push(file);
    }
    expect(offenders).toEqual([]);
  });

  it('sanity-checks that the glob actually loaded source files', () => {
    // Guards against a silently-empty glob giving a false pass.
    expect(Object.keys(sources).length).toBeGreaterThan(50);
  });
});
