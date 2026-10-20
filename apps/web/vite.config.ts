import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const pkg = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf-8')
) as { version: string };

/**
 * This build's identity — `<package version>+<commit>` — injected as
 * `__APP_BUILD__`. The pull's forward-compat quarantine ledger
 * (`db/operations/syncQuarantine.ts`) retries a skipped doc only under a
 * DIFFERENT build, so every deploy re-reads exactly the docs an earlier
 * deploy could not apply. Falls back to `local` outside a git checkout.
 *
 * @returns The build identity string.
 */
function resolveBuildId(): string {
  let sha = process.env.GITHUB_SHA ?? '';
  if (!sha) {
    try {
      sha = execSync('git rev-parse HEAD', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    } catch {
      sha = '';
    }
  }
  return `${pkg.version}+${sha ? sha.slice(0, 12) : 'local'}`;
}

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@oybc/shared': path.resolve(__dirname, '../../packages/shared/src'),
      // Same source-alias treatment for bingo-core: shared's src re-exports
      // from it, and without this the dev server resolves the package to its
      // CJS dist — which the browser can't named-import (T1 latent gap; only
      // dev/e2e ever hit it, all CI build lanes bundle via rollup).
      '@oybc/bingo-core': path.resolve(
        __dirname,
        '../../packages/bingo-core/src'
      ),
    },
  },
  define: {
    // Injected at build time from package.json so the footer version is always
    // in sync with the published semver. No hardcoding required.
    __APP_VERSION__: JSON.stringify(pkg.version),
    __APP_BUILD__: JSON.stringify(resolveBuildId()),
  },
  build: {
    target: 'es2020',
    sourcemap: true,
  },
  server: {
    port: 5173,
    open: true,
  },
});
