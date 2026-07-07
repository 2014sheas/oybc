import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      // Alias to source (mirrors apps/web's @oybc/shared alias) so Play's
      // dev server picks up bingo-core changes without a prior `pnpm build`.
      '@oybc/bingo-core': path.resolve(__dirname, '../../packages/bingo-core/src'),
    },
  },
  build: {
    target: 'es2020',
    sourcemap: true,
  },
  server: {
    port: 5174,
    open: true,
  },
});
