import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@oybc/shared': path.resolve(__dirname, '../../packages/shared/src'),
    },
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
