import { defineConfig } from 'vite';

// Standalone static placeholder. No framework plugins — plain HTML + TS + CSS.
// Builds to dist/, which Firebase Hosting serves as the only public route on
// oybc.com. See docs/COMING_SOON.md.
export default defineConfig({
  build: {
    target: 'es2020',
    sourcemap: true,
  },
  server: {
    port: 5273, // distinct from the app's 5173 so both can run at once
  },
});
