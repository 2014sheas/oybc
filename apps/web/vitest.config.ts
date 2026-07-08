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
  },
});
