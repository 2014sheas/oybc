import { defineConfig } from 'vitest/config';
import path from 'path';

/**
 * Minimal Vitest harness for `@oybc/web` (issue #270, B2-W2 — roadmap E2
 * seed). Scope is deliberately narrow: pure/db-operation unit tests only,
 * not component/DOM tests — hence `environment: 'node'` rather than
 * `jsdom`. Dexie's own runtime needs nothing DOM-specific; it just needs
 * `indexedDB` + `IDBKeyRange` globals, which `./vitest.setup.ts` installs
 * via `fake-indexeddb/auto` before any test file runs.
 *
 * The `@oybc/shared` alias mirrors `vite.config.ts` (source, not `dist`) so
 * tests exercise the same module graph the app does and don't require a
 * prior `pnpm --filter @oybc/shared build`.
 *
 * Coverage (`pnpm test:coverage` → `vitest run --coverage`) is GATED by a
 * FLOOR (2026-10 CI audit): `thresholds` below is the 2026-10-17 measurement
 * (61.15 / 57.66 / 52.07 / 62.74) rounded down to the whole percent, so a PR
 * that drops coverage by more than that rounding margin fails CI. It stops
 * the slide (67.6% statements on 2026-09-23 → 61.2%) without demanding new
 * tests. Raise the floor as coverage grows; never lower it to pass a run.
 * `text-summary` prints to the log, `json-summary` lands in
 * `coverage/coverage-summary.json` for the CI artifact. See CLAUDE.md
 * §Testing Standards.
 */
export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@oybc/shared': path.resolve(__dirname, '../../packages/shared/src'),
    },
  },
  test: {
    globals: false,
    environment: 'node',
    include: ['src/**/*.test.ts'],
    setupFiles: ['./vitest.setup.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/**/*.test.ts', 'src/**/*.d.ts'],
      reporter: ['text-summary', 'json-summary'],
      reportsDirectory: './coverage',
      thresholds: {
        statements: 61,
        branches: 57,
        functions: 52,
        lines: 62,
      },
    },
  },
});
