import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { readFileSync } from 'node:fs';

const pkg = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf-8')
) as { version: string };

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
